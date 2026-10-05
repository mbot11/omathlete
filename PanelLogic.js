// Shared by the panel and deterministic interaction tests. Times are milliseconds.
function contrastingInk(color) {
  function linear(v) { return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
  var luminance = 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b);
  return luminance > 0.179 ? "#000000" : "#ffffff";
}

function refreshInterval(teams, opened, now) {
  if (opened) return 60000;
  for (var i = 0; i < teams.length; i++) {
    var start = teams[i].upcoming ? Date.parse(teams[i].upcoming.date) : NaN;
    if (isFinite(start) && start - now <= 15 * 60000 && now - start <= 6 * 3600000)
      return 60000;
  }
  return 5 * 60000;
}

function countdown(date, now) {
  var start = Date.parse(date);
  if (!isFinite(start)) return "TBD";
  var remaining = start - now;
  if (remaining <= 0) return "Starting";
  if (remaining < 3600000) return Math.ceil(remaining / 60000) + "m";
  if (remaining < 86400000) return Math.ceil(remaining / 3600000) + "h";
  return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][new Date(start).getDay()];
}

function gameKey(game) {
  return game ? (game.sport ? game.sport + ":" : "")
    + String(game.id || game.gameUrl || (game.date + ":" + game.opponent)) : "";
}

function mergeTeamUpdates(existing, incoming, fillOnly) {
  var result = existing.slice();
  for (var i = 0; i < incoming.length; i++) {
    var index = -1;
    for (var j = 0; j < result.length; j++)
      if (teamKey(result[j]) === teamKey(incoming[i])) { index = j; break; }
    if (index < 0) result.push(incoming[i]);
    else if (!fillOnly) result[index] = incoming[i];
  }
  return result.slice(0, 12);
}

function selectedGameIndex(schedule, key, previousIndex) {
  for (var i = 0; i < schedule.length; i++)
    if (gameKey(schedule[i]) === key) return i;
  return Math.max(0, Math.min(previousIndex, schedule.length - 1));
}

function statusText(game, hidden) {
  if (!game) return "";
  var special = {STATUS_DELAYED:"Delayed",STATUS_POSTPONED:"Postponed",
    STATUS_CANCELED:"Canceled",STATUS_CANCELLED:"Canceled",STATUS_SUSPENDED:"Suspended"};
  if (special[game.statusName]) return special[game.statusName];
  if (!hidden) return game.detail || "Scheduled";
  // Provider descriptions can contain winners, aggregate scores and shootouts.
  return game.state === "in" ? "Live" : game.state === "post" ? "Final" : "Scheduled";
}

function dataStale(item, now) {
  if (!item) return false;
  var game = item.current || item;
  return !!item.stale || !!game.scoreStale || !!game.scoreCached
    || (game.state === "in" && (!item.updatedAt || now / 1000 - item.updatedAt > 120));
}

function liveLabel(team, hidden, now) {
  var game = team.current;
  return (game.scoreStale ? "Stale · " : dataStale(team, now) ? "Cached · " : "") + team.teamAbbrev
    + (hidden ? "" : " " + game.teamScore + "–" + game.opponentScore)
    + " · " + statusText(game, hidden);
}

function freshness(item, now) {
  if (!item) return "";
  var game = item.current || item;
  if (game.scoreStale) return "Live score update failed · r to retry";
  var updated = Number((game.scoreCached ? game.scoreUpdatedAt : item.updatedAt) || 0);
  if (!updated && item.loading) return "Loading games…";
  if (!updated) return item.stale ? "Couldn't load games · r to retry" : "";
  var minutes = Math.max(0, Math.floor((now / 1000 - updated) / 60));
  var age = minutes < 1 ? "just now" : minutes < 60 ? minutes + "m ago"
    : minutes < 1440 ? Math.floor(minutes / 60) + "h ago" : Math.floor(minutes / 1440) + "d ago";
  return (game.scoreCached ? "Final score cached · updated " : dataStale(item, now) ? "Cached · updated " : "Updated ") + age;
}

