import QtQuick
import qs.Commons
import "PanelLogic.js" as Logic

Item {
  id: root
  property var rows: []
  property int range: 0
  property bool watchLater: false
  property bool quietHours: true
  property var isHidden: function(game) { return false }
  property int selectedIndex: 0
  property string selectedKey: ""
  property string revealedKey: ""
  property bool reconciling: false
  property string warning: ""
  property double now: Date.now()
  property bool helpOpen: false
  signal chooseRange(int value)
  signal chooseQueue(bool value)
  signal watchGame(var game)
  signal remindGame(var game)
  signal quietToggle()
  signal launch(var game)
  signal back()
  signal refresh()
  signal spoilersToggle()

  function selectedGame() { return rows[selectedIndex] || null }
  function ensureSelectionVisible() {
    Qt.callLater(function() {
      gameList.forceLayout()
      gameList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
      var item = gameList.currentItem
      if (!item) return
      if (item.y < gameList.contentY || item.height > gameList.height)
        gameList.contentY = item.y
      else if (item.y + item.height > gameList.contentY + gameList.height)
        gameList.contentY = item.y + item.height - gameList.height
    })
  }
  // Own the focus loop; never let Tab escape to the host's plugin switcher.
  function focusNext(backward) {
    var controls = []
    function collect(item) {
      if (!item.visible || !item.enabled) return
      if (item.activeFocusOnTab) controls.push(item)
      for (var i = 0; i < item.children.length; i++) collect(item.children[i])
    }
    collect(root)
    if (!controls.length) { root.forceActiveFocus(); return }
    var current = -1
    for (var i = 0; i < controls.length; i++) if (controls[i].activeFocus) current = i
    var next = current < 0 ? (backward ? controls.length - 1 : 0)
      : (current + (backward ? -1 : 1) + controls.length) % controls.length
    controls[next].forceActiveFocus(backward ? Qt.BacktabFocusReason : Qt.TabFocusReason)
  }
  function reveal() {
    var game = selectedGame()
    if (game) revealedKey = revealedKey === Logic.gameKey(game) ? "" : Logic.gameKey(game)
  }
  onVisibleChanged: {
    revealedKey = ""
    if (visible) Qt.callLater(function() { root.forceActiveFocus() })
  }
  onSelectedIndexChanged: {
    if (!reconciling) {
      selectedKey = Logic.gameKey(selectedGame())
      revealedKey = ""
      ensureSelectionVisible()
    }
  }
  onRowsChanged: {
    var oldY = gameList.contentY
    reconciling = true
    selectedIndex = Logic.selectedGameIndex(rows, selectedKey, selectedIndex)
    selectedKey = Logic.gameKey(selectedGame())
    if (revealedKey !== selectedKey) revealedKey = ""
    Qt.callLater(function() {
      gameList.contentY = oldY; gameList.returnToBounds()
      root.ensureSelectionVisible()
      root.reconciling = false
    })
  }
  Keys.onPressed: function(event) {
    var game = selectedGame()
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)
      root.focusNext(event.key === Qt.Key_Backtab || !!(event.modifiers & Qt.ShiftModifier))
    else if (event.key === Qt.Key_Question || event.key === Qt.Key_F1) helpOpen = !helpOpen
    else if (event.key === Qt.Key_J || event.key === Qt.Key_Down) { root.forceActiveFocus(); selectedIndex = Math.max(0, Math.min(rows.length - 1, selectedIndex + 1)) }
    else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) { root.forceActiveFocus(); selectedIndex = Math.max(0, selectedIndex - 1) }
    else if (event.key === Qt.Key_W && game) root.watchGame(game)
    else if (event.key === Qt.Key_B && game) root.remindGame(game)
    else if (event.key === Qt.Key_V) root.reveal()
    else if (event.key === Qt.Key_O && game) root.launch(game)
    else if (event.key === Qt.Key_Q) root.quietToggle()
    else if (event.key === Qt.Key_R) root.refresh()
    else if (event.key === Qt.Key_S) root.spoilersToggle()
    else if (event.key === Qt.Key_L) root.chooseQueue(!watchLater)
    else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_4) root.chooseRange(event.key - Qt.Key_1)
    else if (event.key === Qt.Key_Escape || event.key === Qt.Key_H) root.back()
    else return
    event.accepted = true
  }

  component Action: Rectangle {
    property string label: ""
    property bool active: false
    property int rowIndex: -1
    signal clicked()
    activeFocusOnTab: visible
    Accessible.role: Accessible.Button
    Accessible.name: label
    Accessible.onPressAction: clicked()
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
        root.focusNext(event.key === Qt.Key_Backtab || !!(event.modifiers & Qt.ShiftModifier))
        event.accepted = true
      }
    }
    border.width: activeFocus ? 2 : 0
    border.color: Color.foreground
    Keys.onReturnPressed: clicked()
    Keys.onEnterPressed: clicked()
    Keys.onSpacePressed: clicked()
    onActiveFocusChanged: if (activeFocus && rowIndex >= 0) {
      root.selectedIndex = rowIndex
      root.ensureSelectionVisible()
    }
    height: Math.max(Style.space(30), actionLabel.implicitHeight + Style.space(8))
    color: active ? Color.accent : Qt.rgba(1, 1, 1, 0.08)
    radius: Style.cornerRadius
    Text {
      id: actionLabel
      anchors.fill: parent
      anchors.margins: Style.space(4)
      text: parent.label
      textFormat: Text.PlainText
      color: parent.active ? Logic.contrastingInk(Color.accent) : Color.foreground
      font.pixelSize: Style.font.caption
      font.family: Style.font.family
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      wrapMode: Text.WordWrap
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: { parent.forceActiveFocus(); parent.clicked() }
    }
  }

  Column {
    id: header
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    spacing: Style.space(6)
    Text {
      text: root.watchLater ? "Watch later · protected results" : "Your sports agenda"
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
      width: parent.width
      wrapMode: Text.WordWrap
    }
    Action {
      width: parent.width
      label: root.helpOpen ? "Close shortcuts (?)" : "Keyboard shortcuts (?)"
      onClicked: root.helpOpen = !root.helpOpen
    }
    Text {
      visible: root.helpOpen
      font.family: Style.font.family
      width: parent.width
      text: "Tab/Shift+Tab: focus controls; Enter/Space: activate. j/k: games; 1–4: dates; l: agenda/queue; w: save/remove; b: reminder; v: reveal; o: ESPN; q: quiet hours; s: spoilers; r: refresh; Esc: back."
      color: Color.foreground
      wrapMode: Text.WordWrap
      font.pixelSize: Style.font.caption
    }
    Row {
      width: parent.width
      spacing: Style.space(6)
      Action { width: (parent.width - parent.spacing) / 2; label: "Agenda"; active: !root.watchLater; onClicked: root.chooseQueue(false) }
      Action { width: (parent.width - parent.spacing) / 2; label: "Watch later"; active: root.watchLater; onClicked: root.chooseQueue(true) }
    }
    Row {
      visible: !root.watchLater
      width: parent.width
      spacing: Style.space(4)
      Repeater {
        model: ["Today", "Tomorrow", "Weekend", "7 days"]
        Action {
          required property string modelData
          required property int index
          width: (header.width - Style.space(12)) / 4
          label: modelData
          active: root.range === index
          onClicked: root.chooseRange(index)
        }
      }
    }
    Action {
      width: parent.width
      label: root.quietHours ? "Quiet hours: 10 PM–8 AM · on" : "Quiet hours: off"
      onClicked: root.quietToggle()
    }
    Text {
      width: parent.width
      text: root.warning || "b: reminder Off → 15m before → At start → Off. Shell must be running."
      color: root.warning ? Color.urgent : Color.foreground
      wrapMode: Text.WordWrap
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }
  ListView {
    id: gameList
    objectName: "plannerGames"
    onHeightChanged: root.ensureSelectionVisible()
    onContentHeightChanged: root.ensureSelectionVisible()
    anchors.top: header.bottom
    anchors.topMargin: Style.space(8)
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    clip: true
    reuseItems: true
    currentIndex: root.selectedIndex
    highlightFollowsCurrentItem: false
    model: root.rows
    spacing: Style.space(6)
    section.property: "day"
    section.delegate: Text {
      required property string section
      text: section
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      padding: Style.space(4)
    }
    Text {
      anchors.top: parent.top
      width: parent.width
      visible: root.rows.length === 0
      font.family: Style.font.family
      text: root.watchLater ? "No saved games. Press w on an agenda game to protect its result."
        : "No games found for this period. Schedules may still be loading or unavailable."
      color: Color.foreground
      wrapMode: Text.WordWrap
      font.pixelSize: Style.font.body
    }
    delegate: Rectangle {
      id: card
      required property var modelData
      required property int index
      readonly property bool hiddenResult: root.isHidden(modelData) && root.revealedKey !== Logic.gameKey(modelData)
      onHeightChanged: if (index === root.selectedIndex) root.ensureSelectionVisible()
      onYChanged: if (index === root.selectedIndex) root.ensureSelectionVisible()
      width: gameList.width
      height: details.implicitHeight + Style.space(16)
      color: index === root.selectedIndex ? Qt.rgba(1,1,1,0.1) : "transparent"
      border.width: index === root.selectedIndex ? 1 : 0
      border.color: Color.accent
      radius: Style.cornerRadius
      MouseArea {
        anchors.fill: parent
        onClicked: { root.forceActiveFocus(); root.selectedIndex = card.index }
      }
      Column {
        id: details
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.space(8)
        y: Style.space(8)
        spacing: Style.space(4)
        Text {
          width: parent.width
          text: card.modelData.awayTeam + " @ " + card.modelData.homeTeam + " · " + card.modelData.sport.toUpperCase()
          textFormat: Text.PlainText
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          wrapMode: Text.Wrap
        }
        Text {
          width: parent.width
          text: new Date(card.modelData.date).toLocaleTimeString(Qt.locale(), "h:mm AP")
            + " · " + (card.modelData.broadcast || "TV not supplied")
          font.family: Style.font.family
          textFormat: Text.PlainText
          color: Color.foreground
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
        Text {
          width: parent.width
          text: card.hiddenResult ? "Result protected" : card.modelData.state === "unknown" ? "Result unavailable · open ESPN"
            : Logic.statusText(card.modelData, false)
              + (card.modelData.state !== "pre" && card.modelData.awayScore !== undefined
                ? " · " + card.modelData.awayScore + "–" + card.modelData.homeScore : "")
          font.family: Style.font.family
          textFormat: Text.PlainText
          color: Color.foreground
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
        Text {
          width: parent.width
          text: Logic.freshness(card.modelData, root.now)
          visible: text !== ""
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Logic.dataStale(card.modelData, root.now) ? Color.urgent : Color.foreground
          wrapMode: Text.WordWrap
        }
        Row {
          width: parent.width
          spacing: Style.space(4)
          Action {
            width: (parent.width - parent.spacing) / 2
            rowIndex: card.index
            label: card.modelData.saved ? "Watched / remove" : "Watch later"
            onClicked: { root.selectedIndex = card.index; root.watchGame(card.modelData) }
          }
          Action {
            width: (parent.width - parent.spacing) / 2
            rowIndex: card.index
            label: "Reminder: " + card.modelData.reminder
            onClicked: { root.selectedIndex = card.index; root.remindGame(card.modelData) }
          }
        }
        Row {
          width: parent.width
          spacing: Style.space(4)
          Action {
            width: (parent.width - parent.spacing) / 2
            rowIndex: card.index
            label: card.hiddenResult ? "Reveal this result" : "Hide result"
            visible: root.isHidden(card.modelData)
            onClicked: { root.selectedIndex = card.index; root.reveal() }
          }
          Action {
            width: (parent.width - parent.spacing) / 2
            rowIndex: card.index
            label: "Open ESPN"
            onClicked: root.launch(card.modelData)
          }
        }
      }
    }
  }
}
