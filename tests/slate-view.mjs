// Exercise the production ListView/delegate in Qt with a small theme/host substitute.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';

const source = fs.readFileSync(new URL('../Panel.qml', import.meta.url), 'utf8');
const start = source.indexOf('ListView {\n              id: slateList');
assert.ok(start >= 0);
let depth = 0, quote = '', end = start;
for (; end < source.length; end++) {
  const c = source[end];
  if (quote) {
    if (c === '\\') end++;
    else if (c === quote) quote = '';
  } else if (c === '"' || c === "'") quote = c;
  else if (c === '{') depth++;
  else if (c === '}' && --depth === 0) { end++; break; }
}
const view = source.slice(start, end);
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'omathlete-slate-view-'));
try {
  fs.writeFileSync(path.join(tmp, 'Theme.js'), `
var font = {family: "sans-serif", caption: 12, body: 14, bodySmall: 12};
var cornerRadius = 2;
function space(value) { return value; }
function selectedFillFor() { return "#333333"; }
function selectedBorderFor() { return "#ffffff"; }
`);
  fs.writeFileSync(path.join(tmp, 'Colors.js'), 'var accent = "#ffaa44";');
  fs.copyFileSync(new URL('../PanelLogic.js', import.meta.url), path.join(tmp, 'PanelLogic.js'));
  fs.writeFileSync(path.join(tmp, 'tst_slate.qml'), `
import QtQuick
import QtTest
import "Theme.js" as Style
import "Colors.js" as Color
import "PanelLogic.js" as Logic
Item {
  id: root
  width: 380; height: 360
  property bool fullSlateOpen: true
  property bool spoilersHidden: false
  property bool restoringSlateViewport: false
  property int slateSelectedIndex: 0
  property var bar: null
  property color barForeground: "#ffffff"
  property var slateGames: []
  function cancelViewportRestore() {}
  function openSlateGame() {}
  function gameHidden(game, sport) { return spoilersHidden }
  Item { id: scoreFlick; height: root.height }
  Item { id: slateContainer; y: 0 }
  ${view}
  TestCase {
    name: "VirtualizedSlate"
    when: windowShown
    function delegates() {
      var count = 0
      for (var i = 0; i < slateList.contentItem.children.length; i++)
        if (slateList.contentItem.children[i].modelData !== undefined) count++
      return count
    }
    function test_large_slate() {
      var games = []
      for (var i = 0; i < 500; i++) games.push({id:String(i), sport:"mlb", league:"MLB",
        awayTeam:"CHC", homeTeam:"SEA", awayScore:"2", homeScore:"1", state:"in",
        detail:"Top 9th", when:"7:00 PM", broadcast:"FOX", gameUrl:""})
      root.slateGames = games
      tryCompare(slateList, "count", 500)
      wait(100)
      verify(delegates() > 0 && delegates() < 30, "Only visible/pooled rows should exist")
      slateList.positionViewAtIndex(499, ListView.Contain)
      wait(100)
      verify(slateList.itemAtIndex(499) !== null, "Last row must be reachable")
      verify(delegates() < 30, "Scrolling must not retain all 500 rows")
      root.width = 240
      wait(50)
      compare(slateList.width, 240)
      verify(slateList.itemAtIndex(499).width <= 240)
    }
  }
}
`);
  const runner = process.env.QMLTESTRUNNER || '/usr/lib/qt6/bin/qmltestrunner';
  const result = spawnSync(runner, ['-input', tmp, '-platform', 'offscreen'], {
    encoding: 'utf8', timeout: 20000, env: {...process.env, QML_DISABLE_DISK_CACHE: '1',
      QT_QUICK_BACKEND: 'software', QT_QPA_PLATFORMTHEME: ''}});
  process.stdout.write(result.stdout || '');
  if (result.stderr) process.stderr.write(result.stderr);
  assert.equal(result.status, 0, String(result.error || 'Qt slate rendering test failed'));
} finally {
  fs.rmSync(tmp, {recursive: true, force: true});
}
