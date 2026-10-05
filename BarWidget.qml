import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.chrisroundhill.omathlete"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function refresh() { if (panelLoader.item) panelLoader.item.refresh(true) }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    active: panelLoader.item ? panelLoader.item.barLive && !panelLoader.item.barDataStale : false
    fixedWidth: root.vertical ? -1 : (stateLabel.text
      ? barContent.implicitWidth + button.scaledHorizontalMargin * 2 : Style.bar.iconSlot)
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    tooltipText: panelLoader.item ? panelLoader.item.tooltipText : "Omathlete"

    Row {
      id: barContent
      anchors.centerIn: parent
      spacing: Style.space(6)

      Item {
        id: mark
        width: Style.space(18)
        height: Style.space(15)
        anchors.verticalCenter: parent.verticalCenter

        readonly property color ink: button.active && button.useActiveColor
          ? button.activeColor : button.foreground

        Text {
          anchors.centerIn: parent
          visible: !!panelLoader.item && panelLoader.item.barDataStale
          text: "!"
          color: mark.ink
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
          font.bold: true
          z: 1
        }

        Rectangle {
          anchors.fill: parent
          radius: Style.space(2)
          color: "transparent"
          border.width: 1
          border.color: mark.ink
        }
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: !panelLoader.item || !panelLoader.item.barDataStale
          y: Style.space(3)
          width: 1
          height: parent.height - Style.space(6)
          color: mark.ink
        }
        Rectangle {
          x: Style.space(4)
          visible: !panelLoader.item || !panelLoader.item.barDataStale
          y: Style.space(5)
          width: Style.space(3)
          height: Style.space(3)
          radius: width / 2
          color: mark.ink
        }
        Rectangle {
          anchors.right: parent.right
          visible: !panelLoader.item || !panelLoader.item.barDataStale
          anchors.rightMargin: Style.space(4)
          y: Style.space(5)
          width: Style.space(3)
          height: Style.space(3)
          radius: width / 2
          color: mark.ink
        }
      }

      Text {
        id: stateLabel
        visible: !root.vertical && text !== ""
        width: visible ? Math.min(implicitWidth, Style.space(126)) : 0
        anchors.verticalCenter: parent.verticalCenter
        text: panelLoader.item ? panelLoader.item.barLabel : ""
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        elide: Text.ElideRight
        renderType: Text.NativeRendering
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refresh()
      else if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }
}
