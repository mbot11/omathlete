# Omathlete development guardrails

Work on `dev`. Do not merge, push, tag, release, change protection rules, or
submit marketplace requests without the user's authorization. Preserve existing
user changes. A release tag is immutable; fixes receive a new version.

## Sources of truth

- https://plugins.omarchy.org/develop.html
- https://github.com/omacom/omarchy/blob/quattro/shell/README.md
- https://github.com/omacom/omarchy-plugin-marketplace/blob/main/VERIFICATION.md
- Installed shell interfaces and the repository's SECURITY.md and RELEASE.md.

Recheck current upstream requirements before each publication. The Omarchy skill
is desktop-customization guidance, not a plugin security audit. Use it before
changing desktop settings; never edit packaged Omarchy files or launch a second
desktop Quickshell instance. Isolated Qt test runners are development-only.

## Invariants for every change

- Treat provider responses, saved state, and filesystem paths as untrusted.
- Persistent storage belongs exclusively to `bin/storage.py`. Do not add raw
  XDG-path reads/writes, symlink-following permission changes, or check-then-open
  path guards. Use checked descriptors, bounded reads, and atomic publication.
- `provider.sh` receives only private staging directory FDs; do not give it
  original state/cache paths. Preserve deadlines, decoded-byte ceilings,
  output/cardinality limits, and concurrency limits.
- No shell interpolation of provider/user text, elevated privileges, downloaded
  executable code, account secrets, telemetry, or new endpoints without review.
- Keep dependency changes explicit. Runtime helpers must work on the supported
  Omarchy installation without installing packages during widget operation.
- Preserve keyboard focus/lifecycle, theme-derived fonts/colors, and global
  spoiler protection across bar, panel, agenda, queue, diagnostics, and reminders.

## Required evidence

Run `bash tests/check.sh` for backend/security changes. The storage tests must
run on a filesystem with real root/user ownership; do not relax ownership checks
to accommodate a remapping sandbox. Add adversarial regression coverage whenever
an external-data or filesystem boundary changes. Run `omarchy plugin validate`
and QML lint against installed shell imports before release, plus the desktop
acceptance checklist in RELEASE.md. Report unavailable/untested checks explicitly.

A green CI run or automated marketplace baseline is not security certification.
Record the exact tested commit. For marketplace requests, copy the current form
headings verbatim and do not append extra heading sections. Keep main unchanged
while its exact candidate SHA is under review.
