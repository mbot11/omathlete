import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
const logic = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(repo, 'PanelLogic.js'), 'utf8'), logic);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'omathlete-planner-'));
const now = Date.parse('2026-09-05T17:00:00Z') / 1000;
const env = {...process.env, TZ:'America/Chicago', XDG_STATE_HOME:path.join(tmp,'state'),
  XDG_CACHE_HOME:path.join(tmp,'cache'), OMATHLETE_TESTING:'1', OMATHLETE_NOW:String(now),
  OMATHLETE_NOTIFY_LOG:path.join(tmp,'notifications.log')};
const statePath = path.join(env.XDG_STATE_HOME,'omarchy/settings/omathlete.json');
const cachePath = path.join(env.XDG_CACHE_HOME,'omarchy/omathlete/mlb-16.json');
const team = {sport:'mlb',teamId:'16',teamName:'Chicago Cubs',teamAbbrev:'CHC'};
const game = {id:'401234',date:new Date((now+900)*1000).toISOString(),homeTeam:'CHC',awayTeam:'SEA',
  isHome:true,opponent:'SEA',teamScore:'9',opponentScore:'1',state:'pre',detail:'Scheduled',broadcast:'FOX',gameUrl:'https://www.espn.com/mlb/game/_/gameId/401234'};
function cache(event = game, at = now) {
  fs.writeFileSync(cachePath,JSON.stringify({...team,current:event,upcoming:event,schedule:[event],agenda:[event],updatedAt:at}));
  fs.utimesSync(cachePath,at,at);
}
function run(args, extra={}) {
  const result = spawnSync(path.join(repo,'bin/omathlete'),args,{env:{...env,...extra},encoding:'utf8',timeout:20000});
  assert.equal(result.status,0,result.stderr);
  return JSON.parse(result.stdout);
}
try {
  fs.mkdirSync(path.dirname(statePath),{recursive:true});
  fs.mkdirSync(path.dirname(cachePath),{recursive:true});
  fs.writeFileSync(statePath,JSON.stringify({schemaVersion:1,spoilersHidden:false,teams:[team]}));
  cache();
  const initial = run(['state']);
  assert.equal(initial.teams.length,1);
  assert.deepEqual(initial.watchLater,[]);
  assert.deepEqual(initial.reminders,[]);
  assert.equal(initial.quietHours,true);
  let state = run(['watch-game','mlb',game.id]);
  assert.equal(state.watchLater.length,1);
  assert.equal(state.watchLater[0].teamScore,undefined,'Queue stores metadata, not results');
  assert.ok(logic.protectedGame(game,'mlb',state));
  state = run(['cycle-sort']);
  assert.equal(state.watchLater.length,1,'Unrelated settings preserve the queue');
  state = run(['remind-game','mlb',game.id]);
  assert.equal(state.reminders[0].leadMinutes,15);
  for (const statusName of ['STATUS_DELAYED','STATUS_SUSPENDED','STATUS_POSTPONED','STATUS_CANCELED']) {
    cache({...game,statusName,detail:'Scheduled'});
    assert.equal(run(['check-reminders']).sent,0,'Interrupted games must not send kickoff reminders');
  }
  cache();
  assert.equal(run(['check-reminders']).sent,1);
  assert.equal(run(['check-reminders']).sent,0,'Restarted checker must not send twice');
  const notice = fs.readFileSync(env.OMATHLETE_NOTIFY_LOG,'utf8');
  assert.ok(notice.includes('SEA @ CHC') && notice.includes('FOX'));
  assert.ok(!notice.includes('9–1') && !notice.includes('Scheduled'));
  assert.equal(run(['remind-game','mlb',game.id]).reminders[0].leadMinutes,0);
  cache({...game,state:'in'},now+900);
  assert.equal(run(['check-reminders'],{OMATHLETE_NOW:String(now+900)}).sent,1,'Start-time reminder works after live transition');
  assert.deepEqual(run(['remind-game','mlb',game.id]).reminders,[]);

  // Quiet hours and stale/missed deadlines do not produce a catch-up burst.
  const night = Date.parse('2026-09-06T04:00:00Z')/1000;
  cache({...game,date:new Date((night+900)*1000).toISOString()},night);
  run(['remind-game','mlb',game.id]);
  assert.equal(run(['check-reminders'],{OMATHLETE_NOW:String(night)}).sent,0);
  run(['toggle-quiet']);
  assert.equal(run(['check-reminders'],{OMATHLETE_NOW:String(night)}).sent,1);
  cache({...game,date:new Date((night+3600)*1000).toISOString()},night);
  assert.equal(run(['check-reminders'],{OMATHLETE_NOW:String(night+2700)}).sent,0,'Old cache is not used');
  cache({...game,date:new Date((night+900)*1000).toISOString()},night+400);
  assert.equal(run(['check-reminders'],{OMATHLETE_NOW:String(night+400)}).sent,0,'Missed reminder is not delivered late');
  assert.deepEqual(run(['watch-game','mlb',game.id]).watchLater,[]);

  // Both followed teams in a fixture yield one agenda row, with correctly oriented scores.
  const rows = logic.agendaGames([{...team,agenda:[game]},
    {sport:'mlb',teamId:'12',teamAbbrev:'SEA',agenda:[{...game,isHome:false,teamScore:'1',opponentScore:'9'}]}]);
  assert.equal(rows.length,1);
  assert.equal(rows[0].homeScore,'9');
  assert.equal(rows[0].awayScore,'1');
  const saved = {...logic.preferences(initial),watchLater:[{...game,sport:'mlb'}]};
  assert.equal(logic.plannerRows([],saved,0,true,now*1000)[0].state,'unknown','Saved game survives disappearing from provider window');
  assert.ok(logic.protectedGame(game,'mlb',saved));
  assert.ok(logic.protectedGame(game,'mlb',{...initial,spoilersHidden:true}));
  assert.ok(!logic.protectedGame(game,'mlb',initial));
  const bounds = logic.agendaRange(3,now*1000);
  assert.ok(now*1000 >= bounds[0] && now*1000 < bounds[1]);
  const weekend = logic.agendaRange(2,now*1000);
  assert.equal(new Date(weekend[0]).getDay(),6);
  assert.equal(new Date(weekend[1]).getDay(),1);

  // Optional planner fields are sanitized without discarding legacy favorite teams.
  fs.writeFileSync(statePath,JSON.stringify({...initial,watchLater:[{...game,sport:'../../bad'}],reminders:'bad'}));
  const clean = run(['state']);
  assert.equal(clean.teams.length,1);
  assert.deepEqual(clean.watchLater,[]);
  assert.deepEqual(clean.reminders,[]);
  const detail = run(['detail','--no-cache'],{OMATHLETE_CURL_BIN:path.join(repo,'tests/fixture-curl'),OMATHLETE_FIXTURE_CURRENT_DATES:'1'});
  assert.equal(detail.teams[0].agenda.length,2,'Provider normalization exposes the agenda window separately from detail rows');
  assert.ok(detail.teams[0].agenda.every(game => game.homeTeam && game.awayTeam && game.id));
  assert.ok(detail.teams[0].schedule.length <= 5);
  assert.equal(detail.teams[0].schedule[0].venue,'Fixture Stadium');
  assert.equal(detail.teams[0].schedule[0].teamRecord,'10-5');
  const missingScoresEnv = {OMATHLETE_CURL_BIN:path.join(repo,'tests/fixture-curl'),
    OMATHLETE_FIXTURE_CURRENT_DATES:'1',OMATHLETE_FIXTURE_MISSING_LIVE_SCORES:'1'};
  const liveDetail = run(['detail','--no-cache'],missingScoresEnv).teams[0];
  assert.equal(liveDetail.current.teamScore,'14','Live scoreboard fills absent schedule scores');
  assert.equal(liveDetail.current.opponentScore,'7');
  assert.equal(liveDetail.agenda.find(g=>g.id===liveDetail.current.id).teamScore,'14');
  const utcGameDay = new Date(Date.now()-3600000);
  utcGameDay.setUTCDate(utcGameDay.getUTCDate()-1);
  const previousScoreboardDay = utcGameDay.toISOString().slice(0,10).replaceAll('-','');
  const evening = run(['detail','--no-cache'],{...missingScoresEnv,
    OMATHLETE_FIXTURE_SCOREBOARD_DAY:previousScoreboardDay}).teams[0];
  assert.equal(evening.current.teamScore,'14','Live game can be filed under the day before its UTC start');
  assert.equal(evening.current.opponentScore,'7');
  assert.equal(evening.current.scoreStale,false);
  const noScoreboard = run(['detail','--no-cache'],{...missingScoresEnv,OMATHLETE_FIXTURE_SCOREBOARD_FAILURE:'1'}).teams[0];
  assert.equal(noScoreboard.current.teamScore,'?','Missing score never becomes a fabricated zero or stale score');
  assert.equal(noScoreboard.current.opponentScore,'?');
  assert.equal(noScoreboard.current.scoreStale,true);
  const started = run(['detail','--no-cache'],{...missingScoresEnv,
    OMATHLETE_FIXTURE_SCHEDULE_STATE:'pre',OMATHLETE_FIXTURE_BOARD_STATE:'in'}).teams[0];
  assert.equal(started.current.state,'in','Scoreboard promotes a lagging scheduled game');
  const ended = run(['detail','--no-cache'],{...missingScoresEnv,
    OMATHLETE_FIXTURE_BOARD_STATE:'post',OMATHLETE_FIXTURE_STATUS_NAME:'STATUS_FINAL'}).teams[0];
  assert.equal(ended.current.state,'post');
  assert.equal(ended.schedule[0].section,'LATEST','Final game is no longer placed in LIVE');
  const retained = run(['detail','--no-cache'],{...missingScoresEnv,
    OMATHLETE_FIXTURE_SCHEDULE_STATE:'post',OMATHLETE_FIXTURE_GAME_AGE:'90000',
    OMATHLETE_FIXTURE_SCOREBOARD_FAILURE:'1'}).teams[0];
  assert.equal(retained.current.teamScore,'14','Known final survives missing scores beyond the live window');
  assert.equal(retained.current.scoreCached,true);
  assert.equal(retained.current.scoreUpdatedAt,ended.current.scoreUpdatedAt,'Cache reuse preserves original score timestamp');
  const otherFinal = run(['detail','--no-cache'],{...missingScoresEnv,
    OMATHLETE_FIXTURE_SCHEDULE_STATE:'post',OMATHLETE_FIXTURE_GAME_AGE:'90000',
    OMATHLETE_FIXTURE_SCOREBOARD_FAILURE:'1',OMATHLETE_FIXTURE_GAME_ID:'another-final'}).teams[0];
  assert.equal(otherFinal.current.teamScore,'?','A different final cannot borrow a prior game score');
  for (const name of ['STATUS_POSTPONED','STATUS_CANCELED','STATUS_SUSPENDED']) {
    const changed = run(['detail','--no-cache'],{...missingScoresEnv,
      OMATHLETE_FIXTURE_STATUS_NAME:name}).teams[0];
    assert.ok(changed.schedule.some(g=>g.section==='SCHEDULE CHANGE'));
    assert.ok(!changed.current || changed.current.id !== 'live-mlb');
    assert.ok(!changed.upcoming || changed.upcoming.id !== 'live-mlb');
    assert.notEqual(logic.statusText({statusName:name,state:'in'},true),'Live');
  }
  const delayed = run(['detail','--no-cache'],{...missingScoresEnv,
    OMATHLETE_FIXTURE_SCHEDULE_STATE:'pre',OMATHLETE_FIXTURE_BOARD_STATE:'pre',
    OMATHLETE_FIXTURE_STATUS_NAME:'STATUS_DELAYED',OMATHLETE_FIXTURE_GAME_AGE:'21600'}).teams[0];
  assert.equal(delayed.upcoming.id,'live-mlb','Long delay is not dropped by the kickoff grace window');
  assert.equal(logic.statusText(delayed.upcoming,true),'Delayed');
  const overnight = run(['detail','--no-cache'],{...missingScoresEnv,
    OMATHLETE_FIXTURE_GAME_AGE:'72000',OMATHLETE_FIXTURE_STATUS_NAME:'STATUS_IN_PROGRESS'}).teams[0];
  assert.equal(overnight.current.teamScore,'14','An ongoing game still uses its start-date scoreboard after midnight');
  const overtime = run(['detail','--no-cache'],{...missingScoresEnv,
    OMATHLETE_FIXTURE_STATUS_NAME:'STATUS_IN_PROGRESS',OMATHLETE_FIXTURE_STATUS_DETAIL:'OT 2:15'}).teams[0];
  assert.equal(overtime.current.state,'in');
  assert.equal(logic.statusText(overtime.current,false),'OT 2:15');
  assert.equal(logic.statusText(overtime.current,true),'Live');
  const context = {...game,venue:'Fixture Stadium',teamRecord:'10-5',opponentRecord:'8-7'};
  assert.equal(logic.contrastingInk({r:1,g:1,b:1}),'#000000');
  assert.equal(logic.contrastingInk({r:0,g:0,b:0}),'#ffffff');
  assert.equal(logic.contrastingInk({r:1,g:0.667,b:0.267}),'#000000');
  assert.match(logic.gameContext(context,false),/10-5/);
  assert.ok(!logic.gameContext(context,true).includes('10-5'));
  assert.match(logic.gameContext(context,true),/Home game.*Fixture Stadium/);
  assert.match(logic.availability({loading:true}),/Loading/);
  assert.match(logic.availability({stale:true,updatedAt:now}),/cached/);
  assert.match(logic.availability({stale:true}),/validation failed/);
  assert.match(logic.availability({schedule:[]}),/does not confirm an off-season/);
  const diagnostic = logic.diagnosticSummary([{...team,stale:true,updatedAt:now-600,schedule:[game]}],now*1000);
  assert.equal(JSON.parse(diagnostic).oldestCacheMinutes,10);
  for (const secret of ['Chicago','CHC','401234','https:', 'teamScore']) assert.ok(!diagnostic.includes(secret));
  for (const date of ['2026-09-05T23:59:59','2026-09-06T00:00:00','2026-03-08T12:00:00','2026-11-01T12:00:00']) {
    const time = new Date(date).getTime();
    const today = logic.agendaRange(0,time), tomorrow = logic.agendaRange(1,time);
    assert.equal(today[1],tomorrow[0]);
    assert.equal(new Date(today[0]).getHours(),0);
    assert.ok(time >= today[0] && time < today[1]);
    const boundaryTeam = {...team,agenda:[{...game,id:'start',date:new Date(today[0]).toISOString()},
      {...game,id:'end',date:new Date(today[1]).toISOString()}]};
    const selected = logic.plannerRows([boundaryTeam],initial,0,false,time);
    assert.equal(selected.length,1);
    assert.equal(selected[0].id,'start','Agenda includes midnight start but excludes the next midnight');
  }
  console.log('Omathlete planner and reminder tests passed.');
} finally { fs.rmSync(tmp,{recursive:true,force:true}); }
