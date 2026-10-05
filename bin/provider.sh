#!/usr/bin/env bash
set -o pipefail

readonly PLUGIN_NAME="Omathlete"
# Only storage.py supplies these inherited, private staging directory descriptors.
[[ ${1:-} =~ ^[0-9]+$ && ${2:-} =~ ^[0-9]+$ ]] || exit 2
readonly STATE_DIR="/proc/self/fd/$1"
readonly CACHE_DIR="/proc/self/fd/$2"
shift 2
readonly STATE_FILE="$STATE_DIR/omathlete.json"
readonly CACHE_TTL=60
readonly CATALOG_TTL=$((7 * 24 * 60 * 60))
readonly MAX_TEAMS=12
readonly MAX_RESPONSE_BYTES=$((8 * 1024 * 1024))
readonly MAX_CATALOG_CACHE_BYTES=$((2 * 1024 * 1024))
readonly MAX_TEAM_CACHE_BYTES=$((64 * 1024))
readonly MAX_SLATE_CACHE_BYTES=$((512 * 1024))
readonly MAX_QML_OUTPUT_BYTES=$((1024 * 1024))
readonly MAX_STREAM_OUTPUT_BYTES=$((2 * 1024 * 1024))
readonly MAX_SLATE_REQUESTS=3
readonly MAX_CATALOG_TEAMS=5000
readonly MAX_MERGED_EVENTS=1000
readonly MAX_UPCOMING_GAMES=3
readonly MAX_TEAM_SCHEDULE_GAMES=5
readonly MAX_SLATE_GAMES_PER_LEAGUE=100
readonly MAX_SLATE_GAMES=500
readonly ESPN_ROOT="https://site.api.espn.com/apis/site/v2/sports"
readonly CATALOG_FILE="$CACHE_DIR/teams.json"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CURL_BIN="/usr/bin/curl"
if [[ ${OMATHLETE_TESTING:-0} == 1 && -n ${OMATHLETE_CURL_BIN:-} ]]; then
  CURL_BIN="$OMATHLETE_CURL_BIN"
fi
readonly CURL_BIN

ensure_storage() {
  [[ -d $STATE_DIR && -d $CACHE_DIR && -f $STATE_FILE ]]
}

read_state() {
  ensure_storage
  if [[ $(stat -c %s "$STATE_FILE") -gt 262144 ]] || ! jq -e '
      .schemaVersion == 1
      and (.spoilersHidden | type) == "boolean"
      and ((.sortMode // "manual") | test("^(manual|next|league)$"))
      and ((.pinnedTeam // null) == null or
        ((.pinnedTeam.sport | type) == "string"
          and (.pinnedTeam.sport | test("^(nfl|nba|wnba|mlb|nhl|cfb|cbb|epl|mls)$"))
          and (.pinnedTeam.teamId | type) == "string"
          and (.pinnedTeam.teamId | test("^[0-9]{1,12}$"))))
      and (.teams | type) == "array"
      and (.teams | length) <= 12
      and all(.teams[];
        (.sport | type) == "string"
        and (.sport | test("^(nfl|nba|wnba|mlb|nhl|cfb|cbb|epl|mls)$"))
        and (.teamId | type) == "string" and (.teamId | test("^[0-9]{1,12}$"))
        and (.teamName | type) == "string" and (.teamName | length) > 0 and (.teamName | length) <= 120
        and (.teamAbbrev | type) == "string" and (.teamAbbrev | length) > 0 and (.teamAbbrev | length) <= 20)
    ' "$STATE_FILE" >/dev/null 2>&1; then
    printf '%s\n' '{"schemaVersion":1,"spoilersHidden":false,"sortMode":"manual","pinnedTeam":null,"teams":[]}'
    return
  fi
  jq -c -L "$SCRIPT_DIR" 'include "planner";
    .teams = .teams[:12]
    | .sortMode = (if (.sortMode // "manual") | test("^(manual|next|league)$")
        then (.sortMode // "manual") else "manual" end)
    | .pinnedTeam = ((.pinnedTeam // null) as $pin
        | if $pin != null and any(.teams[]; .sport == $pin.sport and .teamId == $pin.teamId)
          then {sport:$pin.sport,teamId:$pin.teamId} else null end)
    | planner_state
    | {schemaVersion,spoilersHidden,sortMode,pinnedTeam,teams,watchLater,reminders,quietHours}
  ' "$STATE_FILE"
}

write_state() {
  local value="$1" tmp
  tmp=$(mktemp "$STATE_DIR/.omathlete.XXXXXX") || return 1
  printf '%s\n' "$value" >"$tmp"
  /usr/bin/chmod 600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

write_cache() {
  local path="$1" value="$2" max_bytes="$3" tmp size
  tmp=$(mktemp "$CACHE_DIR/.cache.XXXXXX") || return 1
  printf '%s\n' "$value" >"$tmp"
  size=$(stat -c %s "$tmp") || { rm -f "$tmp"; return 1; }
  if (( size > max_bytes )); then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$path"
}

valid_json_file() {
  local path="$1" max_bytes="$2" size
  [[ -f $path ]] || return 1
  size=$(stat -c %s "$path") || return 1
  (( size > 0 && size <= max_bytes )) || return 1
  jq -e 'type == "object" or type == "array"' "$path" >/dev/null 2>&1
}

bounded_output() {
  local max_bytes="$1" tmp size
  tmp=$(mktemp "$CACHE_DIR/.output.XXXXXX") || return 1
  /usr/bin/head -c "$((max_bytes + 1))" >"$tmp"
  size=$(stat -c %s "$tmp") || { rm -f "$tmp"; return 1; }
  if (( size > max_bytes )); then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

sport_rows() {
  printf '\tNFL\tnfl\n'
  printf '\tNBA\tnba\n'
  printf '\tWNBA\twnba\n'
  printf '\tMLB\tmlb\n'
  printf '\tNHL\tnhl\n'
  printf '\tCollege Football\tcfb\n'
  printf '\tCollege Basketball\tcbb\n'
  printf '\tPremier League\tepl\n'
  printf '\tMLS\tmls\n'
}

espn_path() {
  case "$1" in
    nfl) printf 'football/nfl' ;;
    nba) printf 'basketball/nba' ;;
    wnba) printf 'basketball/wnba' ;;
    mlb) printf 'baseball/mlb' ;;
    nhl) printf 'hockey/nhl' ;;
    cfb) printf 'football/college-football' ;;
    cbb) printf 'basketball/mens-college-basketball' ;;
    epl) printf 'soccer/eng.1' ;;
    mls) printf 'soccer/usa.1' ;;
    *) return 1 ;;
  esac
}

