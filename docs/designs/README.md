# Designs

Design notes: the options weighed before a thing was built, kept for the
reasoning behind what shipped.

- [DESIGN-signed-uid.md](DESIGN-signed-uid.md) — signing `gopher_uid` so a player is re-identified once (built; angry-gopher `uid_cookie.zig`).
- [DESIGN-sessions.md](DESIGN-sessions.md) — sessions and the secret, and the choices around session lifetime (partly built: `/admin/secret`).
- [DESIGN-login-throttle.md](DESIGN-login-throttle.md) — options for limiting password guesses (a stall and a guess on metal's one processor); no code, Steve decides.
