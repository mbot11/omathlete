import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "PanelLogic.js" as Logic

Panel {
  id: root
  moduleName: "io.github.chrisroundhill.omathlete"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var report: ({ teams: [], spoilersHidden: false, sortMode: "manual", pinnedTeam: null, stale: false })
  property var savedPreferences: ({teams: [], spoilersHidden: true, sortMode: "manual", pinnedTeam: null})
  property var preferenceQueue: []
  property bool preferencesReady: false
  property var preferences: ({teams: [], spoilersHidden: true, sortMode: "manual", pinnedTeam: null})
  property double now: Date.now()
  property double lastRefreshAt: 0
  property bool refreshPending: false
  property bool forceRefreshPending: false
  property bool busy: false
  property string errorMessage: ""
  property bool diagnosticsOpen: false
  property int selectedIndex: 0
  property bool searchOpen: false
  property bool searchBusy: false
  property var searchResults: []
  property int searchSelectedIndex: 0
  property string requestedQuery: ""
  property bool teamDetailOpen: false
  property var detailTeamKey: null
  readonly property var detailTeam: findTeam(detailTeamKey)
  property int gameSelectedIndex: 0
  property bool fullSlateOpen: false
  property bool plannerOpen: false
  property bool watchLaterOpen: false
  property int agendaRange: 0
  property bool slateBusy: false
  property var slateGames: []
  property bool slateStale: false
  property string slateError: ""
  property int slateSelectedIndex: 0
  property int liveBarIndex: 0
  property var scoreFlashTeams: ({})
  property string pendingSelectionKey: ""
  property bool restoringViewport: false
  property int viewportGeneration: 0
  property var pendingViewport: null
  property bool restoringSlateViewport: false
  property int slateViewportGeneration: 0

  readonly property string sortMode: preferences.sortMode
  readonly property var pinnedTeam: preferences.pinnedTeam
  readonly property var teams: sortedTeams(report.teams || [])
  readonly property bool spoilersHidden: !preferencesReady || preferences.spoilersHidden
  readonly property var liveTeams: {
    var result = []
    for (var i = 0; i < teams.length; i++) {
      if (teams[i].current && teams[i].current.state === "in") result.push(teams[i])
    }
    return result
  }
  readonly property var barTeam: liveTeams.length > 0
    ? liveTeams[liveBarIndex % liveTeams.length]
    : (findTeam(pinnedTeam) || nextBarTeam() || (teams.length > 0 ? teams[0] : null))
  readonly property bool barLive: !!barTeam && !!barTeam.current && barTeam.current.state === "in"
  readonly property bool barDataStale: barLive ? Logic.dataStale(barTeam, root.now) : !!barTeam && !!barTeam.stale
  readonly property string backend: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")) + "bin/omathlete"
  readonly property string barLabel: {
    if (busy && teams.length === 0) return "…"
    if (!barTeam) return ""
    if (barLive) {
      return Logic.liveLabel(barTeam, gameHidden(barTeam.current, barTeam.sport), root.now)
    }
    if (barTeam.upcoming) return barTeam.teamAbbrev
      + (barTeam.upcoming.isHome ? " vs " : " @ ") + barTeam.upcoming.opponent
      + " · " + (barTeam.upcoming.statusName === "STATUS_DELAYED" ? "Delayed" : Logic.countdown(barTeam.upcoming.date, root.now))
    return ""
  }
  readonly property string tooltipText: barLabel
    ? "Omathlete · " + barLabel + " · " + Logic.freshness(barTeam, root.now) + (spoilersHidden ? " · scores hidden" : "")
    : "Omathlete · your teams"

  Component.onCompleted: {
    stateProcess.running = true
    root.refresh(false)
  }

  onSpoilersHiddenChanged: {
    if (spoilersHidden) {
      scoreFlashTeams = ({})
      scoreFlashTimer.stop()
      plannerView.revealedKey = ""
    }
  }

  function gameHidden(game, sport) {
    return !preferencesReady || Logic.protectedGame(game, sport, preferences)
  }

  function openPlanner(queue) {
    searchOpen = false
    teamDetailOpen = false
    fullSlateOpen = false
    watchLaterOpen = queue
    plannerOpen = true
    refresh(false)
  }

  function closePlanner() {
    plannerOpen = false
    keyCatcher.forceActiveFocus()
  }

  onSelectedIndexChanged: if (!restoringViewport) Qt.callLater(function() { root.ensureItemVisible(teamRepeater.itemAt(root.selectedIndex)) })
  onSearchSelectedIndexChanged: Qt.callLater(function() { root.ensureItemVisible(searchRepeater.itemAt(root.searchSelectedIndex)) })
  onGameSelectedIndexChanged: if (!restoringViewport) Qt.callLater(function() { root.ensureItemVisible(detailRepeater.itemAt(root.gameSelectedIndex)) })
  onSlateSelectedIndexChanged: if (!restoringSlateViewport) Qt.callLater(function() {
    slateList.positionViewAtIndex(root.slateSelectedIndex, ListView.Contain)
  })

  function captureViewport() {
    if (!root.opened || fullSlateOpen || searchOpen || plannerOpen) return null
    if (restoringViewport) return pendingViewport
    var repeater = teamDetailOpen ? detailRepeater : teamRepeater
    var items = teamDetailOpen ? (detailTeam ? detailTeam.schedule || [] : []) : teams
    var selected = teamDetailOpen ? gameSelectedIndex : selectedIndex
    var selectedItem = repeater.itemAt(selected)
    if (selectedItem) {
      var selectedTop = selectedItem.mapToItem(content, 0, 0).y
      if (selectedTop >= scoreFlick.contentY && selectedTop + selectedItem.height <= scoreFlick.contentY + scoreFlick.height)
        return {key: teamDetailOpen ? Logic.gameKey(items[selected]) : teamKey(items[selected]),
          detail: teamDetailOpen, offset: selectedTop - scoreFlick.contentY, y: scoreFlick.contentY}
    }
    for (var i = 0; i < items.length; i++) {
      var item = repeater.itemAt(i)
      if (!item) continue
      var top = item.mapToItem(content, 0, 0).y
      if (top + item.height > scoreFlick.contentY)
        return {key: teamDetailOpen ? Logic.gameKey(items[i]) : teamKey(items[i]),
          detail: teamDetailOpen, offset: top - scoreFlick.contentY, y: scoreFlick.contentY}
    }
    return {y: scoreFlick.contentY, detail: teamDetailOpen}
  }

  function cancelViewportRestore() {
    viewportGeneration++
    slateViewportGeneration++
    restoringViewport = false
    restoringSlateViewport = false
    pendingViewport = null
  }

  function restoreViewport(anchor) {
    pendingViewport = anchor
    var generation = ++viewportGeneration
    Qt.callLater(function() {
      if (generation !== root.viewportGeneration) return
      if (anchor && root.opened && !root.fullSlateOpen && !root.searchOpen
          && anchor.detail === root.teamDetailOpen) {
        var repeater = root.teamDetailOpen ? detailRepeater : teamRepeater
        var items = root.teamDetailOpen ? (root.detailTeam ? root.detailTeam.schedule || [] : []) : root.teams
        var target = anchor.y
        for (var i = 0; i < items.length; i++) {
          var key = root.teamDetailOpen ? Logic.gameKey(items[i]) : root.teamKey(items[i])
          var item = repeater.itemAt(i)
          if (key === anchor.key && item) { target = item.mapToItem(content, 0, 0).y - anchor.offset; break }
        }
        scoreFlick.contentY = Math.max(0, Math.min(target, scoreFlick.contentHeight - scoreFlick.height))
      }
      root.restoringViewport = false
      root.pendingViewport = null
    })
  }

  function ensureItemVisible(item) {
    if (!item || !scoreFlick.visible) return
    var mapped = item.mapToItem(content, 0, 0)
    var margin = Style.space(6)
    var top = mapped.y - margin
    var bottom = mapped.y + item.height + margin
    if (top < scoreFlick.contentY) scoreFlick.contentY = Math.max(0, top)
    else if (bottom > scoreFlick.contentY + scoreFlick.height)
      scoreFlick.contentY = Math.min(scoreFlick.contentHeight - scoreFlick.height,
        bottom - scoreFlick.height)
  }

  function teamKey(team) {
    return team ? team.sport + ":" + team.teamId : ""
  }

  function findTeam(key) {
    if (!key) return null
    var wanted = key.sport + ":" + key.teamId
    var source = report.teams || []
    for (var i = 0; i < source.length; i++)
      if (teamKey(source[i]) === wanted) return source[i]
    return null
  }

  function sortedTeams(source) {
    var result = []
    for (var p = 0; p < preferences.teams.length; p++) {
      for (var s = 0; s < source.length; s++)
        if (teamKey(preferences.teams[p]) === teamKey(source[s])) result.push(source[s])
    }
    var manual = result.slice()
    var leagueOrder = {nfl:0, nba:1, wnba:2, mlb:3, nhl:4, cfb:5, cbb:6, epl:7, mls:8}
    if (sortMode === "next") {
      result.sort(function(first, second) {
        var firstLive = first.current && first.current.state === "in"
        var secondLive = second.current && second.current.state === "in"
        if (firstLive !== secondLive) return firstLive ? -1 : 1
        var firstDate = first.upcoming ? Date.parse(first.upcoming.date) : Number.MAX_VALUE
        var secondDate = second.upcoming ? Date.parse(second.upcoming.date) : Number.MAX_VALUE
        return firstDate - secondDate || manual.indexOf(first) - manual.indexOf(second)
      })
    } else if (sortMode === "league") {
      result.sort(function(first, second) {
        return (leagueOrder[first.sport] === undefined ? 99 : leagueOrder[first.sport])
          - (leagueOrder[second.sport] === undefined ? 99 : leagueOrder[second.sport])
          || manual.indexOf(first) - manual.indexOf(second)
      })
    }
    return result
  }

  function nextBarTeam() {
    var next = null
    for (var i = 0; i < teams.length; i++)
      if (teams[i].upcoming && (!next || Date.parse(teams[i].upcoming.date) < Date.parse(next.upcoming.date)))
        next = teams[i]
    return next
  }

  function queuePreference(command, team) {
    if (!preferencesReady) return
    pendingSelectionKey = teamKey(teams[selectedIndex])
    preferenceQueue = preferenceQueue.concat([{command: command, team: team || null}])
    preferences = Logic.projectedPreferences(savedPreferences, preferenceQueue)
    if (command[0] === "watch-game") scoreFlashTeams = ({})
    restoreSelection()
    startPreference()
  }

  function startPreference() {
    if (preferenceProcess.running || preferenceQueue.length === 0) return
    preferenceProcess.result = null
    preferenceProcess.command = [root.backend].concat(preferenceQueue[0].command)
    preferenceProcess.running = true
  }

  function finishPreference(exitCode, result) {
    var action = preferenceQueue[0]
    pendingSelectionKey = teamKey(teams[selectedIndex])
    if (exitCode === 0 && result) savedPreferences = Logic.preferences(result)
    else errorMessage = "Could not save preference · please retry"
    preferenceQueue = preferenceQueue.slice(1)
    preferences = Logic.projectedPreferences(savedPreferences, preferenceQueue)
    restoreSelection()
    if (action && (action.command[0] === "follow" || action.command[0] === "remove"))
      refresh(false)
    Qt.callLater(root.startPreference)
  }

  function tick() {
    now = Date.now()
    if (now - lastRefreshAt >= Logic.refreshInterval(teams, root.opened, now)) {
      refresh(false)
      if (fullSlateOpen) refreshSlate(false)
    }
  }

  function restoreSelection() {
    if (!pendingSelectionKey) return
    for (var i = 0; i < teams.length; i++) {
      if (teamKey(teams[i]) === pendingSelectionKey) {
        selectedIndex = i
        break
      }
    }
    pendingSelectionKey = ""
  }

  function colorLuminance(value) {
    function channel(component) {
      return component <= 0.03928 ? component / 12.92 : Math.pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(value.r) + 0.7152 * channel(value.g) + 0.0722 * channel(value.b)
  }

  function contrastRatio(first, second) {
    var lighter = Math.max(colorLuminance(first), colorLuminance(second))
    var darker = Math.min(colorLuminance(first), colorLuminance(second))
    return (lighter + 0.05) / (darker + 0.05)
  }

  function parsedTeamColor(value) {
    var match = String(value || "").match(/^#([0-9a-fA-F]{6})$/)
    if (!match) return null
    var hex = match[1]
    return Qt.rgba(parseInt(hex.slice(0, 2), 16) / 255,
      parseInt(hex.slice(2, 4), 16) / 255,
      parseInt(hex.slice(4, 6), 16) / 255, 1)
  }

  function teamAccent(team) {
    var primary = parsedTeamColor(team ? team.teamColor : "")
    var alternate = parsedTeamColor(team ? team.teamAlternateColor : "")
    var surface = Color.background
    var minimumTextContrast = 4.5
    if (primary && contrastRatio(primary, surface) >= minimumTextContrast) return primary
    if (alternate && contrastRatio(alternate, surface) >= minimumTextContrast) return alternate
    if (contrastRatio(Color.accent, surface) >= minimumTextContrast) return Color.accent
    return Color.foreground
  }

  function open() {
    root.controller.show()
    root.refresh(false)
  }
  function close() {
    plannerOpen = false
    searchOpen = false
    teamDetailOpen = false
    fullSlateOpen = false
    slateGames = []
    root.controller.hide()
  }
  function toggle() { root.opened ? root.close() : root.open() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function refresh(force) {
    if (detailProcess.running) {
      refreshPending = true
      forceRefreshPending = forceRefreshPending || force
      return
    }
    lastRefreshAt = Date.now()
    busy = true
    errorMessage = ""
    detailProcess.command = force ? [root.backend, "detail-stream", "--no-cache"] : [root.backend, "detail-stream"]
    detailProcess.running = true
  }

  function refreshLive() {
    if (detailProcess.running || liveTeams.length === 0) return
    var command = [root.backend, "detail-stream", "--live"]
    for (var i = 0; i < liveTeams.length; i++)
      command.push(liveTeams[i].sport + ":" + liveTeams[i].teamId)
    busy = true
    detailProcess.command = command
    detailProcess.running = true
  }

  function retryTeam() {
    if (!detailTeam || detailProcess.running) return
    busy = true
    errorMessage = ""
    detailProcess.command = [root.backend, "detail-stream", "--team", Logic.teamKey(detailTeam)]
    detailProcess.running = true
  }

  function adoptReport(nextReport) {
    var anchor = captureViewport()
    restoringViewport = true
    var selectedKey = teamKey(teams[selectedIndex])
    var oldGames = detailTeam ? detailTeam.schedule || [] : []
    var selectedGame = Logic.gameKey(oldGames[gameSelectedIndex])
    var changed = ({})
    if (!spoilersHidden) {
      var previousTeams = report.teams || []
      var nextTeams = nextReport.teams || []
      for (var i = 0; i < nextTeams.length; i++) {
        var nextTeam = nextTeams[i]
        if (!nextTeam.current || nextTeam.current.state !== "in" || gameHidden(nextTeam.current, nextTeam.sport)) continue
        for (var j = 0; j < previousTeams.length; j++) {
          var previousTeam = previousTeams[j]
          if (previousTeam.sport !== nextTeam.sport || previousTeam.teamId !== nextTeam.teamId
              || !previousTeam.current || previousTeam.current.state !== "in") continue
          if (previousTeam.current.teamScore !== nextTeam.current.teamScore
              || previousTeam.current.opponentScore !== nextTeam.current.opponentScore)
            changed[nextTeam.sport + ":" + nextTeam.teamId] = true
          break
        }
      }
    }
    report = nextReport
    pendingSelectionKey = selectedKey
    restoreSelection()
    gameSelectedIndex = Logic.selectedGameIndex(detailTeam ? detailTeam.schedule || [] : [],
      selectedGame, gameSelectedIndex)
    restoreViewport(anchor)
    if (Object.keys(changed).length > 0) {
      scoreFlashTeams = changed
      scoreFlashTimer.restart()
    }
  }

  function adoptTeamMessage(message) {
    if (message.type === "done") return
    var incoming = message.type === "snapshot" ? message.teams
      : message.type === "team" ? [message.team] : []
    if (!Array.isArray(incoming) || incoming.length > 12) throw new Error("Invalid team update")
    var existing = report.teams || []
    if (preferencesReady) {
      var allowed = preferences.teams.map(function(team) { return Logic.teamKey(team) })
      existing = existing.filter(function(team) { return allowed.indexOf(Logic.teamKey(team)) >= 0 })
      incoming = incoming.filter(function(team) { return allowed.indexOf(Logic.teamKey(team)) >= 0 })
    }
    var merged = Logic.mergeTeamUpdates(existing, incoming, message.type === "snapshot")
    adoptReport({teams: merged, stale: merged.some(function(team) { return team.stale === true })})
  }

  function adoptSlate(slate) {
    var selected = Logic.gameKey(slateGames[slateSelectedIndex])
    var topIndex = slateList.indexAt(1, slateList.contentY + 1)
    var selectedItem = slateList.itemAtIndex(slateSelectedIndex)
    if (selectedItem && selectedItem.y >= slateList.contentY
        && selectedItem.y + selectedItem.height <= slateList.contentY + slateList.height)
      topIndex = slateSelectedIndex
    var topItem = slateList.itemAtIndex(topIndex)
    var anchorKey = Logic.gameKey(slateGames[topIndex])
    var offset = topItem ? topItem.y - slateList.contentY : 0
    var oldY = slateList.contentY
    restoringSlateViewport = true
    slateGames = slate.games || []
    slateStale = slate.stale === true
    slateError = (slate.failedLeagues || []).length > 0
      ? "Couldn't update " + slate.failedLeagues.join(", ") + " · r to retry" : ""
    slateSelectedIndex = Logic.selectedGameIndex(slateGames, selected, slateSelectedIndex)
    var generation = ++slateViewportGeneration
    Qt.callLater(function() {
      if (generation !== root.slateViewportGeneration) return
      if (root.fullSlateOpen) {
        slateList.forceLayout()
        var index = Logic.selectedGameIndex(root.slateGames, anchorKey, -1)
        if (anchorKey && Logic.gameKey(root.slateGames[index]) === anchorKey) {
          slateList.positionViewAtIndex(index, ListView.Beginning)
          var item = slateList.itemAtIndex(index)
          if (item) slateList.contentY = item.y - offset
        } else slateList.contentY = oldY
        slateList.returnToBounds()
      }
      root.restoringSlateViewport = false
    })
  }

  function addTeam() {
    if (!addProcess.running) addProcess.running = true
  }

  function openSearch() {
    fullSlateOpen = false
    searchOpen = true
    searchResults = []
    searchSelectedIndex = 0
    searchField.text = ""
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function closeSearch() {
    searchOpen = false
    searchResults = []
    keyCatcher.forceActiveFocus()
  }

  function search(query) {
    if (query.length < 2) {
      searchResults = []
      searchBusy = false
      return
    }
    if (searchProcess.running) return
    requestedQuery = query
    searchBusy = true
    searchProcess.command = [root.backend, "search", query]
    searchProcess.running = true
  }

  function followSearchResult() {
    if (searchResults.length === 0) return
    var result = searchResults[Math.max(0, Math.min(searchSelectedIndex, searchResults.length - 1))]
    queuePreference(["follow", result.sport, result.teamId], result)
    closeSearch()
  }

  function removeSelected() {
    if (teams.length === 0) return
    var team = teams[Math.max(0, Math.min(selectedIndex, teams.length - 1))]
    queuePreference(["remove", team.sport, team.teamId])
    selectedIndex = Math.min(selectedIndex, Math.max(0, teams.length - 1))
  }

  function toggleSpoilers() {
    queuePreference(["toggle-spoilers"])
  }

  function cycleSort() {
    queuePreference(["cycle-sort"])
  }

  function moveSelected(direction) {
    if (sortMode !== "manual" || teams.length === 0) return
    var team = teams[Math.max(0, Math.min(selectedIndex, teams.length - 1))]
    queuePreference(["move", team.sport, team.teamId, String(direction)])
  }

  function togglePinSelected() {
    if (teams.length === 0) return
    var team = teams[Math.max(0, Math.min(selectedIndex, teams.length - 1))]
    queuePreference(["toggle-pin", team.sport, team.teamId])
  }

  function openTeamDetail() {
    if (teams.length === 0) return
    var team = teams[Math.max(0, Math.min(selectedIndex, teams.length - 1))]
    detailTeamKey = {sport: team.sport, teamId: team.teamId}
    gameSelectedIndex = 0
    teamDetailOpen = true
  }

  function toggleFullSlate() {
    if (fullSlateOpen) {
      fullSlateOpen = false
      slateGames = []
      keyCatcher.forceActiveFocus()
      return
    }
    searchOpen = false
    teamDetailOpen = false
    fullSlateOpen = true
    scoreFlick.contentY = 0
    slateSelectedIndex = 0
    refreshSlate(false)
  }

  function refreshSlate(force) {
    if (slateProcess.running) return
    slateBusy = true
    slateProcess.command = force ? [root.backend, "slate", "--no-cache"] : [root.backend, "slate"]
    slateProcess.running = true
  }

  function launchGameUrl(value) {
    var url = String(value || "")
    if (!url.startsWith("https://www.espn.com/")) return
    browserProcess.command = ["/usr/bin/omarchy-launch-browser", url]
    browserProcess.running = true
  }

  function closeTeamDetail() {
    teamDetailOpen = false
    detailTeamKey = null
    keyCatcher.forceActiveFocus()
  }

  function openSelectedGame() {
    if (!detailTeam || !detailTeam.schedule || detailTeam.schedule.length === 0) return
    var game = detailTeam.schedule[Math.max(0, Math.min(gameSelectedIndex, detailTeam.schedule.length - 1))]
    root.launchGameUrl(game.gameUrl)
  }

  function openSlateGame() {
    if (slateGames.length === 0) return
    var game = slateGames[Math.max(0, Math.min(slateSelectedIndex, slateGames.length - 1))]
    root.launchGameUrl(game.gameUrl)
  }

  Process {
    id: detailProcess
    stdout: SplitParser {
      onRead: function(data) {
        var raw = String(data || "").trim()
        if (!raw) return
        try {
          root.adoptTeamMessage(JSON.parse(raw))
          root.selectedIndex = Math.min(root.selectedIndex, Math.max(0, root.teams.length - 1))
          root.restoreSelection()
        } catch (error) {
          root.errorMessage = "Could not read sports data"
        }
      }
    }
    onExited: function(exitCode) {
      root.busy = false
      if ((root.preferences.reminders || []).length > 0 && !reminderProcess.running)
        reminderProcess.running = true
      if (exitCode !== 0) {
        root.errorMessage = "Some games couldn't update · r to retry"
        root.adoptReport({teams: (root.report.teams || []).map(function(team) {
          if (!team.loading) return team
          var failed = Object.assign({}, team)
          failed.loading = false
          failed.stale = true
          return failed
        }), stale: true})
      }
      if (root.refreshPending) {
        var force = root.forceRefreshPending
        root.refreshPending = false
        root.forceRefreshPending = false
        Qt.callLater(function() { root.refresh(force) })
      }
    }
  }

  Process {
    id: addProcess
    command: [root.backend, "add"]
    onExited: {
      stateProcess.running = true
      root.refresh(true)
    }
  }

  Timer {
    id: searchTimer
    interval: 220
    repeat: false
    onTriggered: root.search(searchField.text.trim())
  }

  Timer {
    interval: 6000
    repeat: true
    running: root.liveTeams.length > 1
    onTriggered: root.liveBarIndex = (root.liveBarIndex + 1) % root.liveTeams.length
  }

  Timer {
    id: scoreFlashTimer
    interval: 1600
    repeat: false
    onTriggered: root.scoreFlashTeams = ({})
  }

  Process {
    id: searchProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.searchResults = JSON.parse(String(text || "[]"))
          root.searchSelectedIndex = 0
        } catch (error) {
          root.searchResults = []
        }
      }
    }
    onExited: {
      root.searchBusy = false
      if (searchField.text.trim() !== root.requestedQuery) searchTimer.restart()
    }
  }

  Process {
    id: stateProcess
    command: [root.backend, "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.savedPreferences = Logic.preferences(JSON.parse(String(text)))
          root.preferences = Logic.projectedPreferences(root.savedPreferences, root.preferenceQueue)
          root.preferencesReady = true
        } catch (error) { root.errorMessage = "Could not read preferences" }
      }
    }
  }

  Process {
    id: preferenceProcess
    property var result: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { preferenceProcess.result = JSON.parse(String(text)) }
        catch (error) { preferenceProcess.result = null }
      }
    }
    onExited: function(exitCode) {
      root.finishPreference(exitCode, preferenceProcess.result)
    }
  }

  Process {
    id: slateProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.adoptSlate(JSON.parse(String(text || "{}")))
        } catch (error) {
          root.slateStale = true
          root.slateError = "Couldn't load games · r to retry"
        }
      }
    }
    onExited: function(exitCode) {
      root.slateBusy = false
      if (exitCode !== 0) root.slateError = "Couldn't load games · r to retry"
    }
  }

  Process { id: browserProcess }
  Process {
    id: reminderProcess
    command: [root.backend, "check-reminders"]
  }

  Timer {
    interval: 60000
    repeat: true
    running: (root.preferences.reminders || []).length > 0
    onTriggered: {
      // Refresh first so reminder decisions use the latest known start time.
      root.refresh(false)
    }
  }

  Timer {
    interval: 15 * 1000
    repeat: true
    running: true
    onTriggered: root.tick()
  }


  Timer {
    interval: 15 * 1000
    repeat: true
    running: root.liveTeams.length > 0
    onTriggered: root.refreshLive()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: root.plannerOpen ? plannerView : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(root.fullSlateOpen || root.plannerOpen ? Style.space(560)
      : content.implicitHeight + shortcutFooter.height, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      blocked: root.plannerOpen
      anchors.fill: parent
      onCloseRequested: {
        if (root.plannerOpen) root.closePlanner()
        else if (root.teamDetailOpen) root.closeTeamDetail()
        else if (root.fullSlateOpen) root.toggleFullSlate()
        else root.close()
      }
      onTabRequested: function(direction) {
        if (root.plannerOpen) plannerView.focusNext(direction < 0)
        else root.switchPanel(direction)
      }

      Keys.onPressed: function(event) {
        if (root.plannerOpen) return
        if (event.key === Qt.Key_G || event.key === Qt.Key_L) {
          root.openPlanner(event.key === Qt.Key_L)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_J || event.key === Qt.Key_K
            || event.key === Qt.Key_Down || event.key === Qt.Key_Up)
          root.cancelViewportRestore()
        if (root.fullSlateOpen) {
          if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
            root.slateSelectedIndex = Math.min(root.slateGames.length - 1, root.slateSelectedIndex + 1)
            event.accepted = true
          } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
            root.slateSelectedIndex = Math.max(0, root.slateSelectedIndex - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_A || event.key === Qt.Key_H || event.key === Qt.Key_Backspace) {
            root.toggleFullSlate()
            event.accepted = true
          } else if (event.key === Qt.Key_O || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.openSlateGame()
            event.accepted = true
          } else if (event.key === Qt.Key_S) {
            root.toggleSpoilers()
            event.accepted = true
          } else if (event.key === Qt.Key_R) {
            root.refreshSlate(true)
            event.accepted = true
          }
        } else if (root.teamDetailOpen) {
          var games = root.detailTeam && root.detailTeam.schedule ? root.detailTeam.schedule : []
          if ((event.key === Qt.Key_W || event.key === Qt.Key_B) && games[root.gameSelectedIndex]) {
            var game = Object.assign({}, games[root.gameSelectedIndex], {sport: root.detailTeam.sport})
            root.queuePreference([event.key === Qt.Key_W ? "watch-game" : "remind-game", game.sport, game.id], game)
            event.accepted = true
          } else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
            root.gameSelectedIndex = Math.min(games.length - 1, root.gameSelectedIndex + 1)
            event.accepted = true
          } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
            root.gameSelectedIndex = Math.max(0, root.gameSelectedIndex - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_H || event.key === Qt.Key_Backspace) {
            root.closeTeamDetail()
            event.accepted = true
          } else if (event.key === Qt.Key_O || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.openSelectedGame()
            event.accepted = true
          } else if (event.key === Qt.Key_S) {
            root.toggleSpoilers()
            event.accepted = true
          } else if (event.key === Qt.Key_R) {
            root.retryTeam()
            event.accepted = true
          } else if (event.key === Qt.Key_D) {
            root.diagnosticsOpen = !root.diagnosticsOpen
            event.accepted = true
          }
        } else if ((event.modifiers & Qt.ShiftModifier)
            && (event.key === Qt.Key_J || event.key === Qt.Key_Down)) {
          root.moveSelected(1)
          event.accepted = true
        } else if ((event.modifiers & Qt.ShiftModifier)
            && (event.key === Qt.Key_K || event.key === Qt.Key_Up)) {
          root.moveSelected(-1)
          event.accepted = true
        } else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
          root.selectedIndex = Math.min(root.teams.length - 1, root.selectedIndex + 1)
          event.accepted = true
        } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
          root.selectedIndex = Math.max(0, root.selectedIndex - 1)
          event.accepted = true
        } else if (event.key === Qt.Key_Slash) {
          root.openSearch()
          event.accepted = true
        } else if (event.key === Qt.Key_A) {
          root.toggleFullSlate()
          event.accepted = true
        } else if (event.key === Qt.Key_O) {
          root.cycleSort()
          event.accepted = true
        } else if (event.key === Qt.Key_P) {
          root.togglePinSelected()
          event.accepted = true
        } else if (event.key === Qt.Key_X || event.key === Qt.Key_Delete) {
          root.removeSelected()
          event.accepted = true
        } else if (event.key === Qt.Key_S) {
          root.toggleSpoilers()
          event.accepted = true
        } else if (event.key === Qt.Key_R) {
          root.refresh(true)
          event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.openTeamDetail()
          event.accepted = true
        }
      }

      Flickable {
        id: scoreFlick
        visible: !root.plannerOpen
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: shortcutFooter.top
        contentWidth: width
        contentHeight: root.fullSlateOpen ? height : content.implicitHeight
        interactive: !root.fullSlateOpen
        onMovementStarted: root.cancelViewportRestore()
        clip: true

        Column {
          id: content
          width: parent.width
          spacing: Style.space(8)
          topPadding: Style.space(14)
          bottomPadding: Style.space(14)
          leftPadding: Style.space(14)
          rightPadding: Style.space(14)

          Row {
            width: parent.width - Style.space(28)
            spacing: Style.space(8)

            TeamMark {
              visible: root.teamDetailOpen && !!root.detailTeam
              width: visible ? markSize : 0
              markSize: Style.space(34)
              abbreviation: root.detailTeam ? root.detailTeam.teamAbbrev : ""
              logoUrl: root.detailTeam ? root.detailTeam.teamLogo : ""
              accentColor: root.teamAccent(root.detailTeam)
            }

            Text {
              width: parent.width - spoilerChip.width
                - (root.teamDetailOpen ? Style.space(42) : 0) - Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: root.teamDetailOpen && root.detailTeam
                ? root.detailTeam.teamName : "Omathlete"
              color: root.barForeground
              elide: Text.ElideRight
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Rectangle {
              id: spoilerChip
              anchors.verticalCenter: parent.verticalCenter
              width: spoilerLabel.implicitWidth + Style.space(14)
              height: Style.space(28)
              radius: height / 2
              color: root.spoilersHidden
                ? Style.selectedFillFor(root.barForeground, Color.accent)
                : Style.normalFillFor(root.barForeground, Color.accent)
              border.width: 1
              border.color: root.spoilersHidden ? Color.accent
                : Style.normalBorderFor(root.barForeground, Color.accent)

              Text {
                id: spoilerLabel
                anchors.centerIn: parent
                text: root.spoilersHidden ? "🙈 Hidden" : "Scores"
                color: root.spoilersHidden ? Color.accent : root.barForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleSpoilers()
              }
            }
          }

          Row {
            visible: !root.searchOpen && !root.teamDetailOpen
            width: parent.width - Style.space(28)
            spacing: Style.space(8)
            Repeater {
              model: ["Agenda · g", "Watch later · l"]
              Rectangle {
                required property string modelData
                required property int index
                width: (content.width - Style.space(36)) / 2
                height: Style.space(30)
                color: Style.normalFillFor(root.barForeground, Color.accent)
                radius: Style.cornerRadius
                Text {
                  anchors.centerIn: parent
                  text: modelData
                  color: root.barForeground
                  font.pixelSize: Style.font.caption
                  font.family: Style.font.family
                }
                MouseArea { anchors.fill: parent; onClicked: root.openPlanner(parent.index === 1) }
              }
            }
          }

          Text {
            visible: !!root.errorMessage || (root.busy && root.teams.length > 0) || root.report.stale
            width: parent.width - Style.space(28)
            text: root.errorMessage || (root.busy ? "↻ Refreshing scores" : "Some teams couldn't update · r to retry")
            wrapMode: Text.WordWrap
            color: root.report.stale ? Color.urgent : Qt.darker(root.barForeground, 1.35)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Row {
            visible: !root.searchOpen && !root.teamDetailOpen
            width: parent.width - Style.space(28)
            spacing: Style.space(8)

            Rectangle {
              width: myTeamsLabel.implicitWidth + Style.space(18)
              height: Style.space(30)
              radius: Style.cornerRadius
              color: !root.fullSlateOpen
                ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent"
              Text {
                id: myTeamsLabel
                anchors.centerIn: parent
                text: "My Teams · " + (root.sortMode === "manual" ? "Manual"
                  : root.sortMode === "next" ? "Next Game" : "League")
                color: root.barForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { if (root.fullSlateOpen) root.toggleFullSlate() }
              }
            }

            Rectangle {
              width: slateLabel.implicitWidth + Style.space(18)
              height: Style.space(30)
              radius: Style.cornerRadius
              color: root.fullSlateOpen
                ? Style.hoverFillFor(root.barForeground, Color.accent) : "transparent"
              Text {
                id: slateLabel
                anchors.centerIn: parent
                text: "Full Slate"
                color: root.barForeground
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { if (!root.fullSlateOpen) root.toggleFullSlate() }
              }
            }
          }

          Column {
            visible: root.searchOpen && !root.teamDetailOpen && !root.fullSlateOpen
            width: parent.width - Style.space(28)
            spacing: Style.space(6)

            Rectangle {
              width: parent.width
              height: Style.space(42)
              radius: Style.cornerRadius
              color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.08)
              border.width: 1
              border.color: searchField.activeFocus ? Color.accent
                : Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.2)

              Text {
                visible: searchField.text.length === 0
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                text: "Search teams…"
                color: Qt.darker(root.barForeground, 1.4)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
              }

              TextInput {
                id: searchField
                anchors.fill: parent
                leftPadding: Style.space(12)
                rightPadding: Style.space(12)
                verticalAlignment: TextInput.AlignVCenter
                color: root.barForeground
                selectionColor: Color.accent
                selectedTextColor: Color.background
                clip: true
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                onTextChanged: searchTimer.restart()

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Down || (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier))) {
                    root.searchSelectedIndex = Math.min(root.searchResults.length - 1, root.searchSelectedIndex + 1)
                    event.accepted = true
                  } else if (event.key === Qt.Key_Up || (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier))) {
                    root.searchSelectedIndex = Math.max(0, root.searchSelectedIndex - 1)
                    event.accepted = true
                  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.followSearchResult()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Escape) {
                    root.closeSearch()
                    event.accepted = true
                  }
                }
              }
            }

            Text {
              visible: searchField.text.length < 2
              text: "Type at least two characters"
              color: Qt.darker(root.barForeground, 1.35)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              visible: root.searchBusy
              text: "Searching every roster…"
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              visible: !root.searchBusy && searchField.text.length >= 2 && root.searchResults.length === 0
              text: "No teams found"
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              id: searchRepeater
              model: root.searchResults
              Rectangle {
                required property var modelData
                required property int index
                width: parent.width
                height: Style.space(42)
                radius: Style.cornerRadius
                color: index === root.searchSelectedIndex
                  ? Style.selectedFillFor(root.barForeground, Color.accent)
                  : "transparent"
                border.width: index === root.searchSelectedIndex ? 1 : 0
                border.color: Style.selectedBorderFor(root.barForeground, Color.accent)

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(9)
                  anchors.rightMargin: Style.space(9)
                  spacing: Style.space(8)
                  Text {
                    width: parent.width - leagueLabel.implicitWidth - Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.teamName
                    color: root.barForeground
                    elide: Text.ElideRight
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    id: leagueLabel
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.league
                    color: Qt.darker(root.barForeground, 1.35)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.searchSelectedIndex = parent.index
                  onClicked: root.followSearchResult()
                }
              }
            }

          }

          Column {
            id: slateContainer
            visible: root.fullSlateOpen
            width: parent.width - Style.space(28)
            spacing: Style.space(4)

            Text {
              visible: !!root.slateError
              width: parent.width
              text: root.slateError
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              color: Color.urgent
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.slateBusy && root.slateGames.length === 0
              text: "Loading today's games…"
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              visible: !root.slateBusy && root.slateGames.length === 0
              width: parent.width
              text: root.teams.length === 0
                ? "Follow a team to choose which leagues appear here."
                : root.slateStale || root.slateError ? "Games unavailable. Press r to retry."
                : "No games today in your teams' leagues."
              color: root.barForeground
              wrapMode: Text.WordWrap
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            ListView {
              id: slateList
              width: parent.width
              height: root.fullSlateOpen
                ? Math.max(Style.space(60), scoreFlick.height - slateContainer.y - y - Style.space(14)) : 0
              clip: true
              reuseItems: true
              cacheBuffer: 0
              spacing: Style.space(4)
              currentIndex: root.slateSelectedIndex
              highlightFollowsCurrentItem: false
              onMovementStarted: root.cancelViewportRestore()
              model: root.slateGames
              delegate: Rectangle {
                required property var modelData
                required property int index
                width: slateList.width
                height: slateGameColumn.implicitHeight + Style.space(16)
                radius: Style.cornerRadius
                color: index === root.slateSelectedIndex
                  ? Style.selectedFillFor(root.barForeground, Color.accent)
                  : "transparent"
                border.width: index === root.slateSelectedIndex ? 1 : 0
                border.color: Style.selectedBorderFor(root.barForeground, Color.accent)

                Column {
                  id: slateGameColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.margins: Style.space(8)
                  spacing: Style.space(2)
                  Text {
                    text: modelData.league + (modelData.state === "in" ? " · LIVE" : "")
                    color: modelData.state === "in" ? Color.accent : Qt.darker(root.barForeground, 1.35)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  Text {
                    width: parent.width
                    text: {
                      var matchup = modelData.awayTeam + " @ " + modelData.homeTeam
                      if (modelData.state === "pre" || root.gameHidden(modelData, modelData.sport)) return matchup
                      return matchup + "  " + modelData.awayScore + "–" + modelData.homeScore
                    }
                    color: root.barForeground
                    elide: Text.ElideRight
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: modelData.state === "in"
                  }
                  Text {
                    width: parent.width
                    text: modelData.state === "pre"
                      ? modelData.when + (modelData.broadcast ? " · " + modelData.broadcast : "")
                      : Logic.statusText(modelData, root.gameHidden(modelData, modelData.sport))
                    color: Qt.darker(root.barForeground, 1.25)
                    elide: Text.ElideRight
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: modelData.gameUrl ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onPositionChanged: if (containsMouse && !root.restoringSlateViewport) root.slateSelectedIndex = parent.index
                  onDoubleClicked: root.openSlateGame()
                }
              }
            }

          }

          Column {
            visible: root.teamDetailOpen && !!root.detailTeam
            width: parent.width - Style.space(28)
            spacing: Style.space(6)

            Text {
              width: parent.width
              text: Logic.freshness(root.detailTeam, root.now)
              visible: text !== ""
              color: Logic.dataStale(root.detailTeam, root.now) ? Color.urgent : root.barForeground
              wrapMode: Text.WordWrap
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.detailTeam && (!root.detailTeam.schedule || root.detailTeam.schedule.length === 0)
              width: parent.width
              text: root.detailTeam && root.detailTeam.stale
                ? "Games unavailable. Press r to retry." : "No recent or upcoming games found."
              color: root.barForeground
              wrapMode: Text.WordWrap
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              width: parent.width
              text: Logic.availability(root.detailTeam) + "\nr: retry this team · d: diagnostics"
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              textFormat: Text.PlainText
              color: root.barForeground
              wrapMode: Text.WordWrap
              font.pixelSize: Style.font.caption
              MouseArea { anchors.fill: parent; onClicked: root.diagnosticsOpen = !root.diagnosticsOpen }
            }
            TextEdit {
              visible: root.diagnosticsOpen
              width: parent.width
              text: Logic.diagnosticSummary(root.teams, root.now)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              textFormat: TextEdit.PlainText
              readOnly: true
              selectByMouse: true
              activeFocusOnTab: visible
              color: root.barForeground
              font.pixelSize: Style.font.caption
              wrapMode: TextEdit.Wrap
              Accessible.name: "Diagnostic summary. Select all and copy to share. No scores or team identities included."
            }
            Repeater {
              id: detailRepeater
              model: root.detailTeam && root.detailTeam.schedule ? root.detailTeam.schedule : []
              Rectangle {
                required property var modelData
                required property int index
                width: parent.width
                height: detailGameColumn.implicitHeight + Style.space(18)
                radius: Style.cornerRadius
                color: index === root.gameSelectedIndex
                  ? Style.selectedFillFor(root.barForeground, Color.accent)
                  : "transparent"
                border.width: index === root.gameSelectedIndex ? 1 : 0
                border.color: Style.selectedBorderFor(root.barForeground, Color.accent)

                Column {
                  id: detailGameColumn
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.margins: Style.space(9)
                  spacing: Style.space(3)

                  Text {
                    text: modelData.section
                    color: modelData.kind === "live" ? Color.accent : Qt.darker(root.barForeground, 1.35)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1
                  }
                  Text {
                    width: parent.width
                    text: {
                      var matchup = root.detailTeam.teamAbbrev
                        + (modelData.isHome ? " vs " : " @ ") + modelData.opponent
                      if (modelData.kind === "upcoming" || root.gameHidden(modelData, root.detailTeam.sport)) return matchup
                      return matchup + "  " + modelData.teamScore + "–" + modelData.opponentScore
                    }
                    color: root.barForeground
                    elide: Text.ElideRight
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                  }
                  Text {
                    width: parent.width
                    text: modelData.when
                      + (modelData.kind === "upcoming"
                        ? " · " + Logic.statusText(modelData, true) + " · " + (modelData.broadcast || "TV TBA")
                        : " · " + Logic.statusText(modelData, root.gameHidden(modelData, root.detailTeam.sport))
                          + (modelData.broadcast ? " · " + modelData.broadcast : ""))
                    color: Qt.darker(root.barForeground, 1.25)
                    wrapMode: Text.WordWrap
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                  Text {
                    width: parent.width
                    text: Logic.gameContext(modelData, root.gameHidden(modelData, root.detailTeam.sport))
                      + (!modelData.broadcast ? " · TV network not supplied by ESPN" : "")
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    textFormat: Text.PlainText
                    color: root.barForeground
                    wrapMode: Text.WordWrap
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: modelData.gameUrl ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onPositionChanged: if (containsMouse && !root.restoringViewport) root.gameSelectedIndex = parent.index
                  onDoubleClicked: root.openSelectedGame()
                }
              }
            }

          }

          Text {
            visible: !root.searchOpen && !root.teamDetailOpen && !root.fullSlateOpen
              && root.teams.length === 0 && !root.busy
            width: parent.width - Style.space(28)
            text: root.errorMessage || "No favorite teams yet. Press / to find one."
            color: root.barForeground
            wrapMode: Text.WordWrap
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          Text {
            visible: !root.searchOpen && !root.teamDetailOpen && !root.fullSlateOpen
              && root.busy && root.teams.length === 0
            text: "Finding the action…"
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }

          Repeater {
            id: teamRepeater
            visible: !root.searchOpen && !root.teamDetailOpen
            model: root.teams
            Rectangle {
              required property var modelData
              required property int index
              visible: !root.searchOpen && !root.teamDetailOpen && !root.fullSlateOpen
              width: content.width - Style.space(28)
              height: visible ? gameColumn.implicitHeight + Style.space(18) : 0
              radius: Style.cornerRadius
              color: index === root.selectedIndex
                ? Style.selectedFillFor(root.barForeground, root.teamAccent(modelData))
                : root.scoreFlashTeams[modelData.sport + ":" + modelData.teamId]
                  ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
                  : "transparent"
              border.width: index === root.selectedIndex ? 1 : 0
              border.color: Style.selectedBorderFor(root.barForeground, root.teamAccent(modelData))

              Rectangle {
                width: Style.space(3)
                height: parent.height - Style.space(14)
                anchors.left: parent.left
                anchors.leftMargin: Style.space(3)
                anchors.verticalCenter: parent.verticalCenter
                radius: width / 2
                color: root.teamAccent(modelData)
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onPositionChanged: if (containsMouse && !root.restoringViewport) root.selectedIndex = parent.index
                onDoubleClicked: root.openTeamDetail()
              }

              Row {
                id: gameColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(9)
                anchors.leftMargin: Style.space(14)
                spacing: Style.space(10)

                TeamMark {
                  anchors.verticalCenter: parent.verticalCenter
                  abbreviation: modelData.teamAbbrev || ""
                  logoUrl: modelData.teamLogo || ""
                  accentColor: root.teamAccent(modelData)
                }

                Column {
                  width: parent.width - Style.space(46)
                  spacing: Style.space(3)

                  Row {
                    width: parent.width
                    spacing: Style.space(7)
                    Rectangle {
                      visible: !!modelData.current && modelData.current.state === "in"
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(7)
                      height: width
                      radius: width / 2
                      color: Color.accent
                    }
                    Text {
                      width: parent.width
                        - (modelData.current && modelData.current.state === "in" ? Style.space(14) : 0)
                        - (pinLabel.visible ? pinLabel.implicitWidth + Style.space(7) : 0)
                      text: modelData.teamName || modelData.teamAbbrev
                      color: root.barForeground
                      elide: Text.ElideRight
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.subtitle
                      font.bold: true
                    }
                    Text {
                      id: pinLabel
                      visible: !!root.pinnedTeam
                        && root.pinnedTeam.sport === modelData.sport
                        && root.pinnedTeam.teamId === modelData.teamId
                      text: "PIN"
                      color: Color.accent
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }
                  Text {
                    width: parent.width
                    text: {
                      var game = modelData.current
                      if (!game) return modelData.loading && !modelData.updatedAt ? "Loading games…"
                        : modelData.stale && !modelData.updatedAt ? "Games unavailable" : "No recent game"
                      var hidden = root.gameHidden(game, modelData.sport)
                      var score = hidden ? "" : " · " + game.teamScore + "–" + game.opponentScore
                      return (game.isHome ? "vs " : "@ ") + game.opponent + score + " · " + Logic.statusText(game, hidden)
                    }
                    color: root.barForeground
                    elide: Text.ElideRight
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Row {
                    visible: !!modelData.upcoming
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                      width: parent.width - homeBroadcast.width - parent.spacing
                      text: modelData.upcoming
                        ? "Next: " + (modelData.upcoming.isHome ? "vs " : "@ ")
                          + modelData.upcoming.opponent + " · " + modelData.upcoming.when
                        : ""
                      color: Qt.darker(root.barForeground, 1.25)
                      elide: Text.ElideRight
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                      id: homeBroadcast
                      width: Math.min(implicitWidth, Style.space(72))
                      text: modelData.upcoming && modelData.upcoming.broadcast
                        ? modelData.upcoming.broadcast : "TV TBA"
                      color: Color.accent
                      horizontalAlignment: Text.AlignRight
                      elide: Text.ElideRight
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                  }
                  Text {
                    width: parent.width
                    text: Logic.freshness(modelData, root.now)
                    visible: text !== ""
                    color: Logic.dataStale(modelData, root.now) ? Color.urgent : root.barForeground
                    wrapMode: Text.WordWrap
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

        }
      }

      PlannerView {
        id: plannerView
        visible: root.plannerOpen
        anchors.top: parent.top
        anchors.bottom: shortcutFooter.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.space(14)
        rows: Logic.plannerRows(root.teams, root.preferences, root.agendaRange, root.watchLaterOpen, root.now)
        range: root.agendaRange
        watchLater: root.watchLaterOpen
        now: root.now
        quietHours: root.preferences.quietHours !== false
        warning: root.errorMessage || (root.report.stale ? "Some schedules are cached or unavailable." : "")
        isHidden: function(game) { return root.gameHidden(game, game.sport) }
        onChooseRange: function(value) { root.agendaRange = value; root.watchLaterOpen = false; revealedKey = "" }
        onChooseQueue: function(value) { root.watchLaterOpen = value; revealedKey = "" }
        onWatchGame: function(game) { revealedKey = ""; root.queuePreference(["watch-game", game.sport, game.id], game) }
        onRemindGame: function(game) { root.queuePreference(["remind-game", game.sport, game.id], game) }
        onQuietToggle: root.queuePreference(["toggle-quiet"])
        onLaunch: function(game) { root.launchGameUrl(game.gameUrl) }
        onBack: root.closePlanner()
        onRefresh: root.refresh(true)
        onSpoilersToggle: root.toggleSpoilers()
      }

      Rectangle {
        id: shortcutFooter
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: shortcutLabel.implicitHeight + Style.space(16)
        color: Color.background
        border.width: 0

        Rectangle {
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: 1
          color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.16)
        }

        Text {
          id: shortcutLabel
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(14)
          anchors.rightMargin: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          text: root.plannerOpen
            ? "? shortcuts   tab focus   l agenda/queue   j/k move   w watch/remove   b bell   v reveal   esc back"
            : root.searchOpen
            ? "↑/↓ move   enter follow   esc back"
            : root.fullSlateOpen
              ? "a my teams   j/k move   o open ESPN   s spoilers   r refresh"
              : root.teamDetailOpen
                ? "j/k move   o open ESPN   w watch later   b bell   s spoilers   r retry team   d diagnostics   h/esc back"
                : "/ search   a slate   j/k move   o sort   p pin   enter details"
                  + (root.sortMode === "manual" ? "   shift+j/k reorder" : "")
                  + "   x remove   s spoilers   g agenda   l watch later"
          color: Qt.darker(root.barForeground, 1.4)
          wrapMode: Text.WordWrap
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