sport_label() {
  case "$1" in
    nfl) printf 'NFL' ;; nba) printf 'NBA' ;; wnba) printf 'WNBA' ;;
    mlb) printf 'MLB' ;; nhl) printf 'NHL' ;; cfb) printf 'College Football' ;;
    cbb) printf 'College Basketball' ;; epl) printf 'Premier League' ;; mls) printf 'MLS' ;;
    *) printf '%s' "$1" ;;
  esac
}

notify() {
  if command -v omarchy-notification-send >/dev/null 2>&1; then
    omarchy-notification-send "$PLUGIN_NAME" "$1" >/dev/null 2>&1 || true
  fi
}

fetch_json() {
  local url="$1" deadline="${2:-10}" tmp size
  tmp=$(mktemp "$CACHE_DIR/.response.XXXXXX") || return 1
  if ! "$CURL_BIN" -fsS --compressed --max-time "$deadline" \
      --max-filesize "$MAX_RESPONSE_BYTES" "$url" \
      | /usr/bin/head -c "$((MAX_RESPONSE_BYTES + 1))" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  size=$(stat -c %s "$tmp") || { rm -f "$tmp"; return 1; }
  if (( size > MAX_RESPONSE_BYTES )) || ! jq -e 'type == "object" or type == "array"' \
      "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  cat "$tmp"
  rm -f "$tmp"
}

