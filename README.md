# Omathlete

**Your teams. Right on time.**

Omathlete is a keyboard-first sports widget for the Omarchy Quattro bar. It
shows upcoming games, live and recent scores, and broadcast information for
the teams you follow. Spoiler mode is global and persists across shell
restarts.

## Install

```sh
omarchy plugin add https://github.com/chrisroundhill/omathlete.git --enable
```

The plugin ID is `io.github.chrisroundhill.omathlete`.

## Remove

Disable and remove the plugin with:

```sh
omarchy plugin remove io.github.chrisroundhill.omathlete
```

Removal leaves your preferences and short-lived cache in place so reinstalling
does not discard your followed teams. To remove that data as well, delete:

```text
~/.local/state/omarchy/settings/omathlete.json
~/.local/state/omarchy/settings/omathlete-reminders.json
~/.cache/omarchy/omathlete/
```

## Use

- Click the bar widget to open or close it.
- Press `/` to open native team search, then type any team name.
- Press `j`/`k` on favorites or the arrow keys in search to move.
- Press `o` on My Teams to cycle `Manual`, `Next Game`, and `League` sorting.
- In Manual sorting, press `Shift+j`/`Shift+k` to reorder favorites.
- Press `p` to pin the selected team to the idle bar. Live games still take priority.
- Press Enter in search to follow the selected team.
- Press Enter on a favorite to see its latest result and next three games.
- In team details, press `o` to open the selected game on ESPN and `h` or
  Escape to go back.
- Press `a` to temporarily show today's full slate for the leagues represented
  by your favorite teams. Press `a` again to return to My Teams.
- Press `x` or Delete to unfollow the selected team.
- Press `s` to persistently hide or show scores.
- Press `r` to refresh now.
- Press `g` for your sports agenda or `l` for your watch-later queue.
- Press Escape to close.
- Middle-click the bar widget to refresh without opening it.

The bar prioritizes live favorite games, then the earliest upcoming game
across all favorites. Multiple live games rotate every six seconds. Horizontal
bars fit the scoreboard label to its text within a width cap; vertical bars show the Omathlete
scoreboard mark without text. While a game is live, only the affected teams are
refreshed every 15 seconds. A changed score receives a brief, non-animated
highlight unless spoiler mode is enabled.

With the panel closed, schedules refresh every five minutes, increasing to
once a minute within 15 minutes of the next game. Countdown labels update
locally every 15 seconds. Open team details continue updating as games go live
or finish, preserving your selected game when its position changes.

Spoiler, sort, and pin changes appear immediately and save independently of
network refreshes. Hidden scores also replace provider status descriptions
with generic labels so result summaries cannot reveal a winner.

Each team shows when its data was last updated. Provider failures preserve
cached games, and unavailable data is distinguished from an empty schedule.
Partial team-search refreshes retain the failed leagues' previous entries.

Favorites display cached games first, then update individually as requests
finish. Teams without cached data appear as loading placeholders. Full Slate
fetches up to three leagues concurrently and creates rows as you scroll.
Refreshes preserve the selected team/game and its position in the viewport.

## Agenda, watch later, and reminders

The agenda shows followed teams' games for Today, Tomorrow, Weekend
(Saturday–Sunday), or Seven Days. Press `1`–`4` to select a period and `l`
to switch between the agenda and watch-later queue. Dates use your local
timezone. A matchup between two followed teams appears once. Coverage depends
on ESPN's available schedules; the agenda is capped at 32 games per team.
Press `?` or F1 for planner shortcut help. Tab/Shift+Tab focus buttons;
Enter/Space activate them. `j`/`k` move between games and keep the selection
visible, including in long queues. Team names and broadcast information wrap.

Press `w` on an agenda or team-detail game to save it for later. Its scores and revealing
status descriptions stay hidden throughout the widget, including the bar,
until you mark it watched/remove it with `w`. Global spoiler mode still takes
precedence. In the planner, `v` explicitly reveals only the selected result;
moving to another game or closing the planner clears that temporary reveal.
Saved games remain in the queue even after leaving the schedule window. If a
result is no longer cached, `o` opens its ESPN page (which may show spoilers).

Reminders are **off by default**. Press `b` on a game to cycle Off → 15 minutes
before → At start → Off. Reminder messages contain only the matchup, local
start time, and broadcast—not scores. `q` toggles the default local quiet window
of 10 p.m.–8 a.m. Both lists hold up to 32 games.

