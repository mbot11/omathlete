#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
export XDG_STATE_HOME="$test_root/state" XDG_CACHE_HOME="$test_root/cache"
export OMATHLETE_TESTING=1 OMATHLETE_CURL_BIN="$repo_dir/tests/fixture-curl"
backend="$repo_dir/bin/omathlete"
cache="$XDG_CACHE_HOME/omarchy/omathlete"
mkdir -p "$XDG_STATE_HOME/omarchy/settings"
state="$XDG_STATE_HOME/omarchy/settings/omathlete.json"
printf '%s\n' '{"schemaVersion":1,"spoilersHidden":false,"teams":[{"sport":"mlb","teamId":"16","teamName":"Chicago Cubs","teamAbbrev":"CHC"}]}' >"$state"

# Schema/normalization failures preserve the previous cache, including its timestamp.
"$backend" detail --no-cache >"$test_root/good.json"
jq -e '.teams[0].updatedAt > 0 and .teams[0].schedule[0].id != ""' "$test_root/good.json" >/dev/null
cp "$cache/mlb-16.json" "$test_root/team-cache.json"
for failure in OMATHLETE_FIXTURE_BAD_SHAPE OMATHLETE_FIXTURE_BAD_EVENT OMATHLETE_FIXTURE_FAILURE; do
  env "$failure=1" "$backend" detail --no-cache >"$test_root/stale.json"
  jq -e --slurpfile good "$test_root/good.json" '
    .stale and .teams[0].stale and .teams[0].updatedAt == $good[0].teams[0].updatedAt
    and .teams[0].schedule == $good[0].teams[0].schedule' "$test_root/stale.json" >/dev/null
  cmp "$cache/mlb-16.json" "$test_root/team-cache.json"
done

"$backend" slate --no-cache >"$test_root/slate.json"
slate_cache="$cache/slate-mlb-$(date +%Y%m%d).json"
cp "$slate_cache" "$test_root/slate-cache.json"
for failure in OMATHLETE_FIXTURE_BAD_SHAPE OMATHLETE_FIXTURE_BAD_EVENT; do
  env "$failure=1" "$backend" slate --no-cache >"$test_root/stale-slate.json"
  jq -e '.stale and .failedLeagues == ["MLB"] and (.games | length) == 2' "$test_root/stale-slate.json" >/dev/null
  cmp "$slate_cache" "$test_root/slate-cache.json"
done

# An outage without cache differs from a successful, empty schedule.
rm "$slate_cache"
OMATHLETE_FIXTURE_FAILURE=1 "$backend" slate --no-cache | jq -e '.stale and .games == [] and .failedLeagues == ["MLB"]' >/dev/null
OMATHLETE_FIXTURE_EMPTY_EVENTS=1 "$backend" slate --no-cache | jq -e '.stale == false and .games == [] and .failedLeagues == []' >/dev/null
OMATHLETE_FIXTURE_EMPTY_EVENTS=1 "$backend" detail --no-cache | jq -e '.teams[0].stale == false and .teams[0].schedule == []' >/dev/null

# Upgrade compatibility with the old array-only slate cache.
jq '.games' "$test_root/slate-cache.json" >"$slate_cache"
OMATHLETE_FIXTURE_FAILURE=1 "$backend" slate --no-cache | jq -e '.stale and (.games | length) == 2' >/dev/null

# A partial catalog update refreshes healthy leagues and retains the failed league.
"$backend" search team >/dev/null
touch -d '8 days ago' "$cache/teams.json"
OMATHLETE_FIXTURE_FAIL_SPORT=mlb OMATHLETE_FIXTURE_CATALOG_PREFIX=New "$backend" search team >/dev/null
jq -e 'length == 9 and any(.[]; .sport == "mlb" and .teamName == "Team 0")
  and any(.[]; .sport == "nfl" and .teamName == "New 0")' "$cache/teams.json" >/dev/null
age=$(( $(date +%s) - $(stat -c %Y "$cache/teams.json") ))
(( age >= 604400 && age < 604800 ))
touch -d '8 days ago' "$cache/teams.json"
cp "$cache/teams.json" "$test_root/catalog.json"
OMATHLETE_FIXTURE_FAILURE=1 "$backend" search team >/dev/null
cmp "$cache/teams.json" "$test_root/catalog.json"

# Concurrent commands must not lose each other's state changes; none need ESPN.
OMATHLETE_FIXTURE_FAILURE=1 "$backend" toggle-spoilers >"$test_root/toggle.json" &
toggle_pid=$!
OMATHLETE_FIXTURE_FAILURE=1 "$backend" cycle-sort >"$test_root/sort.json" &
sort_pid=$!
OMATHLETE_FIXTURE_FAILURE=1 "$backend" toggle-pin mlb 16 >"$test_root/pin.json" &
pin_pid=$!
wait "$toggle_pid" "$sort_pid" "$pin_pid"
"$backend" state | jq -e '.spoilersHidden and .sortMode == "next" and .pinnedTeam.teamId == "16"' >/dev/null
for result in toggle sort pin; do jq -e '.schemaVersion == 1' "$test_root/$result.json" >/dev/null; done
printf 'Omathlete reliability tests passed.\n'
