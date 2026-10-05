# Sourced by omathlete after its storage/provider helpers are defined.
planner_lookup() {
  local sport="$1" game_id="$2" state team_id path found
  espn_path "$sport" >/dev/null || return 1
  [[ $game_id =~ ^[A-Za-z0-9_-]{1,64}$ ]] || return 1
  state=$(read_state)
  while IFS= read -r team_id; do
    path="$CACHE_DIR/$sport-$team_id.json"
    valid_json_file "$path" "$MAX_TEAM_CACHE_BYTES" || continue
    found=$(jq -ce --arg id "$game_id" --arg sport "$sport" --argjson cachedAt "$(stat -c %Y "$path")" '
      . as $team | [(.agenda // [])[], (.schedule // [])[], .current, .upcoming]
      | map(select(. != null and .id == $id)) | first // empty
      | . + {sport:$sport,cachedAt:$cachedAt,
          homeTeam:(.homeTeam // (if .isHome then $team.teamAbbrev else .opponent end)),
          awayTeam:(.awayTeam // (if .isHome then .opponent else $team.teamAbbrev end))}
    ' "$path" 2>/dev/null) || continue
    [[ -n $found ]] && { printf '%s\n' "$found"; return; }
  done < <(jq -r --arg sport "$sport" '.teams[] | select(.sport == $sport) | .teamId' <<<"$state")
  return 1
}

planner_change() {
  local action="$1" sport="${2:-}" game_id="${3:-}" state game updated collection
  state=$(read_state)
  if [[ $action == toggle-quiet ]]; then
    updated=$(jq -c '.quietHours = (.quietHours | not)' <<<"$state")
  else
    espn_path "$sport" >/dev/null || return 1
    [[ $game_id =~ ^[A-Za-z0-9_-]{1,64}$ ]] || return 1
    collection=watchLater
    [[ $action == remind-game ]] && collection=reminders
    game=$(jq -c --arg sport "$sport" --arg id "$game_id" --arg field "$collection" \
      '[.[$field][] | select(.sport == $sport and .id == $id)][0] // empty' <<<"$state")
    if [[ -z $game ]]; then
      game=$(planner_lookup "$sport" "$game_id") || return 1
      jq -e -L "$SCRIPT_DIR" 'include "planner"; planner_game' <<<"$game" >/dev/null || return 1
      if [[ $(jq --arg field "$collection" '.[$field] | length' <<<"$state") -ge 32 ]]; then
        notify "You can save up to 32 games in each list."
        return 1
      fi
    fi
    updated=$(jq -c -L "$SCRIPT_DIR" --arg action "$action" --arg sport "$sport" --arg id "$game_id" --argjson game "$game" '
      include "planner";
      if $action == "watch-game" then
        if any(.watchLater[]; .sport == $sport and .id == $id)
        then .watchLater |= map(select(.sport != $sport or .id != $id))
        else .watchLater += [($game | game_snapshot)] end
      elif $action == "remind-game" then
        ([.reminders[] | select(.sport == $sport and .id == $id)][0]) as $old
        | .reminders |= map(select(.sport != $sport or .id != $id))
        | if $old == null then .reminders += [($game | game_snapshot) + {leadMinutes:15}]
          elif $old.leadMinutes == 15 then .reminders += [($game | game_snapshot) + {leadMinutes:0}]
          else . end
      else error("Unknown planner action") end
    ' <<<"$state") || return 1
  fi
  write_state "$updated"
}

check_reminders() {
  local now state record sport game_id game start due signature cached_at hour due_hour ledger sent updated message
  local -a due_games=()
  now=$(date +%s)
  if [[ ${OMATHLETE_TESTING:-0} == 1 && ${OMATHLETE_NOW:-} =~ ^[0-9]+$ ]]; then now="$OMATHLETE_NOW"; fi
  state=$(read_state)
  ledger="$STATE_DIR/omathlete-reminders.json"
  sent='[]'
  if valid_json_file "$ledger" 32768; then
    sent=$(jq -c --argjson now "$now" '[.[] | select((.key | type) == "string"
      and (.key | length) <= 180 and (.at | type) == "number" and .at > ($now - 30*86400))][:128]' "$ledger" 2>/dev/null) || sent='[]'
  fi
  while IFS= read -r record; do
    sport=$(jq -r '.sport' <<<"$record")
    game_id=$(jq -r '.id' <<<"$record")
    game=$(planner_lookup "$sport" "$game_id") || continue
    # Use recent schedule data only, and never infer kickoff from a past result.
    [[ $(jq -r '.state' <<<"$game") =~ ^(pre|in)$ ]] || continue
    jq -e '((.statusName // "") + " " + (.detail // ""))
      | test("postpon|cancel|suspend|delay|TBD"; "i")' <<<"$game" >/dev/null && continue
    cached_at=$(jq -r '.cachedAt' <<<"$game")
    (( now - cached_at <= 600 && now >= cached_at - 60 )) || continue
    start=$(jq -r '.date' <<<"$game")
    start=$(date -d "$start" +%s 2>/dev/null) || continue
    due=$((start - $(jq -r '.leadMinutes' <<<"$record") * 60))
    # Two-minute window avoids a burst of old reminders after sleep or quiet hours.
    (( now >= due && now - due <= 120 )) || continue
    if [[ $(jq -r '.quietHours' <<<"$state") == true ]]; then
      hour=$(date -d "@$now" +%H); due_hour=$(date -d "@$due" +%H)
      (( 10#$hour >= 8 && 10#$hour < 22 && 10#$due_hour >= 8 && 10#$due_hour < 22 )) || continue
    fi
    signature="$sport:$game_id:$start:$(jq -r '.leadMinutes' <<<"$record")"
    jq -e --arg key "$signature" 'any(.[]; .key == $key)' <<<"$sent" >/dev/null && continue
    sent=$(jq -c --arg key "$signature" --argjson now "$now" '. + [{key:$key,at:$now}] | .[-128:]' <<<"$sent")
    due_games+=("$(jq -r --arg when "$(date -d "@$start" '+%-I:%M %p')" \
      '.awayTeam + " @ " + .homeTeam + " · " + $when + (if .broadcast != "" then " · " + .broadcast else "" end)' <<<"$game")")
  done < <(jq -c '.reminders[]' <<<"$state")
  if ((${#due_games[@]})); then
    updated=$(mktemp "$STATE_DIR/.reminders.XXXXXX") || return 1
    printf '%s\n' "$sent" >"$updated"
    mv -f "$updated" "$ledger" || return 1
    message=$(printf '%s\n' "${due_games[@]:0:3}")
    if ((${#due_games[@]} > 3)); then message+=$'\n'"+ $((${#due_games[@]} - 3)) more games"; fi
    if [[ ${OMATHLETE_TESTING:-0} == 1 ]]; then
      [[ -z ${OMATHLETE_NOTIFY_LOG:-} ]] || printf '%s\n' "$message" >>"$OMATHLETE_NOTIFY_LOG"
    else
      notify "$message"
    fi
  fi
  printf '{"sent":%s}\n' "${#due_games[@]}"
}