Reminders run only while the desktop shell/plugin is running, using recently
cached schedules. Delivery is deduplicated across shell restarts. Reminders
missed by more than two minutes are skipped, so resuming the desktop does not
produce a backlog. Removing a followed team stops its cache refreshes and may
prevent its saved reminders from being delivered.

### Game context and troubleshooting

Team details include home/away location, venue, and overall team/opponent records
when ESPN supplies them. Records are hidden whenever that game's result is
protected, including saved watch-later games. Missing TV information means ESPN
did not supply a network; it does not mean the game is untelevised.
Live scores use ESPN's daily scoreboard because team schedules can report the
current inning/clock without scores. A missing score displays `?`, not zero;
stale scoreboard results are not substituted as current scores.
Scoreboard status is reconciled before choosing Live/Latest/Upcoming sections.
Nearby scheduled and completed games are checked too, so a lagging schedule
can transition directly to live or final. Active games use their start-date
scoreboard across midnight (up to 24 hours after the scheduled start).
Delays remain visible; postponed, canceled, and suspended fixtures appear under
Schedule Change instead of counting down as normal upcoming games.

If a later response omits a known final score, the same game's cached final is
retained and labeled with its original score-update age. Live data older than
two minutes, failed refreshes, and failed score requests get explicit freshness
warnings. The bar puts Cached/Stale before live scores, disables its live
highlight while stale, and shows `!` in the icon (including vertical bars).
The tooltip and team/planner views provide more detail. These indicators also
remain visible when spoilers are hidden, without exposing the score or inning.

Team View distinguishes loading, cached fallback, unavailable data, and a
successful response with no upcoming fixtures. An empty schedule is not proof
that a team is out of season. Press `r` there to refresh only that team.
If a refresh is already running, wait for it to finish before retrying.

Press `d` in Team View to show a diagnostic summary. Select its text and copy
with Ctrl+C (Tab focuses the field; Ctrl+A selects all). It contains only
provider identity, aggregate loading/cache counts, and cache age—not favorite
team identities, scores, URLs, local paths, or raw provider responses.

Sorting changes only the current view. Manual order is retained when viewing
teams by next game or league, and the selected sort mode, manual order, and idle
bar pin persist across shell restarts.

Omathlete currently supports NFL, NBA, WNBA, MLB, NHL, college football,
men's college basketball, the Premier League, and MLS.

## Requirements and data

Omathlete uses Python 3.11+ (standard library only), `curl`, `jq`, `flock`
(util-linux), and `omarchy-menu-select`. Python provides no-follow,
descriptor-relative storage operations; it must be available as `/usr/bin/python3`.
It makes direct HTTPS requests to ESPN's undocumented
site JSON API. No account, API key, backend, telemetry, package installation,
or elevated privilege is used.

Preferences are stored in:

```text
~/.local/state/omarchy/settings/omathlete.json
```

Short-lived schedule responses are stored in:

```text
~/.cache/omarchy/omathlete/
```

The corresponding `XDG_STATE_HOME` and `XDG_CACHE_HOME` overrides are supported
only as absolute, non-symlinked paths with trusted ownership. Unsafe storage
fails closed: no automatic `chmod`, symlink repair, or preference migration is
attempted. See [SECURITY.md](SECURITY.md) before relocating these directories.

ESPN's site API is not a supported public developer contract and may change.
Team and league names and logos belong to their respective owners. See
[SECURITY.md](SECURITY.md) for the security model and private reporting policy.

## Develop

Saved files inside an installed user plugin are discovered by the Omarchy
shell. To force discovery or inspect failures:

```sh
omarchy-shell shell rescanPlugins
omarchy plugin list --json
qs log -p "$OMARCHY_PATH/shell" --tail 100
```

Run deterministic provider coverage and the optional live integration check:

```sh
python3 -I tests/storage.py
tests/provider-fixtures.sh
bash tests/reliability.sh
node tests/panel-logic.mjs
node tests/loading.mjs
node tests/slate-view.mjs
node tests/bar-view.mjs
node tests/planner.mjs
node tests/planner-view.mjs
tests/smoke.sh
```

`bash tests/check.sh` runs the complete offline regression gate in one command.
The Omarchy runtime/manifest checks and manual desktop acceptance in
[RELEASE.md](RELEASE.md) remain separate. [AGENTS.md](AGENTS.md) records the
development guardrails for future changes.

Node.js is needed only for development tests, not to run the plugin.
The slate rendering test also uses Qt 6's `qmltestrunner` and QtTest module;
set `QMLTESTRUNNER` if the executable is installed at a nonstandard path.

## License

MIT
