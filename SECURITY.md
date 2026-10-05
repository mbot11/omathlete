# Security policy

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's
private vulnerability reporting for this repository. Include the affected
version, reproduction steps, and expected impact. If private reporting is not
enabled yet, wait until it is available rather than publishing exploit details.

## Security model

Omathlete runs as the current desktop user. It does not request elevated
privileges, accept inbound connections, collect telemetry, or store account
credentials. It writes only its preference and short-lived cache files under
the user's XDG state and cache directories.

### Filesystem trust boundary

`bin/storage.py` walks absolute XDG paths one component at a time with
`O_DIRECTORY | O_NOFOLLOW`, checks descriptor ownership and permissions, and
keeps directory descriptors open for the whole command. Ancestors must belong
to root or the current user and not be group/other-writable (root-owned sticky
directories such as `/tmp` are allowed only as ancestors). Storage leaves must
belong to the current user. Existing directories are never chmodded.

Settings, reminder history, cache files, and the lock must be user-owned regular
files, not symlinks, hardlinks, FIFOs, devices, or group/other-writable files.
Reads open with `O_NOFOLLOW | O_NONBLOCK`, check `fstat`, and enforce byte limits.
The provider receives only private 0700 staging directories through inherited
FDs, never the original XDG paths. Copies preserve cache timestamps. Changed,
allowlisted outputs are staged exclusively and fsynced, then replaced atomically
relative to the held destination FD. Cleanup is descriptor-relative and does
not follow symlinks. Preference mutations retain an exclusive bounded-wait lock
through publication; network-only commands release it after their snapshot.

Cache snapshots inspect at most 4096 directory entries, select at most 64
recognized files, and copy at most 64 MiB. Publication is limited to 128 files
and 64 MiB, in addition to existing per-type limits. The input/output headroom
allows new game/date caches without filling a transaction's file budget.

Symlinked XDG roots or intermediate directories are intentionally unsupported;
we do not silently follow them or migrate user data. Unsafe paths cause a
nonzero exit. Use real, user-owned directories instead. These protections guard
against redirected persistence; they do not sandbox malicious code already
running as the same user, root, or code inside the trusted plugin checkout.

Network requests are limited to ESPN's HTTPS site API and image CDN. Links
opened from game rows must use ESPN's HTTPS website origin. Provider data and
local state are validated before their values become file paths, colors, image
sources, or browser targets.

Provider JSON responses retain a 12-second-or-shorter deadline and are rejected
before parsing if their decompressed body exceeds 8 MiB. Cached and derived
responses have smaller type-specific byte limits. Team catalogs, merged event
feeds, team schedules, league slates, text fields, and the final JSON emitted to
the shell are also explicitly bounded.

Incremental favorite refreshes emit at most 14 newline-delimited messages:
one cached snapshot, up to 12 team updates, and completion. Each message is
limited to 1 MiB and the entire stream to 2 MiB. Full Slate fetches at most
three leagues concurrently; existing response, cache, and output limits apply.

Planner state stores at most 32 watch-later entries and 32 reminder entries,
using validated matchup metadata rather than saved scores. Preferences are
limited to 256 KiB before parsing. The reminder deduplication ledger is capped
at 128 entries and 32 KiB on read. Reminder checking uses local caches and the
desktop notification command; it adds no daemon, account, or external service.

ESPN's site API is undocumented and may change. Team and league names and logos
remain the property of their respective owners; their inclusion does not imply
affiliation or endorsement.

## Supported versions

Until the first stable release, security fixes are applied only to the latest
version on the `main` branch.
