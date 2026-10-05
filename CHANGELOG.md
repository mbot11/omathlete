# Changelog

## 0.1.3

- Harden state/cache persistence with checked directory descriptors, no-follow bounded reads, private staging, safe locking, and atomic publication.
- Reject symlinked or unsafe storage paths without changing their permissions; require Python 3.11+ for the storage boundary.
- Add hostile-filesystem regression tests, a combined offline gate, and documented plugin-development guardrails.

## 0.1.2

- Local-date Agenda, persistent Watch Later, and opt-in game reminders with quiet hours.
- Keyboard-accessible planner controls, shortcut help, wrapped labels, and stable selection after queue removals.
- Keep Tab/Shift+Tab focus inside Agenda and Watch Later instead of switching to another plugin.
- Suppress kickoff reminders for delayed, suspended, postponed, or canceled games.
- Cached-first incremental loading, preserved navigation, and team-specific retries.
- Venue and team records with spoiler protection; copyable, privacy-safe diagnostics.
- Live scoreboard scores and status reconciliation, interrupted fixtures, overnight games, and retained cached finals.
- Find evening U.S. games on the previous-day ESPN scoreboard when their UTC date differs.
- Explicit score freshness warnings, including compact and vertical bars.
- Theme-consistent fonts and content-sized bar labels to reduce unused space.
- Regression coverage for provider limits, failures, state transitions, keyboard behavior, spoilers, and bar geometry.

## 0.1.1

- Bound remote response bodies, cache sizes, derived collections, and QML output.

## 0.1.0

- Initial keyboard-first favorite-team schedules, scores, broadcasts, and spoiler protection.