fetch_teams() {
  local path="$1"
  fetch_json "$ESPN_ROOT/$path/teams?limit=1000" 10 \
    | jq -r '(.sports[0].leagues[0].teams // [])[:1000][].team
      | select((.id | tostring) | test("^[0-9]{1,12}$"))
      | [(.displayName | tostring)[:120], (.id | tostring),
          ((.abbreviation // .shortDisplayName // .displayName) | tostring)[:20]] | @tsv' \
    | sort
}

catalog_sports() {
  printf '%s\n' nfl nba wnba mlb nhl cfb cbb epl mls
}

refresh_catalog() {
  local work sport path label part index failed=0
  work=$(mktemp -d "$CACHE_DIR/.catalog.XXXXXX") || return 1
  declare -a pids=()
  declare -a sports=()

  while IFS= read -r sport; do
    path=$(espn_path "$sport") || continue
    label=$(sport_label "$sport")
    part="$work/$sport.json"
    (
      fetch_json "$ESPN_ROOT/$path/teams?limit=1000" 12 \
        | jq -ce --arg sport "$sport" --arg league "$label" '
          if (.sports[0].leagues[0].teams | type) != "array" then error("Invalid teams") else . end |
          [(.sports[0].leagues[0].teams // [])[:1000][].team
          | select((.id | tostring) | test("^[0-9]{1,12}$")) | {
            sport:$sport,
            teamId:(.id | tostring),
            teamName:(.displayName | tostring)[:120],
            teamAbbrev:((.abbreviation // .shortDisplayName // .displayName) | tostring)[:20],
            league:$league
          }]'
    ) >"$part" &
    pids+=("$!")
    sports+=("$sport")
  done < <(catalog_sports)

  for index in "${!pids[@]}"; do
    if ! wait "${pids[index]}"; then
      failed=$((failed + 1))
      sport="${sports[index]}"
      part="$work/$sport.json"
      if valid_json_file "$CATALOG_FILE" "$MAX_CATALOG_CACHE_BYTES"; then
        jq -c --arg sport "$sport" '[.[] | select(.sport == $sport)]' "$CATALOG_FILE" >"$part"
      else
        printf '[]\n' >"$part"
      fi
    fi
  done

  if (( failed == ${#pids[@]} )); then
    rm -rf "$work"
    return 1
  fi

  if ! jq -sc --argjson max "$MAX_CATALOG_TEAMS" \
      'add | map(select(.teamId and .teamName)) | unique_by(.sport + ":" + .teamId) | .[:$max]' \
      "$work"/*.json >"$work/teams.json" \
      || ! valid_json_file "$work/teams.json" "$MAX_CATALOG_CACHE_BYTES"; then
    rm -rf "$work"
    return 1
  fi
  mv -f "$work/teams.json" "$CATALOG_FILE"
  # Retry partial catalogs soon while keeping successfully fetched leagues usable.
  if (( failed > 0 )); then
    touch -d "@$(( $(date +%s) - CATALOG_TTL + 300 ))" "$CATALOG_FILE"
  fi
  rm -rf "$work"
  (( failed == 0 ))
}

ensure_catalog() {
  local age
  ensure_storage
  if valid_json_file "$CATALOG_FILE" "$MAX_CATALOG_CACHE_BYTES"; then
    age=$(( $(date +%s) - $(stat -c %Y "$CATALOG_FILE") ))
    (( age < CATALOG_TTL )) && return
  fi
  refresh_catalog || [[ -s "$CATALOG_FILE" ]]
}

search_teams() {
  local query="${1:-}"
  [[ ${#query} -ge 2 ]] || { printf '%s\n' '[]'; return; }
  ensure_catalog || { printf '%s\n' '[]'; return 1; }
  jq -c --arg query "${query,,}" '
    [$query as $q | .[]
      | select((.teamName | ascii_downcase | contains($q))
        or (.teamAbbrev | ascii_downcase | contains($q))
        or (.league | ascii_downcase | contains($q)))
      | . + {rank:(if (.teamName | ascii_downcase | startswith($q)) then 0
        elif (.teamAbbrev | ascii_downcase) == $q then 1 else 2 end)}]
    | sort_by(.rank, .teamName)
    | .[:12]
    | map(del(.rank))
  ' "$CATALOG_FILE"
}

follow_team() {
  local sport="$1" team_id="$2" state count team updated
  ensure_catalog || return 1
  team=$(jq -c --arg sport "$sport" --arg id "$team_id" \
    '[.[] | select(.sport == $sport and .teamId == $id)][0] // empty' "$CATALOG_FILE")
  [[ -n $team ]] || { notify "That team is no longer available."; return 1; }
  state=$(read_state)
  if jq -e --arg sport "$sport" --arg id "$team_id" \
      'any(.teams[]; .sport == $sport and .teamId == $id)' <<<"$state" >/dev/null; then
    notify "$(jq -r '.teamName' <<<"$team") is already followed."
    return
  fi
  count=$(jq '.teams | length' <<<"$state")
  (( count < MAX_TEAMS )) || { notify "You can follow up to $MAX_TEAMS teams."; return 1; }
  updated=$(jq -c --argjson team "$team" '.teams += [$team | del(.league)]' <<<"$state")
  write_state "$updated" || return 1
  notify "Following $(jq -r '.teamName' <<<"$team")"
}

add_team() {
  local state count sport_line sport path rows selection name team_id abbrev updated
  state=$(read_state)
  count=$(jq '.teams | length' <<<"$state")
  if (( count >= MAX_TEAMS )); then
    notify "You can follow up to $MAX_TEAMS teams."
    return 1
  fi

  sport_line=$(sport_rows | omarchy-menu-select "Omathlete · choose a sport" -- --width 440) || return
  sport="${sport_line##*$'\t'}"
  path=$(espn_path "$sport") || return 1
  rows=$(fetch_teams "$path") || { notify "Could not load teams."; return 1; }
  selection=$(printf '%s\n' "$rows" | awk -F'\t' '{print "\t" $1 "\t" $2 ":" $3}' \
    | omarchy-menu-select "Omathlete · search teams" -- --width 500 --maxheight 560) || return
  name="${selection%%$'\t'*}"
  name="${name#$'\t'}"
  local key="${selection##*$'\t'}"
  team_id="${key%%:*}"
  abbrev="${key#*:}"

  if jq -e --arg sport "$sport" --arg id "$team_id" \
      'any(.teams[]; .sport == $sport and .teamId == $id)' <<<"$state" >/dev/null; then
    notify "$name is already followed."
    return
  fi

  updated=$(jq -c --arg sport "$sport" --arg id "$team_id" --arg name "$name" --arg abbrev "$abbrev" \
    '.teams += [{sport:$sport, teamId:$id, teamName:$name, teamAbbrev:$abbrev}]' <<<"$state")
  write_state "$updated" || return 1
  notify "Following $name"
}

remove_team() {
  local sport="$1" team_id="$2" state updated name
  state=$(read_state)
  name=$(jq -r --arg sport "$sport" --arg id "$team_id" \
    '[.teams[] | select(.sport == $sport and .teamId == $id) | .teamName][0] // "Team"' <<<"$state")
  updated=$(jq -c --arg sport "$sport" --arg id "$team_id" \
    '.teams |= map(select(.sport != $sport or .teamId != $id))
      | if .pinnedTeam != null and .pinnedTeam.sport == $sport and .pinnedTeam.teamId == $id
        then .pinnedTeam = null else . end' <<<"$state")
  write_state "$updated" || return 1
  rm -f "$CACHE_DIR/${sport}-${team_id}.json"
  notify "Stopped following $name"
}

toggle_spoilers() {
  local state updated hidden
  state=$(read_state)
  updated=$(jq -c '.spoilersHidden = (.spoilersHidden | not)' <<<"$state")
  write_state "$updated" || return 1
  hidden=$(jq -r '.spoilersHidden' <<<"$updated")
  [[ $hidden == true ]] && notify "Scores hidden" || notify "Scores visible"
}

cycle_sort() {
  local state updated mode
  state=$(read_state)
  updated=$(jq -c '.sortMode = (if .sortMode == "manual" then "next"
    elif .sortMode == "next" then "league" else "manual" end)' <<<"$state")
  write_state "$updated" || return 1
  mode=$(jq -r '.sortMode' <<<"$updated")
  notify "Sort: ${mode^}"
}

move_team() {
  local sport="$1" team_id="$2" direction="$3" state updated
  [[ $direction == -1 || $direction == 1 ]] || return 2
  state=$(read_state)
  [[ $(jq -r '.sortMode' <<<"$state") == manual ]] || return 1
  updated=$(jq -c --arg sport "$sport" --arg id "$team_id" --argjson direction "$direction" '
    ([.teams | to_entries[] | select(.value.sport == $sport and .value.teamId == $id) | .key][0]) as $from
    | if $from == null then . else ($from + $direction) as $to
      | if $to < 0 or $to >= (.teams | length) then .
        else .teams[$from] as $team
          | .teams[$from] = .teams[$to]
          | .teams[$to] = $team
        end
      end
  ' <<<"$state")
  write_state "$updated" || return 1
}

toggle_pin() {
  local sport="$1" team_id="$2" state updated name
  state=$(read_state)
  name=$(jq -r --arg sport "$sport" --arg id "$team_id" '
    [.teams[] | select(.sport == $sport and .teamId == $id) | .teamName][0] // empty' <<<"$state")
  [[ -n $name ]] || return 1
  updated=$(jq -c --arg sport "$sport" --arg id "$team_id" '
    if .pinnedTeam != null and .pinnedTeam.sport == $sport and .pinnedTeam.teamId == $id
    then .pinnedTeam = null else .pinnedTeam = {sport:$sport,teamId:$id} end' <<<"$state")
  write_state "$updated" || return 1
  if [[ $(jq -r '.pinnedTeam == null' <<<"$updated") == true ]]; then
    notify "Idle bar pin cleared"
  else
    notify "Pinned $name to the idle bar"
  fi
}

stale_team() {
  local team="$1" cache_file="$2"
  if valid_json_file "$cache_file" "$MAX_TEAM_CACHE_BYTES" \
      && jq -e '.teamId and (.schedule | type == "array")' "$cache_file" >/dev/null 2>&1; then
    jq -c '. + {stale:true}' "$cache_file"
  else
    jq -c '. + {teamLogo:"",teamColor:"",teamAlternateColor:"",current:null,
      upcoming:null,schedule:[],stale:true,updatedAt:null}' <<<"$team"
  fi
}

team_detail() {
  local team="$1" no_cache="$2" sport team_id name abbrev path cache_file age payload regular
  local season_year now league_cache league_payload league_age merged_payload normalized
  local live_date live_scores='{"games":[]}' previous='{}' prior_date prior_scores
  sport=$(jq -r '.sport' <<<"$team")
  team_id=$(jq -r '.teamId' <<<"$team")
  name=$(jq -r '.teamName' <<<"$team")
  abbrev=$(jq -r '.teamAbbrev' <<<"$team")
  path=$(espn_path "$sport") || return 1
  cache_file="$CACHE_DIR/${sport}-${team_id}.json"

  if [[ $no_cache == false && -f "$cache_file" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$cache_file") ))
    if (( age < CACHE_TTL )) && valid_json_file "$cache_file" "$MAX_TEAM_CACHE_BYTES"; then
      cat "$cache_file"
      return
    fi
  fi

  if ! payload=$(fetch_json "$ESPN_ROOT/$path/teams/$team_id/schedule" 10) \
      || ! jq -e 'type == "object" and (.events | type == "array")' <<<"$payload" >/dev/null 2>&1; then
    stale_team "$team" "$cache_file"
    return
  fi

  now=$(date -u +%s)

  # ESPN defaults football team schedules to preseason during the late-summer
  # handoff. Merge the same season's regular schedule so the latest exhibition
  # result and the next meaningful games are both available.
  if [[ $sport == nfl || $sport == cfb ]]; then
    season_year=$(jq -r '.season.year // empty' <<<"$payload" 2>/dev/null)
    if [[ $season_year =~ ^[0-9]{4}$ ]] && regular=$(fetch_json \
        "$ESPN_ROOT/$path/teams/$team_id/schedule?season=$season_year&seasontype=2" 10); then
      payload=$(printf '%s\n%s\n' "$payload" "$regular" | jq -sc \
        --argjson max "$MAX_MERGED_EVENTS" '
        .[0] as $base | .[1] as $regular | $base
        | .events = (($base.events + $regular.events) | unique_by(.id) | .[:$max])')
    fi
  fi

  # ESPN's soccer team endpoints can lag behind their league scoreboards
  # and omit scheduled fixtures. Only fall back when no future game exists,
  # and share each league response across its followed teams.
  if [[ $sport == epl || $sport == mls ]]; then
    season_year=$(jq -r '.season.year // empty' <<<"$payload" 2>/dev/null)
    if [[ $season_year =~ ^[0-9]{4}$ ]] && ! jq -e --argjson now "$now" '
        any((.events // [])[];
          .competitions[0].status.type.state == "pre"
          and ((.date | if test("T[0-9]{2}:[0-9]{2}Z$") then sub("Z$"; ":00Z") else . end
            | try fromdateiso8601 catch 0) >= ($now - 3600)))
      ' <<<"$payload" >/dev/null 2>&1; then
      league_cache="$CACHE_DIR/$sport-$season_year.json"
      league_payload=""
      if [[ $no_cache == false && -f $league_cache ]]; then
        league_age=$(( $(date +%s) - $(stat -c %Y "$league_cache") ))
        if (( league_age < CACHE_TTL )) && valid_json_file "$league_cache" "$MAX_RESPONSE_BYTES"; then
          league_payload=$(cat "$league_cache")
        fi
      fi
      if [[ -z $league_payload ]] && league_payload=$(fetch_json \
          "$ESPN_ROOT/$path/scoreboard?dates=$season_year&limit=1000" 10); then
        write_cache "$league_cache" "$league_payload" "$MAX_RESPONSE_BYTES"
      fi
      if [[ -n $league_payload ]]; then
        if merged_payload=$(printf '%s\n%s\n' "$payload" "$league_payload" | jq -sc \
          --arg id "$team_id" --argjson max "$MAX_MERGED_EVENTS" '
          .[0] as $base | .[1] as $league | $base
          | .events = (($base.events + [($league.events // [])[]
              | select(any(.competitions[0].competitors[]?; .team.id == $id))][:200])
            | unique_by(.id) | .[:$max])' 2>/dev/null); then
          payload="$merged_payload"
        fi
      fi
    fi
  fi

  # Team schedules can update the inning/clock while omitting live scores.
  # Reuse the bounded daily scoreboard, matching exact event IDs below.
  live_date=$(jq -r --argjson now "$now" '
    [.events | sort_by((if .competitions[0].status.type.state == "in" then 1 else 0 end), .date) | reverse | .[]
      | .date | select(type == "string")
      | (if test("T[0-9]{2}:[0-9]{2}Z$") then sub("Z$"; ":00Z") else . end)
      | select((try fromdateiso8601 catch 0) >= ($now - 86400)
        and (try fromdateiso8601 catch 0) <= ($now + 3600))]
    | first // "" | .[:10] | gsub("-"; "")' <<<"$payload" 2>/dev/null) || live_date=""
  if [[ $live_date =~ ^[0-9]{8}$ ]]; then
    live_scores=$(slate_sport "$sport" "$live_date" "$no_cache") || live_scores='{"games":[]}'
    # ESPN may file an evening U.S. game under the day before its UTC start
    # date. Try exactly one adjacent day when a scheduled live event is absent.
    if jq -e --argjson board "$live_scores" '
      any(.events[]; . as $event | .competitions[0].status.type.state == "in"
        and ([ $board.games[]? | select(.id == ($event.id | tostring) and .stale != true) ] | length == 0))
      ' <<<"$payload" >/dev/null 2>&1; then
      prior_date=$(date -u -d "${live_date:0:4}-${live_date:4:2}-${live_date:6:2} -1 day" +%Y%m%d)
      prior_scores=$(slate_sport "$sport" "$prior_date" "$no_cache") || prior_scores='{"games":[],"stale":true}'
      live_scores=$(printf '%s\n%s\n' "$live_scores" "$prior_scores" | jq -sc '
        {games:([.[].games[]?] | group_by(.id) | map(sort_by(.stale) | first)),
         stale:any(.[]; .stale == true)}')
    fi
  fi
  if valid_json_file "$cache_file" "$MAX_TEAM_CACHE_BYTES"; then previous=$(cat "$cache_file"); fi

  if normalized=$(jq -ce --arg sport "$sport" --arg id "$team_id" --arg name "$name" --arg abbrev "$abbrev" \
    --argjson liveScores "$live_scores" \
    --argjson previous "$previous" \
    --argjson now "$now" --argjson maxUpcoming "$MAX_UPCOMING_GAMES" \
    --argjson maxSchedule "$MAX_TEAM_SCHEDULE_GAMES" '
      def epoch:
        (if test("T[0-9]{2}:[0-9]{2}Z$") then sub("Z$"; ":00Z") else . end)
        | try fromdateiso8601 catch 0;
      def side($event; $where): [$event.competitions[0].competitors[]? | select(.homeAway == $where)][0];
      def text($length): tostring | .[:$length];
      def scoreboard($event): [$liveScores.games[]? | select(.id == ($event.id | tostring) and .stale != true)][0];
      def interrupted: (.competitions[0].status.type.name // "") | test("POSTPONED|CANCELED|CANCELLED|SUSPENDED");
      def view($event):
        (side($event; "home")) as $home |
        (side($event; "away")) as $away |
        ($home.team.id == $id) as $isHome |
        (if $isHome then $home else $away end) as $mine |
        (if $isHome then $away else $home end) as $other |
        scoreboard($event) as $liveScore |
        ([($previous.schedule // [])[], ($previous.agenda // [])[], $previous.current
          | select(. != null and .id == ($event.id | tostring) and .state == "post"
            and .teamScore != "?" and .opponentScore != "?")][0]) as $oldFinal |
        (if $event.competitions[0].status.type.state == "post" and $liveScore == null
          and ($mine.score == null or $other.score == null) then $oldFinal else null end) as $savedFinal |
        {
          id: (($event.id // "") | text(64)),
          homeTeam: (($home.team.abbreviation // $home.team.displayName // "TBD") | text(40)),
          awayTeam: (($away.team.abbreviation // $away.team.displayName // "TBD") | text(40)),
          state: (($liveScore.state // $event.competitions[0].status.type.state // "pre") | text(12)),
          detail: (($liveScore.detail // $event.competitions[0].status.type.shortDetail // "Scheduled") | text(120)),
          statusName: (($event.competitions[0].status.type.name // "") | text(64)),
          scoreCached: ($savedFinal != null),
          scoreUpdatedAt: (if $savedFinal != null then ($savedFinal.scoreUpdatedAt // $previous.updatedAt) else $now end),
          scoreStale: ($event.competitions[0].status.type.state == "in"
            and $liveScore == null and ($liveScores.stale == true or $mine.score == null or $other.score == null)),
          isHome: $isHome,
          venue: (($event.competitions[0].venue.fullName // "") | text(120)),
          teamRecord: (([$mine.records[]? | select(.type == "total" or .name == "overall") | .summary][0] // "") | text(40)),
          opponentRecord: (([$other.records[]? | select(.type == "total" or .name == "overall") | .summary][0] // "") | text(40)),
          opponent: (($other.team.abbreviation // $other.team.displayName // "TBD") | text(40)),
          teamScore: ((if $liveScore then (if $isHome then $liveScore.homeScore else $liveScore.awayScore end)
            elif $savedFinal then $savedFinal.teamScore
            elif ($mine.score | type) == "object" then ($mine.score.displayValue // $mine.score.value)
            else $mine.score end) // "?" | text(20)),
          opponentScore: ((if $liveScore then (if $isHome then $liveScore.awayScore else $liveScore.homeScore end)
            elif $savedFinal then $savedFinal.opponentScore
            elif ($other.score | type) == "object" then ($other.score.displayValue // $other.score.value)
            else $other.score end) // "?" | text(20)),
          date: ($event.date | text(64)),
          when: (($event.date | epoch) | strflocaltime("%a, %b %-d · %-I:%M %p")),
          broadcast: (($event.competitions[0].broadcasts[0].media.shortName
            // $event.competitions[0].broadcasts[0].names[0] // "") | text(80)),
          gameUrl: (([($event.links // [])[]
            | select((.href // "") | test("^https://www\\.espn\\.com/"))
            | select((.rel // []) | index("summary"))
            | select((.rel // []) | index("desktop"))
            | .href][0] // "") | text(512))
        };
      # Reconcile state before choosing live/recent/upcoming sections.
      [(.events // [])[] | . as $event | scoreboard($event) as $score
        | if $score != null then .competitions[0].status.type += {
            state:$score.state, shortDetail:$score.detail, name:($score.statusName // "")}
          else . end] as $events |
      (.team // {}) as $team |
      (($team.logo // "") | text(512)) as $logo |
      (if ($logo | test("^https://a\\.espncdn\\.com/")) then $logo else "" end) as $teamLogo |
      (if (($team.color // "") | test("^[0-9A-Fa-f]{6}$"))
        then ("#" + $team.color) else "" end) as $teamColor |
      (if (($team.alternateColor // "") | test("^[0-9A-Fa-f]{6}$"))
        then ("#" + $team.alternateColor) else "" end) as $teamAlternateColor |
      ([$events[] | select(.competitions[0].status.type.state == "in")
        | select(interrupted | not)
        | select((.date | epoch) <= ($now + 3600))] | sort_by(.date) | last) as $live |
      ([$events[] | select(.competitions[0].status.type.state == "post")
        | select(interrupted | not)
        | select((.date | epoch) <= ($now + 3600))] | sort_by(.date) | last) as $recent |
      ([$events[] | select(.competitions[0].status.type.state == "pre")
        | select(interrupted | not)
        | select((.date | epoch) >= ($now - 3600)
          or ((.competitions[0].status.type.name // "") == "STATUS_DELAYED" and (.date | epoch) >= ($now - 86400)))] | sort_by(.date) | .[:$maxUpcoming]) as $nextGames |
      ([$events[] | select(interrupted) | select((.date | epoch) >= ($now - 86400))]
        | sort_by(.date) | .[:1]) as $interruptions |
      ($nextGames[0] // null) as $next |
      ((if $live then [(view($live) + {kind:"live", section:"LIVE"})] else [] end)
        + (if $recent then [(view($recent) + {kind:"recent", section:"LATEST"})] else [] end)
        + [$interruptions[] | (view(.) + {kind:"interrupted",section:"SCHEDULE CHANGE"})]
        + [$nextGames[] | (view(.) + {kind:"upcoming", section:"UPCOMING"})]
        | .[:$maxSchedule]) as $schedule |
      {
        sport:$sport, teamId:$id, teamName:$name, teamAbbrev:$abbrev,
        teamLogo:$teamLogo, teamColor:$teamColor, teamAlternateColor:$teamAlternateColor,
        current: (if $live then view($live) elif $recent then view($recent) else null end),
        upcoming: (if $next then (view($next) + {
          relative: (if (($next.date | epoch) - $now) < 86400 then
            (((((($next.date | epoch) - $now) / 3600) | floor | tostring) + "h"))
          else (($next.date | epoch) | strflocaltime("%a")) end)
        }) else null end),
        schedule:$schedule,
        agenda: ([$events[] | select((.date | epoch) >= ($now - 86400)
          and (.date | epoch) <= ($now + 8 * 86400))] | sort_by(.date) | .[:32] | map(view(.))),
        stale:false, updatedAt:$now
      }
    ' <<<"$payload" 2>/dev/null | bounded_output "$MAX_TEAM_CACHE_BYTES") \
      && [[ -n $normalized ]] && write_cache "$cache_file" "$normalized" "$MAX_TEAM_CACHE_BYTES"; then
    printf '%s\n' "$normalized"
  else
    stale_team "$team" "$cache_file"
  fi
}

detail() {
  local no_cache=false live_only=false state spoilers sort_mode pinned count index team item key requested
  local work pid force_team stale=false running=0 max_jobs=8
  local -a items=() live_keys=() pids=()
  if [[ ${1:-} == "--no-cache" ]]; then
    no_cache=true
  elif [[ ${1:-} == "--live" ]]; then
    live_only=true
    shift
    live_keys=("$@")
  fi
  state=$(read_state)
  spoilers=$(jq -r '.spoilersHidden' <<<"$state")
  sort_mode=$(jq -r '.sortMode' <<<"$state")
  pinned=$(jq -c '.pinnedTeam' <<<"$state")
  count=$(jq '.teams | length' <<<"$state")
  work=$(mktemp -d "$CACHE_DIR/.detail.XXXXXX") || return 1
  for ((index=0; index<count; index++)); do
    team=$(jq -c ".teams[$index]" <<<"$state")
    force_team="$no_cache"
    if [[ $live_only == true ]]; then
      force_team=false
      key="$(jq -r '.sport + ":" + .teamId' <<<"$team")"
      for requested in "${live_keys[@]}"; do
        if [[ $requested == "$key" ]]; then force_team=true; break; fi
      done
    fi
    (team_detail "$team" "$force_team" >"$work/$index.json") &
    pids[index]=$!
    (( ++running >= max_jobs )) && { wait -n 2>/dev/null || true; (( --running )); }
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  for ((index=0; index<count; index++)); do
    [[ -s $work/$index.json ]] || continue
    item=$(cat "$work/$index.json")
    jq -e 'type == "object"' <<<"$item" >/dev/null 2>&1 || continue
    [[ $(jq -r '.stale // false' <<<"$item") == true ]] && stale=true
    items+=("$item")
  done
  rm -rf "$work"
  if ((${#items[@]})); then
    printf '%s\n' "${items[@]}" | jq -sc --argjson hidden "$spoilers" --argjson stale "$stale" \
      --arg sortMode "$sort_mode" --argjson pinnedTeam "$pinned" \
      '. as $teams | {
        schemaVersion:1,
        spoilersHidden:$hidden,
        sortMode:$sortMode,
        pinnedTeam:$pinnedTeam,
        stale:$stale,
        teams:$teams,
        primary: (
          ([$teams[] | select(.current.state == "in")] | sort_by(.current.date) | first)
          // ([$teams[] | select(.upcoming != null)] | sort_by(.upcoming.date) | first)
          // null
        )
        }' | bounded_output "$MAX_QML_OUTPUT_BYTES"
  else
    jq -cn --argjson hidden "$spoilers" --arg sortMode "$sort_mode" --argjson pinnedTeam "$pinned" \
      '{schemaVersion:1,spoilersHidden:$hidden,sortMode:$sortMode,pinnedTeam:$pinnedTeam,stale:false,teams:[],primary:null}' \
      | bounded_output "$MAX_QML_OUTPUT_BYTES"
  fi
}

team_snapshot() {
  local team="$1" path age
  path="$CACHE_DIR/$(jq -r '.sport + "-" + .teamId' <<<"$team").json"
  if valid_json_file "$path" "$MAX_TEAM_CACHE_BYTES" \
      && jq -e '.teamId and (.schedule | type == "array")' "$path" >/dev/null 2>&1; then
    age=$(( $(date +%s) - $(stat -c %Y "$path") ))
    jq -c --argjson stale "$([[ $age -ge $CACHE_TTL ]] && printf true || printf false)" \
      '. + {stale:$stale,loading:true}' "$path"
  else
    jq -c '. + {current:null,upcoming:null,schedule:[],stale:false,loading:true,updatedAt:null}' <<<"$team"
  fi
}

# One parent writes complete JSON lines: children never interleave stdout.
# At most one snapshot + twelve team updates + a completion message are emitted.
stream_emit() {
  local LC_ALL=C
  local line="$1" size
  size=$((${#line} + 1))
  (( size <= MAX_QML_OUTPUT_BYTES && stream_bytes + size <= MAX_STREAM_OUTPUT_BYTES )) || return 1
  stream_bytes=$((stream_bytes + size))
  printf '%s\n' "$line"
}

detail_stream() (
  local state work index team finished force=false key requested stream_bytes=0
  local -a teams=() snapshots=() live_keys=()
  local -A jobs=()
  [[ ${1:-} == --no-cache ]] && force=true
  if [[ ${1:-} == --live ]]; then shift; live_keys=("$@"); fi
  state=$(read_state)
  if [[ ${1:-} == --team ]]; then
    state=$(jq -c --arg key "${2:-}" '.teams |= map(select((.sport + ":" + .teamId) == $key))' <<<"$state")
    force=true
  fi
  work=$(mktemp -d "$CACHE_DIR/.stream.XXXXXX") || exit 1
  trap 'if ((${#jobs[@]})); then kill "${!jobs[@]}" 2>/dev/null || true; wait "${!jobs[@]}" 2>/dev/null || true; fi; rm -rf "$work"' EXIT
  mapfile -t teams < <(jq -c '.teams[]' <<<"$state")
  for team in "${teams[@]}"; do snapshots+=("$(team_snapshot "$team")"); done
  stream_emit "$(printf '%s\n' "${snapshots[@]}" | jq -sc '{type:"snapshot",teams:.}')" || exit 1
  for index in "${!teams[@]}"; do
    team="${teams[index]}"
    local force_team="$force"
    key=$(jq -r '.sport + ":" + .teamId' <<<"$team")
    for requested in "${live_keys[@]}"; do
      [[ $requested == "$key" ]] && force_team=true
    done
    (team_detail "$team" "$force_team" >"$work/$index.json") &
    jobs[$!]="$index"
  done
  while ((${#jobs[@]})); do
    finished=""
    wait -n -p finished "${!jobs[@]}" || true
    [[ -n $finished ]] || exit 1
    index="${jobs[$finished]}"
    unset 'jobs[$finished]'
    if valid_json_file "$work/$index.json" "$MAX_TEAM_CACHE_BYTES" \
        && jq -e 'type == "object" and .teamId and (.schedule | type == "array")' \
          "$work/$index.json" >/dev/null 2>&1; then
      team=$(cat "$work/$index.json")
    else
      key=$(jq -r '.sport + "-" + .teamId' <<<"${teams[index]}")
      team=$(stale_team "${teams[index]}" "$CACHE_DIR/$key.json")
    fi
    stream_emit "$(jq -c '{type:"team",team:(. + {loading:false})}' <<<"$team")" || exit 1
  done
  stream_emit '{"type":"done"}'
)

cached_slate() {
  local cache_file="$1" stale="$2"
  valid_json_file "$cache_file" "$MAX_SLATE_CACHE_BYTES" || return 1
  jq -ce --argjson stale "$stale" '
    if type == "array" then {games:.,updatedAt:null} else . end
    | if (.games | type) != "array" then error("Invalid slate") else . end
    | .stale = $stale | .games |= map(. + {stale:$stale})
  ' "$cache_file"
}

slate_sport() {
  local sport="$1" date_key="$2" force="$3" path label cache_file age payload normalized
  path=$(espn_path "$sport") || return 1
  label=$(sport_label "$sport")
  cache_file="$CACHE_DIR/slate-${sport}-${date_key}.json"

  if [[ $force == false && -f $cache_file ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$cache_file") ))
    if (( age < CACHE_TTL )) && normalized=$(cached_slate "$cache_file" false); then
      printf '%s\n' "$normalized"
      return
    fi
  fi

  if ! payload=$(fetch_json "$ESPN_ROOT/$path/scoreboard?dates=$date_key&limit=500" 10) \
      || ! jq -e 'type == "object" and (.events | type == "array")' <<<"$payload" >/dev/null 2>&1; then
    cached_slate "$cache_file" true || printf '%s\n' '{"games":[],"stale":true,"updatedAt":null}'
    return
  fi

  if normalized=$(jq -ce --arg sport "$sport" --arg league "$label" \
    --argjson now "$(date +%s)" --argjson max "$MAX_SLATE_GAMES_PER_LEAGUE" '
      def epoch:
      (if test("T[0-9]{2}:[0-9]{2}Z$") then sub("Z$"; ":00Z") else . end)
      | try fromdateiso8601 catch 0;
      def text($length): tostring | .[:$length];
      [(.events // [])[] as $event
      | ($event.competitions[0].competitors // []) as $teams
      | ([$teams[] | select(.homeAway == "home")][0]) as $home
      | ([$teams[] | select(.homeAway == "away")][0]) as $away
      | {
          id:($event.id | text(64)), sport:$sport, league:$league,
          homeTeam:(($home.team.abbreviation // $home.team.shortDisplayName // "TBD") | text(40)),
          awayTeam:(($away.team.abbreviation // $away.team.shortDisplayName // "TBD") | text(40)),
          homeScore:(($home.score // "?") | text(20)),
          awayScore:(($away.score // "?") | text(20)),
          state:(($event.competitions[0].status.type.state // "pre") | text(12)),
          statusName:(($event.competitions[0].status.type.name // "") | text(64)),
          detail:(($event.competitions[0].status.type.shortDetail // "Scheduled") | text(120)),
          date:($event.date | text(64)),
          when:(($event.date | epoch) | strflocaltime("%-I:%M %p")),
          broadcast:(($event.competitions[0].broadcasts[0].media.shortName
            // $event.competitions[0].broadcasts[0].names[0] // "") | text(80)),
          gameUrl:(([($event.links // [])[]
            | select((.href // "") | test("^https://www\\.espn\\.com/"))
            | select((.rel // []) | index("summary"))
            | select((.rel // []) | index("desktop"))
            | .href][0] // "") | text(512)),
          stale:false,
          rank:(if $event.competitions[0].status.type.state == "in" then 0
            elif $event.competitions[0].status.type.state == "pre" then 1 else 2 end)
        }]
    | sort_by(.rank, .date)
    | .[:$max]
    | map(del(.rank))
    | {games:.,stale:false,updatedAt:$now}
  ' <<<"$payload" 2>/dev/null | bounded_output "$MAX_SLATE_CACHE_BYTES") \
      && [[ -n $normalized ]] && write_cache "$cache_file" "$normalized" "$MAX_SLATE_CACHE_BYTES"; then
    printf '%s\n' "$normalized"
  else
    cached_slate "$cache_file" true || printf '%s\n' '{"games":[],"stale":true,"updatedAt":null}'
  fi
}

full_slate() (
  local force=false state hidden date_key sport work finished
  local -A jobs=()
  [[ ${1:-} == "--no-cache" ]] && force=true
  state=$(read_state)
  hidden=$(jq -r '.spoilersHidden' <<<"$state")
  date_key=$(date +%Y%m%d)
  work=$(mktemp -d "$CACHE_DIR/.slate.XXXXXX") || exit 1
  trap 'if ((${#jobs[@]})); then kill "${!jobs[@]}" 2>/dev/null || true; wait "${!jobs[@]}" 2>/dev/null || true; fi; rm -rf "$work"' EXIT

  while IFS= read -r sport; do
    [[ -n $sport ]] || continue
    (
      item=$(slate_sport "$sport" "$date_key" "$force") || item='{"games":[],"stale":true}'
      jq -c --arg league "$(sport_label "$sport")" '. + {league:$league}' <<<"$item"
    ) >"$work/$sport.json" &
    jobs[$!]="$sport"
    if ((${#jobs[@]} >= MAX_SLATE_REQUESTS)); then
      finished=""
      wait -n -p finished "${!jobs[@]}" || true
      [[ -n $finished ]] || exit 1
      unset 'jobs[$finished]'
    fi
  done < <(jq -r '.teams | map(.sport) | unique[]' <<<"$state")

  if ((${#jobs[@]})); then
    wait "${!jobs[@]}" || true
    jobs=()
  fi
  # A sentinel handles zero followed leagues without a special unbounded argv path.
  printf '{"games":[],"stale":false}\n' >"$work/empty.json"
  jq -sc --arg date "$date_key" --argjson hidden "$hidden" --argjson max "$MAX_SLATE_GAMES" '
    . as $parts | ([$parts[] | select(.stale) | .league] | sort) as $failed |
    ([.[].games[]] | unique_by(.sport + ":" + .id)
      | sort_by((if .state == "in" then 0 elif .state == "pre" then 1 else 2 end), .date)
      | .[:$max]) as $games |
    {date:$date,spoilersHidden:$hidden,stale:($failed | length > 0),failedLeagues:$failed,
      games:$games,leagues:($games | map(.league) | unique)}' "$work"/*.json \
    | bounded_output "$MAX_QML_OUTPUT_BYTES"
)

# Serialize read/modify/write preferences even when separate plugin processes overlap.
source "$SCRIPT_DIR/planner.sh"
case "${1:-}" in
  add|follow|remove|toggle-spoilers|cycle-sort|move|toggle-pin|watch-game|remind-game|toggle-quiet|check-reminders)
    ensure_storage
    exec 9>"$STATE_DIR/.omathlete.lock"
    /usr/bin/flock -w 30 9 || exit 1
    ;;
esac

case "${1:-}" in
  add) add_team ;;
  search) search_teams "${2:-}" ;;
  follow) follow_team "${2:?sport required}" "${3:?team id required}" ;;
  remove) remove_team "${2:?sport required}" "${3:?team id required}" ;;
  toggle-spoilers) toggle_spoilers ;;
  cycle-sort) cycle_sort ;;
  move) move_team "${2:?sport required}" "${3:?team id required}" "${4:?direction required}" ;;
  toggle-pin) toggle_pin "${2:?sport required}" "${3:?team id required}" ;;
  detail) shift; detail "$@" ;;
  detail-stream) shift; detail_stream "$@" ;;
  slate) full_slate "${2:-}" ;;
  state) read_state ;;
  watch-game|remind-game|toggle-quiet) planner_change "$@" ;;
  check-reminders) check_reminders ;;
  *)
    printf 'Usage: %s {add|search <query>|follow <sport> <team-id>|remove <sport> <team-id>|toggle-spoilers|cycle-sort|move <sport> <team-id> <-1|1>|toggle-pin <sport> <team-id>|detail [--no-cache|--live sport:id...]|detail-stream [--no-cache|--live sport:id...]|slate [--no-cache]|watch-game <sport> <game-id>|remind-game <sport> <game-id>|toggle-quiet|check-reminders|state}\n' "$0" >&2
    exit 2
    ;;
esac
result=$?
case "${1:-}" in
  add|follow|remove|toggle-spoilers|cycle-sort|move|toggle-pin|watch-game|remind-game|toggle-quiet)
    (( result == 0 )) && read_state
    ;;
esac
exit "$result"
