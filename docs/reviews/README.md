# Reviews

Adversarial reviews, each in `REVIEW-interrupts.md`'s shape: what holds up,
findings by severity with the failure each causes and how likely it is, fix
shapes, and nothing fixed in the review itself (CLOUD.md's "Limits"). Code
and scripts cite these by filename and finding number ("REVIEW-restart-fat32.md
F1").

- [REVIEW-interrupts.md](REVIEW-interrupts.md) — `src/interrupts.zig` and its MSI-X routing; the shape the others follow.
- [REVIEW-two-disks.md](REVIEW-two-disks.md) — the site on the boot disk, chat's data on the volume.
- [REVIEW-request-paths.md](REVIEW-request-paths.md) — every path angry-gopher builds from a request.
- [REVIEW-store.md](REVIEW-store.md) — angry-gopher's `store.zig`.
- [REVIEW-restart-fat32.md](REVIEW-restart-fat32.md) — the restart (item 16) and FAT32 (item 17).
- [REVIEW-admin-host.md](REVIEW-admin-host.md) — `/admin/host`.
- [REVIEW-admin-backup.md](REVIEW-admin-backup.md) — `/admin/backup`.
- [REVIEW-first-line.md](REVIEW-first-line.md) — the boot that printed its first line and stopped.
- [REVIEW-signed-uid-and-limits.md](REVIEW-signed-uid-and-limits.md) — the signed `gopher_uid` and the game store's limits.
- [REVIEW-fixed-sizes.md](REVIEW-fixed-sizes.md) — metal's fixed sizes against data that grows.
