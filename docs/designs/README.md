# Designs

Design notes: the options weighed before a thing was built, kept for the
reasoning behind what shipped.

- [DESIGN-signed-uid.md](DESIGN-signed-uid.md) — signing `gopher_uid` so a player is re-identified once (built; angry-gopher `uid_cookie.zig`).
- [DESIGN-sessions.md](DESIGN-sessions.md) — sessions and the secret, and the choices around session lifetime (partly built: `/admin/secret`).
- [DESIGN-login-throttle.md](DESIGN-login-throttle.md) — options for limiting password guesses (a stall and a guess on metal's one processor) (built; angry-gopher `login_throttle.zig`).
- [DESIGN-picture-cache.md](DESIGN-picture-cache.md) — pictures read whole kept in the page cache, and its cap (built; `page_cache_largest_kib`).
- [DESIGN-sleep.md](DESIGN-sleep.md) — a kernel that sleeps until its application's wake, `between` returning a wake, and the host's fetch (built, on `master`).