function availability(team) {
  if (!team) return "No team selected.";
  if (team.loading) return "Loading schedule…";
  if (team.stale) return team.updatedAt
    ? "Provider refresh failed; showing cached games. Retry this team with r."
    : "Schedule unavailable: provider request or response validation failed. Retry with r.";
  if (!(team.schedule || []).length) return "Provider returned no recent or upcoming games. This does not confirm an off-season.";
  if (!team.upcoming) return "No upcoming fixture returned by the provider. Try refreshing this team.";
  return "Schedule loaded. Broadcasts and game context depend on provider coverage.";
}

function gameContext(game, hidden) {
  var parts = [game.isHome ? "Home game" : "Away game"];
  if (game.venue) parts.push(game.venue);
  if (!hidden && (game.teamRecord || game.opponentRecord))
    parts.push("Records: " + (game.teamRecord || "unavailable") + " / " + (game.opponentRecord || "unavailable"));
  return parts.join(" · ");
}

// Deliberately omit favorites, scores, URLs, local paths and raw provider errors.
function diagnosticSummary(teams, now) {
  return JSON.stringify({component:"Omathlete",provider:"ESPN",teams:teams.length,
    loading:teams.filter(function(t){return !!t.loading}).length,
    stale:teams.filter(function(t){return !!t.stale}).length,
    unavailable:teams.filter(function(t){return !t.updatedAt}).length,
    noUpcoming:teams.filter(function(t){return !t.upcoming}).length,
    oldestCacheMinutes:teams.reduce(function(age,t){return t.updatedAt
      ? Math.max(age, Math.max(0, Math.floor((now / 1000 - t.updatedAt) / 60))) : age},0)}, null, 2);
}

function preferences(state) {
  return {spoilersHidden: state.spoilersHidden === true, sortMode: state.sortMode || "manual",
    pinnedTeam: state.pinnedTeam || null, teams: (state.teams || []).slice(),
    watchLater: (state.watchLater || []).slice(), reminders: (state.reminders || []).slice(),
    quietHours: state.quietHours !== false};
}

function gameSnapshot(game) {
  return {sport:game.sport,id:game.id,date:game.date,homeTeam:game.homeTeam,awayTeam:game.awayTeam,
    broadcast:game.broadcast || "",gameUrl:game.gameUrl || ""};
}

function protectedGame(game, sport, state) {
  if (state.spoilersHidden) return true;
  var key = (sport || game.sport) + ":" + game.id;
  return (state.watchLater || []).some(function(saved) { return gameKey(saved) === key; });
}

function agendaGames(teams) {
  teams = teams.slice().sort(function(a,b) { return (b.updatedAt || 0) - (a.updatedAt || 0); });
  var games = {}, result = [];
  for (var i = 0; i < teams.length; i++) {
    var team = teams[i];
    var schedule = (team.agenda || []).concat(team.schedule || []);
    for (var j = 0; j < schedule.length; j++) {
      var game = schedule[j];
      if (!game.id) continue;
      var key = team.sport + ":" + game.id;
      if (games[key]) continue;
      var entry = Object.assign({}, game, {sport:team.sport,stale:team.stale,updatedAt:team.updatedAt});
      entry.homeTeam = game.homeTeam || (game.isHome ? team.teamAbbrev : game.opponent);
      entry.awayTeam = game.awayTeam || (game.isHome ? game.opponent : team.teamAbbrev);
      entry.homeScore = game.isHome ? game.teamScore : game.opponentScore;
      entry.awayScore = game.isHome ? game.opponentScore : game.teamScore;
      games[key] = true;
      result.push(entry);
    }
  }
  return result.sort(function(a, b) { return Date.parse(a.date) - Date.parse(b.date); });
}

