# Design: limiting password guesses (options, no code)

QUEUE.md item 93. **Nothing limits login attempts today**, on Linux or on
metal: `/login/full` calls `users.checkUserPassword` (login.zig:127, :148) for
every try, and that is a bcrypt verify at **cost 10** (auth.zig:26) — tens of
milliseconds of CPU each. So an unlimited guesser is two problems at once:

1. **Guessing.** The only account worth guessing is **uid 1** (Steve, the sole
   admin: admin_ui.zig `admin_uid = "1"`). Members have no powers a guesser
   wants; the admin has `/admin/backup` (every hash) and `/admin/secret`.
2. **A stall.** Metal serves **one request at a time on one processor**. Each
   guess forces a bcrypt, so a flood of `POST /login/full` is a CPU-exhaustion
   attack: the machine spends its one core hashing guesses while real requests
   wait. Linux has more cores and threads per connection, so there it is
   slower but not a full stall.

This note weighs the options. No code; Steve decides.

## The machinery already exists

`game_limits.zig` already does per-address, per-window counting for item 52's
bounds, and a login throttle is the same shape — so this is tuning and a hook,
not new infrastructure:

- **`clientAddress`** (game_limits.zig:101) is the address to key on: the
  connection's `peer`, or, when `peer` is the `trusted_proxy` (Caddy), the
  **last** entry of `X-Forwarded-For` — the one Caddy added, which a client
  cannot forge past. The cutover sets `droplet/trusted-proxy` so this is the
  real client, not Caddy (CUTOVER.md step 7).
- **A fixed table** of 256 address slots (`table: [slots]Usage`), each a
  windowed counter that resets an hour after its first count, the oldest slot
  evicted when the table is full. In memory, nothing kept past a request,
  **identical on both hosts** (game_limits.zig's header: "both hosts keep it
  the same way").
- **`refuse`** turns a bound into a 429 whose text names the bound.

So the throttle would add a `failures` counter (per address, and — see below —
per name) beside the existing `players`/`resigns`/`bytes` ones, checked at the
top of `handleLoginFull` and bumped on a failed `checkUserPassword`.

## The one rule that matters most on metal: refuse *before* the bcrypt

Whatever the policy, the refusal must be a **cheap table lookup that
short-circuits before `checkUserPassword`**. If the limit is checked only
after the bcrypt, a flood still pays one bcrypt per guess and the stall stands;
the point for metal is that the (N+1)th guess from a limited address or against
a limited name costs a hash-table probe, not a hash. This is the difference
between a throttle that protects the single processor and one that only slows
the attacker's success rate.

## Option A — a delay after each failure. **Rejected for metal.**

The textbook answer (sleep ~1 s after a wrong password) is actively harmful
here: metal serves one request at a time, so a `sleep` inside a login handler
**stalls the whole machine** for that second — every other connection waits.
An attacker would *induce* the delay on purpose. A delay also still pays the
bcrypt. Mentioned only to rule it out: on a single-processor, one-request-at-
a-time server, never hold a request to slow a caller.

## Option B — refuse after N failures in a window (recommended)

Count failed logins and refuse (429, "too many attempts, try again later")
once a counter passes its bound, with the counter resetting after a window —
exactly `players_per_hour`'s shape. Two counters, because they stop different
attacks:

- **Per address** (`clientAddress`): stops **one address** hammering any
  name(s). After N failures that address gets cheap 429s until the window
  resets. This is the CPU guard against a single flooder.
- **Per name** (the submitted member id): stops **many addresses** guessing
  **one** account — the distributed attack on uid 1, which per-address cannot
  see (each address is one guess). After N failures against a name, further
  guesses of that name are refused before the bcrypt, wherever they come from.

Neither is a permanent lock: the window resets (an hour, or shorter — see the
numbers). A success could also clear the address counter, so a member who
mistypes then gets it right is not left throttled.

### What it costs a real member who mistypes

With a per-name bound of, say, **10 failures / 15 minutes**: a member fat-
fingering their password a few times is nowhere near it; someone who has
genuinely forgotten gets ten tries before a 15-minute pause, which is the
moment to use the reset path, not keep guessing. Tune the number to taste —
the cost of a higher bound is more bcrypts an attacker gets per window.

### Against one address vs. many

- **One address, any names:** the per-address counter trips after N; the
  flood then costs table probes, not hashes. Stall closed.
- **Many addresses, one name (the real threat to uid 1):** the per-name
  counter trips after N total, across all addresses; the distributed flood
  then costs table probes too, and uid 1's password is protected at N guesses
  per window however many addresses are used.

### The tension to decide: locking the admin out

A per-name bound on uid 1 means an attacker can **deny the admin their login**
by burning the name's budget during an attack — a nuisance, not a breach.
Three ways to settle it, for Steve:

1. **Accept it.** During an attack the admin waits out the window, or uses the
   password-reset runbook (`ADMIN-PASSWORD-LOST.md`, which writes a reset
   through the console, not through `/login`). Simplest; the attack is rare
   and the window short.
2. **A trusted-address bypass.** The per-name bound does not apply to a
   request from the admin's own address (a configured IP, or the private
   network). Keeps the admin able to log in mid-attack; adds a config knob.
3. **Let a correct password through even over the bound, at a trickle.** Check
   the password past the limit but only once every few seconds per name, so a
   real admin succeeds while a guesser still gets at most a trickle of
   bcrypts. Reintroduces a little bcrypt cost under attack; most forgiving to
   the admin.

My suggestion: **B with per-name 10/15 min and per-address ~20/hour, option 1
for the admin** (the reset runbook already exists, and it is the honest
break-glass), unless Steve wants to keep admin login working mid-attack, in
which case option 2 (a trusted address) is cleaner than 3.

## Option C — escalating refusal

A variant of B: the window or the bound tightens as failures repeat (first 10
free, then 10/hour, then 10/day). More forgiving to a mistyper, more punishing
to a persistent guesser. Costs a little more state per slot. Worth it only if
B's flat bound proves too blunt; I would start flat.

## How it is judged, on both hosts

Like `game_limits`: in memory, deterministic, the same code on metal and
Linux, so a judge story runs identically on both.

- **The bound trips, and before the bcrypt.** Drive N+1 wrong logins for one
  name (or from one address); assert the first N return the normal "wrong
  password" page and the (N+1)th returns 429. That the refusal is *before* the
  bcrypt is the metal-critical property: assert it by timing (the 429 returns
  in well under a bcrypt's tens of ms) or, more robustly, by a counter that
  the refusal path increments and the bcrypt path does not — the judge reads
  it off `/admin/host` or a test hook, and the two hosts must agree.
- **The window resets, and the table evicts its oldest** — the same unit tests
  `game_limits` has for `players_per_hour` (an hour after the first count the
  count starts again; a full table gives up its oldest), extended to the
  failures counter.
- **A correct password is never refused under the bound**, and (if a success
  clears the counter) a mistype-then-correct member is not left throttled.

## Summary for Steve

- The stall and the guessing are the same problem; the fix is **refuse before
  the bcrypt**, which only Option B (count-and-refuse, no delay) does.
- Key on **both** the address (one flooder → CPU guard) and the name (many
  addresses → protect uid 1).
- No permanent locks — windowed, resetting — so a throttle is not itself a DoS
  on a real member, with the admin-lockout tension settled by the reset
  runbook (simplest) or a trusted-address bypass.
- It reuses `game_limits`' table and `clientAddress`, so it is tuning and a
  hook, judged on both hosts the way the game bounds already are.

The numbers (10/15 min per name, ~20/hour per address, success clears the
address counter) are a starting point for Steve to set.
