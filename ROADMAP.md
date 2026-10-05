# Omathlete roadmap

## Product promise

Omathlete answers: when does my team play, where can I watch, and what is the
score? It should be fast enough to summon, read, and dismiss without leaving
the keyboard.

## MVP

- Follow individual teams through a searchable picker.
- Show a favorite team's recent/live game and next game.
- Include local start time and broadcast network when ESPN provides it.
- Keep spoiler mode global and persistent.
- Support keyboard and pointer interaction.
- Cache briefly, preserve stale results during provider failures, and refresh
  automatically while the panel is open.
- Require no account, API key, backend, daemon, package installation, or
  elevated privilege.

Initial leagues: NFL, NBA, WNBA, MLB, NHL, college football, men's college
basketball, Premier League, and MLS.

## Next slices

1. Real-desktop accessibility checks across user themes and bar layouts.

## Completed slices

- Team marks and theme-safe team accents.
- Provider fixtures for every supported league and offline/error cases.
- Targeted live refresh and reduced-motion score-change feedback.
- Reversible favorite sorting, manual ordering, and idle bar priority.
- Background kickoff discovery, local countdowns, and refreshing open details.
- Immediate preferences with serialized saves independent of provider requests.
- Atomic game caches, partial-catalog recovery, and per-team data age.
- Cached-first incremental favorites, bounded parallel slates, and virtualized slate rows.
- Selection and viewport preservation across provider updates and automatic sorting.
- Local-date agenda with deduplicated matchups and Today/Tomorrow/Weekend/Seven Days views.
- Persistent watch-later protection and temporary per-game result reveal.
- Opt-in pregame reminders, quiet hours, and persistent delivery deduplication.
- Planner keyboard focus, shortcut help, wrapped names, and long-queue regression checks.
- Optional venue and team records with spoiler-safe display.
- Team-specific retries, missing-data explanations, and privacy-safe diagnostic summaries.
- Scoreboard-driven game transitions, interrupted fixtures, and retained cached finals.
- Age-based live-data warnings in the bar, tooltip, team details, and planner.

## Deliberately deferred

- Following entire leagues
- Standings and calendar export
- Score notifications and reminders while the shell is not running
- Play-by-play and betting lines
- Additional providers and non-team sports
- Account sync