function agendaRange(range, now) {
  var day = new Date(now);
  var start = new Date(day.getFullYear(), day.getMonth(), day.getDate());
  var days = 1;
  if (range === 1) start.setDate(start.getDate() + 1);
  if (range === 2) {
    start.setDate(start.getDate() + (day.getDay() === 0 ? -1 : (6 - day.getDay())));
    days = 2;
  }
  if (range === 3) days = 7;
  var end = new Date(start); end.setDate(end.getDate() + days);
  return [start.getTime(), end.getTime()];
}

function plannerRows(teams, state, range, watchLater, now) {
  var all = agendaGames(teams), bounds = agendaRange(range, now);
  var games = watchLater ? (state.watchLater || []).map(function(saved) {
    return all.filter(function(game) { return gameKey(game) === gameKey(saved); })[0]
      || Object.assign({}, saved, {state:"unknown"});
  }) : all.filter(function(game) { var date = Date.parse(game.date); return date >= bounds[0] && date < bounds[1]; });
  return games.sort(function(a,b) { return Date.parse(a.date) - Date.parse(b.date); }).map(function(game) {
    var date = new Date(game.date);
    var reminder = (state.reminders || []).filter(function(item) { return gameKey(item) === gameKey(game); })[0];
    return Object.assign({}, game, {
      day: ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"][date.getDay()] + " · "
        + ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][date.getMonth()] + " " + date.getDate(),
      saved: (state.watchLater || []).some(function(item) { return gameKey(item) === gameKey(game); }),
      reminder: reminder ? (reminder.leadMinutes ? "15m before" : "At start") : "Off"
    });
  });
}

function teamKey(team) {
  return team ? team.sport + ":" + team.teamId : "";
}

function applyPreference(state, action) {
  var next = preferences(state);
  var command = action.command;
  var key = command[1] + ":" + command[2];
  var index = -1;
  for (var i = 0; i < next.teams.length; i++)
    if (teamKey(next.teams[i]) === key) index = i;
  switch (command[0]) {
  case "watch-game":
    var watchedKey = command[1] + ":" + command[2];
    var saved = next.watchLater.some(function(game) { return gameKey(game) === watchedKey; });
    next.watchLater = next.watchLater.filter(function(game) { return gameKey(game) !== watchedKey; });
    if (!saved && action.team && next.watchLater.length < 32) next.watchLater.push(gameSnapshot(action.team));
    break;
  case "remind-game":
    var reminderKey = command[1] + ":" + command[2];
    var oldReminder = next.reminders.filter(function(game) { return gameKey(game) === reminderKey; })[0];
    next.reminders = next.reminders.filter(function(game) { return gameKey(game) !== reminderKey; });
    if ((!oldReminder || oldReminder.leadMinutes === 15) && action.team && next.reminders.length < 32)
      next.reminders.push(Object.assign(gameSnapshot(action.team), {leadMinutes:oldReminder ? 0 : 15}));
    break;
  case "toggle-quiet": next.quietHours = !next.quietHours; break;
  case "toggle-spoilers": next.spoilersHidden = !next.spoilersHidden; break;
  case "cycle-sort":
    next.sortMode = next.sortMode === "manual" ? "next" : next.sortMode === "next" ? "league" : "manual";
    break;
  case "toggle-pin":
    if (index >= 0) next.pinnedTeam = teamKey(next.pinnedTeam) === key ? null
      : {sport: command[1], teamId: command[2]};
    break;
  case "move":
    var to = index + Number(command[3]);
    if (next.sortMode === "manual" && index >= 0 && to >= 0 && to < next.teams.length) {
      var team = next.teams[index]; next.teams[index] = next.teams[to]; next.teams[to] = team;
    }
    break;
  case "remove":
    if (index >= 0) next.teams.splice(index, 1);
    if (teamKey(next.pinnedTeam) === key) next.pinnedTeam = null;
    break;
  case "follow":
    if (index < 0 && next.teams.length < 12 && action.team) next.teams.push(action.team);
    break;
  }
  return next;
}

function projectedPreferences(saved, pending) {
  var result = preferences(saved);
  for (var i = 0; i < pending.length; i++) result = applyPreference(result, pending[i]);
  return result;
}
