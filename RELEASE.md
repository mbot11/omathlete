# 0.1.3 release checklist

## 0.1.3: storage-hardening gate

Storage-hardening desktop acceptance: owner confirmed loading/refresh,
settings persistence across restart, Watch Later, reminder configuration,
keyboard traversal, and spoiler checks passed on the dev build.
Local automated evidence: full offline suite passed; the final focused run
passed all 12 storage tests and incremental-loading checks. Omarchy manifest
validation and QML lint passed. This does not constitute a security audit.

The historical acceptance recorded below applies to 0.1.2. For 0.1.3:

- Run `bash tests/check.sh`, including hostile storage paths, no-follow reads,
  descriptor-pinned ancestor replacement, safe publication, and concurrency.
- Run `omarchy plugin validate .` and QML lint against the installed shell.
- Confirm Python 3.11+ is available without runtime package installation.
- Recheck desktop loading, settings persistence, reminders, and restart behavior.
- Review SECURITY.md filesystem assumptions, dependencies, endpoint allowlists,
  decoded-response limits, and cancellation/cleanup before tagging a new version.
- Do not move the existing v0.1.2 tag. Publish a new version and update the
  marketplace request with its exact merged SHA, retaining the form's headings.
- Automated checks do not replace review of changed trust boundaries.

Work stays on `dev` until the release is deliberately promoted. This document
does not authorize a merge, push, tag, GitHub release, or marketplace submission.

## Historical 0.1.2 automated gates

Last local verification: 2026-09-08. Deterministic suites, live ESPN smoke,
shell syntax, manifest check, QML lint, and whitespace checks passed. A focused
review checked response/output limits, planner-state validation, browser target
restrictions, and notification argument handling; the tracked-file scan found
no matching private-key or common access-token patterns. This is not an audit.

- Shell syntax and manifest contract from `.github/workflows/ci.yml`.
- Every deterministic test listed in README, including bar geometry and planner selection.
- QML lint against the installed Omarchy shell modules.
- Optional live ESPN smoke test: `tests/smoke.sh` (uses isolated state/cache).
- `git diff --check` and review of the release diff for secrets or local paths.

## Historical 0.1.2 desktop and media gates

- [x] Check Agenda with a crowded list and the active theme; traverse using only the keyboard (user confirmed).
- [x] Remove first/middle/last Watch Later entries; selection remains visible and results stay protected (user confirmed).
- [x] Verify reminder Off / 15m before / At start, quiet hours, and no duplicate notification after reload (user confirmed).
- [x] Confirm compact horizontal spacing; automated vertical geometry checks pass. Vertical runtime remains unverified.
- [x] Capture updated `preview.png` with no private desktop content (user supplied, 2026-09-08).
- [ ] Capture an additional Agenda screenshot (optional promotional material).
- [ ] Record a short keyboard-only demonstration; include spoiler mode and reminders.

The updated preview shows the current home view and compact horizontal bar.
Do not publish a whole-desktop capture containing unrelated applications.

## Promotion

1. Complete the gates and finalize the changelog.
2. Set `manifest.json` to 0.1.3 on `dev` when the candidate is accepted.
3. Push `dev` and open a reviewed PR into `main`.
4. After merge, tag the accepted main commit and create the GitHub release.
5. Follow the marketplace's current exact-commit update/approval process.

Keep `main` stable while any marketplace review of its current commit is pending.
Security checks are regression evidence, not a security certification.
