import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const logic = vm.createContext({});
const focusSource = fs.readFileSync(new URL('../Panel.qml',import.meta.url),'utf8');
assert.match(focusSource,/focusTarget: root\.plannerOpen \? plannerView : keyCatcher/);
assert.match(focusSource,/id: keyCatcher\s+blocked: root\.plannerOpen/);
assert.match(focusSource,/if \(root\.plannerOpen\) plannerView\.focusNext\(direction < 0\)/);
// Text is not a Controls label: QtQuick does not inherit the theme font.
for (const file of ['Panel.qml', 'PlannerView.qml']) {
  const source = fs.readFileSync(new URL('../' + file, import.meta.url), 'utf8');
  for (const match of source.matchAll(/^([ \t]*)(?:section\.delegate: )?(?:Text|TextEdit|TextInput)\s*\{/gm)) {
    const end = source.indexOf('\n' + match[1] + '}', match.index);
    const ownProperties = source.slice(match.index, end);
    assert.match(ownProperties, /font\.family:/, `${file}: text must explicitly use the theme font`);
  }
}
vm.runInContext(fs.readFileSync(new URL('../PanelLogic.js', import.meta.url), 'utf8'), logic);
const now = Date.parse('2026-09-05T18:00:00Z');
const liveTeam = {teamAbbrev:'CHC',updatedAt:now/1000,current:{state:'in',detail:'Top 7th',teamScore:'3',opponentScore:'8'}};
assert.equal(logic.dataStale(liveTeam,now),false);
assert.equal(logic.dataStale(liveTeam,now+121000),true,'Live data ages even without a completed refresh');
assert.match(logic.liveLabel(liveTeam,false,now+121000),/^Cached · CHC 3–8/);
assert.equal(logic.liveLabel(liveTeam,true,now+121000),'Cached · CHC · Live');
assert.ok(!logic.liveLabel(liveTeam,true,now+121000).includes('7th'));
assert.match(logic.freshness(liveTeam,now+121000),/^Cached/);
assert.equal(logic.dataStale({...liveTeam,stale:true},now),true);
assert.match(logic.liveLabel({...liveTeam,current:{...liveTeam.current,scoreStale:true}},false,now),/^Stale/);
assert.match(logic.freshness({...liveTeam,current:{...liveTeam.current,scoreStale:true}},now),/update failed/);
assert.equal(logic.dataStale({...liveTeam,updatedAt:(now+121000)/1000},now+121000),false,'Successful refresh clears stale state');
const team = {sport: 'mlb', teamId: '16', teamAbbrev: 'CHC',
  upcoming: {id: 'game-1', date: new Date(now + 3600000).toISOString()}};
assert.equal(logic.refreshInterval([team], false, now), 300000);
assert.equal(logic.refreshInterval([team], false, now + 50 * 60000), 60000);
assert.equal(logic.refreshInterval([team], false, now + 61 * 60000), 60000);
assert.equal(logic.refreshInterval([team], true, now), 60000);
assert.equal(logic.refreshInterval([], false, now), 300000);
assert.equal(logic.countdown(team.upcoming.date, now), '1h');
assert.equal(logic.countdown(team.upcoming.date, now + 50 * 60000), '10m');
assert.equal(logic.countdown(team.upcoming.date, now + 61 * 60000), 'Starting');
assert.equal(logic.countdown('invalid', now), 'TBD');

for (const state of ['in', 'post', 'pre']) {
  const status = logic.statusText({state, detail: 'Cubs win 4–2 on penalties'}, true);
  assert.ok(!/Cubs|win|4|2|penalties/.test(status));
}
assert.equal(logic.freshness({stale: true, updatedAt: now / 1000 - 240}, now), 'Cached · updated 4m ago');
assert.match(logic.freshness({stale: true}, now), /Couldn't load/);

// Exercise the actual panel methods with controllable process/timer substitutes.
const source = fs.readFileSync(new URL('../Panel.qml', import.meta.url), 'utf8');
const calls = [];
const panel = vm.createContext({Logic: logic, console,
  Qt: {callLater: callback => calls.push(callback)},
  report: {teams: [team]}, savedPreferences: {teams: [team], spoilersHidden: false},
  preferences: {teams: [team], spoilersHidden: false, sortMode: 'manual'},
  preferencesReady: true, preferenceQueue: [],
  selectedIndex: 0, pendingSelectionKey: '', gameSelectedIndex: 0,
  viewportGeneration: 0, pendingViewport: null, restoringViewport: false,
  slateViewportGeneration: 0, restoringSlateViewport: false,
  searchOpen: false, teamDetailOpen: false, plannerOpen: false, slateGames: [], slateSelectedIndex: 0,
  detailTeamKey: {sport: 'mlb', teamId: '16'},
  detailProcess: {running: true}, preferenceProcess: {running: false},
  scoreFlashTimer: {restart() {}}, scoreFlashTeams: {},
  refreshPending: false, forceRefreshPending: false, backend: '/test/backend',
  lastRefreshAt: 0, busy: false, errorMessage: ''});
panel.root = panel;
for (const match of source.matchAll(/^  function \w+\([^\n]*\) \{[\s\S]*?^  \}/gm))
  vm.runInContext(match[0], panel);
Object.defineProperties(panel, {
  teams: {get: () => panel.sortedTeams(panel.report.teams || [])},
  sortMode: {get: () => panel.preferences.sortMode || 'manual'},
  pinnedTeam: {get: () => panel.preferences.pinnedTeam || null},
  spoilersHidden: {get: () => !panel.preferencesReady || panel.preferences.spoilersHidden},
  detailTeam: {get: () => panel.findTeam(panel.detailTeamKey)}
});

// A slow network request cannot delay local changes or overwrite them on completion.
panel.toggleSpoilers();
assert.equal(panel.spoilersHidden, true);
panel.cycleSort();
panel.togglePinSelected();
assert.equal(panel.sortMode, 'next');
assert.equal(panel.pinnedTeam.teamId, '16');
assert.equal(panel.preferenceQueue.length, 3);
assert.equal(panel.preferenceProcess.command[1], 'toggle-spoilers');
panel.adoptReport({spoilersHidden: false, sortMode: 'manual', pinnedTeam: null, teams: [team]});
assert.equal(panel.spoilersHidden, true);
assert.equal(panel.sortMode, 'next');
assert.equal(panel.pinnedTeam.teamId, '16');

// Completing the first save must preserve later optimistic changes.
panel.finishPreference(0, logic.applyPreference(panel.savedPreferences, panel.preferenceQueue[0]));
assert.equal(panel.spoilersHidden, true);
assert.equal(panel.sortMode, 'next');
assert.equal(panel.pinnedTeam.teamId, '16');

// A failed save rolls back that action while later pending actions stay applied.
panel.finishPreference(1, null);
assert.equal(panel.sortMode, 'manual');
assert.equal(panel.spoilersHidden, true);
assert.equal(panel.pinnedTeam.teamId, '16');
assert.match(panel.errorMessage, /Could not save/);

// A queued force refresh is remembered while the network process is occupied.
panel.refresh(true);
assert.equal(panel.refreshPending, true);
assert.equal(panel.forceRefreshPending, true);

// The actual closed-panel timer starts a request at the background deadline.
panel.opened = false;
panel.fullSlateOpen = false;
panel.detailProcess.running = false;
panel.lastRefreshAt = Date.now() - 300000;
panel.tick();
assert.equal(panel.detailProcess.running, true);
assert.equal(panel.detailProcess.command[1], 'detail-stream');

// Details resolve fresh objects and follow a selected game across kickoff/reordering.
panel.report = {teams: [{...team, schedule: [{id: 'older'}, {...team.upcoming}]}]};
panel.gameSelectedIndex = 1;
const live = {...team.upcoming, state: 'in', teamScore: '1', opponentScore: '0'};
panel.adoptReport({teams: [{...team, current: live, schedule: [live, {id: 'older'}]}]});
assert.equal(panel.detailTeam.current.teamScore, '1');
assert.equal(panel.gameSelectedIndex, 0);
panel.adoptReport({teams: [{...team, current: {...live, teamScore: '2'}, schedule: [{...live, teamScore: '2'}]}]});
assert.equal(panel.detailTeam.schedule[0].teamScore, '2');
assert.equal(panel.gameSelectedIndex, 0);
assert.equal(logic.selectedGameIndex([], 'removed', 3), 0);

// Incremental results retain other teams and never replace fresh data with a cache snapshot.
const other = {sport: 'nba', teamId: '4', teamAbbrev: 'CHI', upcoming: {date: '2026-09-06T18:00:00Z'}};
panel.preferences = {...panel.preferences, teams: [team, other]};
panel.adoptTeamMessage({type: 'snapshot', teams: [{...team, current: {teamScore: 'old'}}, other]});
assert.equal(panel.report.teams.length, 2);
assert.equal(panel.findTeam(team).current.teamScore, '2');
panel.adoptTeamMessage({type: 'team', team: {...other, current: {state: 'in', teamScore: '44'}}});
assert.equal(panel.findTeam(other).current.teamScore, '44');
assert.equal(panel.findTeam(team).current.teamScore, '2');
assert.equal(panel.report.teams.length, 2);

function flush() { while (calls.length) calls.shift()(); }
flush();
panel.opened = true;
panel.fullSlateOpen = false;
panel.content = {};
panel.scoreFlick = {contentY: 100, contentHeight: 500, height: 250};
const third = {sport: 'mlb', teamId: '12', teamAbbrev: 'SEA'};
const fourth = {sport: 'nfl', teamId: '3', teamAbbrev: 'CHI'};
panel.preferences = {...panel.preferences, teams: [team, other, third, fourth], sortMode: 'next'};
panel.report = {teams: [team, other, third, fourth]};
panel.teamRepeater = {itemAt: index => index >= 0 && index < panel.teams.length
  ? {height: 100, mapToItem: () => ({y: index * 100})} : null};
panel.selectedIndex = 1;
const selectedKey = panel.teamKey(panel.teams[1]);
// The selected row starts 0px below the viewport top; keep it there as it moves.
panel.adoptReport({teams: [team, other, {...third, current: {state: 'in'}}, fourth]});
flush();
assert.equal(panel.teamKey(panel.teams[panel.selectedIndex]), selectedKey);
assert.equal(panel.scoreFlick.contentY, 200);

// Full Slate preserves identity across rank changes, including identical ESPN IDs in different leagues.
panel.fullSlateOpen = true;
panel.slateGames = [{sport: 'mlb', id: '1'}, {sport: 'nba', id: '1'}, {sport: 'mls', id: '2'}];
panel.slateSelectedIndex = 1;
panel.slateList = {contentY: 100, height: 100,
  indexAt: (_x, y) => Math.floor(y / 100),
  itemAtIndex: index => index >= 0 && index < panel.slateGames.length ? {y: index * 100, height: 100} : null,
  forceLayout() {}, positionViewAtIndex(index) { this.contentY = index * 100; }, returnToBounds() {}};
panel.ListView = {Beginning: 0};
panel.adoptSlate({games: [{sport: 'nba', id: '1'}, {sport: 'mls', id: '2'}, {sport: 'mlb', id: '1'}]});
flush();
assert.equal(panel.slateSelectedIndex, 0);
assert.equal(panel.slateList.contentY, 0);
assert.equal(panel.restoringSlateViewport, false);

// A late update from a removed team must not bring it back or displace a new favorite.
panel.preferences = {...panel.preferences, teams: [team]};
panel.adoptTeamMessage({type: 'team', team: other});
assert.equal(panel.report.teams.length, 1);
assert.equal(panel.report.teams[0].teamId, team.teamId);

// Explicit navigation cancels a deferred background scroll correction.
panel.fullSlateOpen = false;
panel.scoreFlick.contentY = 50;
panel.restoreViewport({y: 0, detail: false});
panel.cancelViewportRestore();
flush();
assert.equal(panel.scoreFlick.contentY, 50);

console.log('Omathlete panel interaction tests passed.');
