import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'omathlete-bar-'));
try {
  const source = fs.readFileSync(new URL('../BarWidget.qml', import.meta.url), 'utf8');
  fs.writeFileSync(path.join(tmp,'SportsBar.qml'), source.replace('import qs.Commons',
    'import "Theme.js" as Style').replace('import qs.Ui','').replace('\nBarWidget {','\nHostWidget {'));
  fs.writeFileSync(path.join(tmp,'Theme.js'), 'var bar={iconSlot:30}; function space(n){return n;}');
  fs.writeFileSync(path.join(tmp,'HostWidget.qml'), `import QtQuick
Item { property var bar: null; property string moduleName: ""; readonly property bool vertical: bar ? bar.vertical : false }`);
  fs.writeFileSync(path.join(tmp,'WidgetButton.qml'), `import QtQuick
Item {
  property var bar: null
  property bool labelVisible: false
  property bool hasVisualContent: true
  property bool active: false
  property bool useActiveColor: true
  property color activeColor: "orange"
  property color foreground: "white"
  property real scaledHorizontalMargin: 8.5
  property string fontFamily: "monospace"
  property real fontSize: bar ? bar.fontSize : 14
  property real fixedWidth: -1
  property real fixedHeight: -1
  property string tooltipText: ""
  signal pressed(int buttonCode)
  implicitWidth: fixedWidth > 0 ? fixedWidth : 30
  implicitHeight: fixedHeight > 0 ? fixedHeight : 30
}`);
  fs.writeFileSync(path.join(tmp,'Panel.qml'), `import QtQuick
Item {
  property var bar: null
  property var anchorItem: null
  property var hostWidget: null
  property bool opened: false
  property bool barLive: false
  property bool barDataStale: false
  property string tooltipText: "test"
  readonly property string barLabel: bar ? bar.label : ""
}`);
  fs.writeFileSync(path.join(tmp,'tst_bar.qml'), `import QtQuick
import QtTest
Item {
  width: 500; height: 100
  QtObject { id: host; property string label: "CHC · 9h"; property bool vertical: false; property real fontSize: 14 }
  SportsBar { id: widget; bar: host; width: implicitWidth; height: implicitHeight }
  TestCase {
    name: "BarSizing"; when: windowShown
    function test_width() {
      wait(80)
      var compact = widget.implicitWidth
      verify(compact > 30 && compact < 167, "Short text must not reserve the maximum slot")
      host.label = "Cached · CHC 3–8 · Top 7th"
      wait(30)
      verify(widget.implicitWidth > compact)
      verify(widget.implicitWidth <= 167, "Long labels remain capped")
      host.fontSize = 24
      wait(30)
      verify(widget.implicitWidth <= 167, "Large theme fonts remain bounded")
      host.vertical = true
      wait(30)
      compare(widget.implicitWidth,30)
      host.vertical = false
      host.label = ""
      wait(30)
      compare(widget.implicitWidth,30)
    }
  }
}`);
  const result = spawnSync(process.env.QMLTESTRUNNER || '/usr/lib/qt6/bin/qmltestrunner',
    ['-input',tmp,'-platform','offscreen'], {encoding:'utf8',timeout:20000,
      env:{...process.env,QT_QUICK_BACKEND:'software',QT_QPA_PLATFORMTHEME:'',QML_DISABLE_DISK_CACHE:'1'}});
  process.stdout.write(result.stdout || '');
  process.stderr.write(result.stderr || '');
  assert.equal(result.status,0,String(result.error || 'Bar sizing failed'));
} finally { fs.rmSync(tmp,{recursive:true,force:true}); }
