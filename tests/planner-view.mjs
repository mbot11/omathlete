import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
const tmp = fs.mkdtempSync(path.join(os.tmpdir(),'omathlete-planner-view-'));
try {
  const source = fs.readFileSync(new URL('../PlannerView.qml',import.meta.url),'utf8');
  fs.writeFileSync(path.join(tmp,'PlannerView.qml'),source.replace('import qs.Commons',
    'import "Theme.js" as Style\nimport "Colors.js" as Color'));
  fs.copyFileSync(new URL('../PanelLogic.js',import.meta.url),path.join(tmp,'PanelLogic.js'));
  fs.writeFileSync(path.join(tmp,'Theme.js'),'var font={family:"sans-serif",caption:12,body:14,subtitle:16}; var cornerRadius=2; function space(n){return n;}');
  fs.writeFileSync(path.join(tmp,'Colors.js'),'var foreground="#ffffff"; var background="#101010"; var accent=Qt.rgba(1,0.667,0.267,1); var urgent="#ff8888";');
  fs.writeFileSync(path.join(tmp,'tst_planner.qml'),`
import QtQuick
import QtTest
Item {
  id: host
  width:240; height:560
  property int pluginSwitches: 0
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_G) { p.visible = true; event.accepted = true }
    else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      pluginSwitches++; event.accepted = true
    }
  }
  Item { id: otherPlugin; activeFocusOnTab: true }
  PlannerView {
    id:p
    visible:false
    anchors.fill:parent
    isHidden:function(game){ return true }
    rows:[{id:"1",sport:"mlb",homeTeam:"CHC",awayTeam:"SEA",homeScore:"99",awayScore:"88",
      state:"post",detail:"Final",date:"2026-09-05T18:00:00Z",day:"Sat · Sep 5",broadcast:"FOX",saved:true,reminder:"Off"},
      {id:"2",sport:"mlb",homeTeam:"NYY",awayTeam:"BOS",state:"pre",date:"2026-09-05T19:00:00Z",
      day:"Sat · Sep 5",broadcast:"",saved:false,reminder:"15m before"}]
  }
  SignalSpy {id:watchSpy; target:p; signalName:"watchGame"}
  SignalSpy {id:reminderSpy; target:p; signalName:"remindGame"}
  SignalSpy {id:backSpy; target:p; signalName:"back"}
  TestCase {
    name:"PlannerKeyboardAndSpoilers"
    when:windowShown
    function texts(item) {
      var text = item.text === undefined ? "" : String(item.text)
      for(var i=0;i<item.children.length;i++) text += " " + texts(item.children[i])
      return text
    }
    function test_planner() {
      host.forceActiveFocus()
      keyClick(Qt.Key_G)
      wait(100)
      verify(p.activeFocus,"Opening with g transfers focus to the planner")
      for(var n=0;n<40;n++) {
        keyClick(Qt.Key_Tab)
        verify(!otherPlugin.activeFocus,"Tab must not leave the planner")
      }
      for(var n=0;n<40;n++) {
        keyClick(Qt.Key_Backtab,Qt.ShiftModifier)
        verify(!otherPlugin.activeFocus,"Shift+Tab must not leave the planner")
      }
      compare(host.pluginSwitches,0,"Host plugin switching must not receive planner Tab")
      p.forceActiveFocus()
      p.selectedIndex = 0
      verify(texts(p).indexOf("88–99") < 0,"Hidden scores must not appear in delegate text")
      keyClick(Qt.Key_V)
      wait(30)
      verify(texts(p).indexOf("88–99") >= 0,"Explicit reveal should show selected result")
      keyClick(Qt.Key_J)
      wait(30)
      compare(p.selectedIndex,1)
      verify(texts(p).indexOf("88–99") < 0,"Moving selection must clear reveal")
      keyClick(Qt.Key_W)
      compare(watchSpy.count,1)
      compare(watchSpy.signalArguments[0][0].id,"2")
      keyClick(Qt.Key_B)
      compare(reminderSpy.count,1)
      keyClick(Qt.Key_Escape)
      compare(backSpy.count,1)
      compare(p.width,240)
      keyClick(Qt.Key_Question)
      compare(p.helpOpen,true)
      keyClick(Qt.Key_Question)
      compare(p.helpOpen,false)
      keyClick(Qt.Key_Tab)
      keyClick(Qt.Key_Return)
      compare(p.helpOpen,true,"Tab reaches an actionable button")
      p.helpOpen = false
      var many = []
      for(var n=0;n<32;n++) many.push({id:String(n),sport:"mlb",
        homeTeam:"A very long university team name",awayTeam:"Another very long team name",
        date:"2026-09-05T19:00:00Z",day:"Sat · Sep 5",state:"post",detail:"Final 88-99",
        homeScore:"99",awayScore:"88",broadcast:"A long broadcast network name",saved:true,reminder:"Off"})
      p.rows = many
      wait(50)
      p.forceActiveFocus()
      for(var n=0;n<35;n++) keyClick(Qt.Key_J)
      wait(50)
      compare(p.selectedIndex,31)
      var list = findChild(p,"plannerGames")
      verify(list.contentY > 0,"Keyboard selection scrolls long queues")
      verify(list.currentItem.y >= list.contentY - 1)
      // Font metrics vary across Qt versions. A wrapped card can be taller
      // than the viewport; in that case its top must remain reachable.
      tryVerify(function() {
        return list.currentItem.y + Math.min(list.currentItem.height,list.height)
          <= list.contentY + list.height + 1
      }, 2000, "Selected card geometry: y=" + list.currentItem.y + ", h=" + list.currentItem.height
        + ", scroll=" + list.contentY + ", viewport=" + list.height + ", top=" + list.y)
      verify(texts(p).indexOf("88–99") < 0)
      verify(texts(p).indexOf("Final 88-99") < 0)
      for(var n=0;n<35;n++) keyClick(Qt.Key_K)
      compare(p.selectedIndex,0)
      // Removing another row preserves identity; removing the selected row
      // selects its next neighbor, then the previous neighbor at the end.
      p.watchLater = true
      p.rows = many.slice(0,4)
      wait(30)
      p.selectedIndex = 2
      p.rows = many.slice(1,4)
      wait(30)
      compare(p.selectedGame().id,"2")
      compare(p.selectedIndex,1)
      p.reveal()
      p.rows = [many[1],many[3]]
      wait(30)
      compare(p.selectedGame().id,"3")
      compare(p.revealedKey,"")
      p.rows = [many[1]]
      wait(30)
      compare(p.selectedGame().id,"1")
      compare(p.selectedIndex,0)
      p.rows = []
      wait(30)
      keyClick(Qt.Key_J)
      compare(p.selectedIndex,0,"Empty list selection never becomes negative")
    }
  }
}
`);
  const result = spawnSync(process.env.QMLTESTRUNNER || '/usr/lib/qt6/bin/qmltestrunner',
    ['-input',tmp,'-platform','offscreen'],{encoding:'utf8',timeout:20000,
      env:{...process.env,QT_QUICK_BACKEND:'software',QT_QPA_PLATFORMTHEME:'',QML_DISABLE_DISK_CACHE:'1'}});
  process.stdout.write(result.stdout || '');
  if(result.stderr) process.stderr.write(result.stderr);
  assert.equal(result.status,0,String(result.error || 'Planner Qt test failed'));
} finally { fs.rmSync(tmp,{recursive:true,force:true}); }
