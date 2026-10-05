import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const repo = fileURLToPath(new URL('../', import.meta.url));
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'omathlete-loading-'));
const env = {...process.env, XDG_STATE_HOME: path.join(tmp, 'state'), XDG_CACHE_HOME: path.join(tmp, 'cache'),
  OMATHLETE_TESTING: '1', OMATHLETE_CURL_BIN: path.join(repo, 'tests/fixture-curl')};
const backend = path.join(repo, 'bin/omathlete');
const statePath = path.join(env.XDG_STATE_HOME, 'omarchy/settings/omathlete.json');
const cache = path.join(env.XDG_CACHE_HOME, 'omarchy/omathlete');
const fixtureTeams = JSON.parse(fs.readFileSync(path.join(repo, 'tests/fixtures/provider-teams.json')));
function state(sports) {
  const teams = sports.map(sport => {
    const {teamId, teamName, teamAbbrev} = fixtureTeams.find(team => team.sport === sport);
    return {sport, teamId, teamName, teamAbbrev};
  });
  fs.writeFileSync(statePath, JSON.stringify({schemaVersion: 1, spoilersHidden: true, teams}));
}
function run(args, extra = {}) {
  const result = spawnSync(backend, args, {env: {...env, ...extra}, encoding: 'utf8', timeout: 20000, maxBuffer: 3 * 1024 * 1024});
  assert.equal(result.status, 0, result.stderr || String(result.error));
  assert.ok(!result.stderr.includes('wait:'), result.stderr);
  return result.stdout;
}
try {
  fs.mkdirSync(path.dirname(statePath), {recursive: true});
  state(['mlb', 'nba']);
  run(['detail', '--no-cache']);
  const targetKey = 'mlb:' + fixtureTeams.find(team => team.sport === 'mlb').teamId;
  const targeted = run(['detail-stream','--team',targetKey]).trim().split('\n').map(JSON.parse);
  assert.equal(targeted[0].teams.length,1);
  assert.equal(targeted.filter(message => message.type === 'team').length,1);
  assert.equal(targeted[1].team.sport,'mlb');
  const messages = [];
  const started = performance.now();
  let buffer = '', bytes = 0, errors = '';
  const proc = spawn(backend, ['detail-stream', '--no-cache'], {env: {...env,
    OMATHLETE_FIXTURE_DELAY_SPORT: 'mlb', OMATHLETE_FIXTURE_DELAY_SECONDS: '2'}});
  proc.stderr.on('data', chunk => { errors += chunk; });
  proc.stdout.on('data', chunk => {
    bytes += chunk.length;
    buffer += chunk.toString();
    let end;
    while ((end = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      if (line) {
        const value = JSON.parse(line);
        if (value.type === 'team') {
          const persisted = JSON.parse(fs.readFileSync(path.join(cache,
            `${value.team.sport}-${value.team.teamId}.json`), 'utf8'));
          assert.equal(persisted.updatedAt, value.team.updatedAt,
            'A displayed team must already be available to watch/reminder commands');
        }
        messages.push({at: performance.now() - started, value});
      }
    }
  });
  const timeout = setTimeout(() => proc.kill(), 15000);
  const status = await new Promise((resolve, reject) => { proc.on('error', reject); proc.on('close', resolve); });
  clearTimeout(timeout);
  assert.equal(status, 0, errors);
  assert.equal(buffer, '');
  assert.equal(messages.length, 4);
  assert.equal(messages[0].value.type, 'snapshot');
  assert.ok(messages[0].value.teams.every(team => team.current && team.loading));
  assert.equal(messages[1].value.team.sport, 'nba', 'Fast second team must finish ahead of slow first team');
  assert.equal(messages[2].value.team.sport, 'mlb');
  assert.ok(messages[2].at - messages[1].at > 1000, 'Updates must arrive incrementally, not at process exit');
  assert.equal(messages[3].value.type, 'done');
  assert.ok(bytes <= 2 * 1024 * 1024);

  // Cold start displays followed-team placeholders before any requests complete.
  fs.rmSync(cache, {recursive: true});
  const cold = run(['detail-stream']).trim().split('\n').map(JSON.parse);
  assert.ok(cold[0].teams.every(team => team.loading && !team.current));
  assert.equal(cold.filter(message => message.type === 'team').length, 2);
  state([]);
  assert.deepEqual(run(['detail-stream']).trim().split('\n').map(JSON.parse),
    [{type: 'snapshot', teams: []}, {type: 'done'}]);

  // Four leagues require multiple worker slots; no more than three requests overlap.
  state(['mlb', 'nba', 'epl', 'mls']);
  const journal = path.join(tmp, 'requests.log');
  const slate = JSON.parse(run(['slate', '--no-cache'], {OMATHLETE_FIXTURE_JOURNAL: journal,
    OMATHLETE_FIXTURE_DELAY_SPORT: 'all', OMATHLETE_FIXTURE_DELAY_SECONDS: '0.3', OMATHLETE_FIXTURE_FAIL_SPORT: 'mls'}));
  let active = 0, maximum = 0, requests = 0;
  for (const line of fs.readFileSync(journal, 'utf8').trim().split('\n')) {
    const [, event] = line.split('\t');
    active += event === 'start' ? 1 : -1;
    if (event === 'start') requests++;
    maximum = Math.max(maximum, active);
    assert.ok(active >= 0 && active <= 3);
  }
  assert.equal(requests, 4);
  assert.equal(active, 0);
  assert.ok(maximum >= 2, 'League requests must overlap');
  assert.equal(slate.games.length, 6);
  assert.deepEqual(slate.failedLeagues, ['MLS']);
  assert.ok(slate.stale);

  // Maximum favorites and near-limit caches exercise completed-worker collection and
  // enforce the aggregate streaming cap, not just the size of each JSON line.
  const manyTeams = Array.from({length: 12}, (_, index) => ({sport: 'mlb', teamId: String(index + 1),
    teamName: `Team ${index}`, teamAbbrev: `T${index}`}));
  fs.writeFileSync(statePath, JSON.stringify({schemaVersion: 1, spoilersHidden: true, teams: manyTeams}));
  for (const team of manyTeams) {
    fs.writeFileSync(path.join(cache, `mlb-${team.teamId}.json`), JSON.stringify({...team,
      current: null, upcoming: null, schedule: [], stale: false, padding: 'x'.repeat(63000)}));
  }
  const largeStream = run(['detail-stream']);
  const largeMessages = largeStream.trim().split('\n').map(JSON.parse);
  assert.equal(largeMessages.length, 14);
  assert.equal(largeMessages.filter(message => message.type === 'team').length, 12);
  assert.ok(Buffer.byteLength(largeStream) > 1024 * 1024);
  assert.ok(Buffer.byteLength(largeStream) <= 2 * 1024 * 1024);
  assert.ok(largeStream.trim().split('\n').every(line => Buffer.byteLength(line) <= 1024 * 1024));
  console.log(`Omathlete loading tests passed (cached snapshot ${Math.round(messages[0].at)}ms; fast team ${Math.round(messages[1].at)}ms; slow team ${Math.round(messages[2].at)}ms; peak league requests ${maximum}).`);
} finally {
  fs.rmSync(tmp, {recursive: true, force: true});
}
