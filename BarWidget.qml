import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.itsdotdev.youtube-music"

  property string title: ""
  property string artist: ""
  property string thumbnail: ""
  property bool playing: false
  property bool playerRunning: false
  property bool popupOpen: false
  property string scriptPath: Qt.resolvedUrl("bin/youtube-music").toString().replace("file://", "")
  readonly property bool hasTrack: title !== ""
  readonly property color foreground: root.bar ? root.bar.barForeground : "#f7f7f7"
  readonly property color green: "#1ed760"
  readonly property bool opened: popupOpen
  readonly property int popupX: 10
  readonly property int popupY: 38
  readonly property int popupWidth: 400
  readonly property int popupHeight: 540

  implicitWidth: hasTrack ? Style.space(154) : Style.space(30)
  implicitHeight: barSize

  function openPlayer() {
    root.toggle("{}")
  }

  function open(payloadJson) {
    popupOpen = true
    Qt.callLater(function() {
      if (popupPlayerLoader.item && popupPlayerLoader.item.open) popupPlayerLoader.item.open(payloadJson || "{}")
    })
  }

  function close() {
    if (popupPlayerLoader.item && popupPlayerLoader.item.close) popupPlayerLoader.item.close()
    popupOpen = false
  }

  function toggle(payloadJson) {
    if (root.opened) root.close()
    else root.open(payloadJson || "{}")
  }

  function runAction(action) {
    if (actionProc.running) return
    actionProc.command = ["bash", scriptPath, action]
    actionProc.running = true
  }

  function refreshStatus() {
    if (statusProc.running) return
    statusProc.command = ["bash", scriptPath, "status"]
    statusProc.running = true
  }

  function applyStatus(raw) {
    try {
      var status = JSON.parse(String(raw || "{}"))
      root.playerRunning = status.running === true
      root.playing = root.playerRunning && status.paused !== true
      root.title = String(status.title || "")
      root.artist = String(status.artist || "")
      root.thumbnail = String(status.thumbnail || "")
    } catch (error) {
      console.warn("YouTube Music bar: invalid player status", error)
    }
  }

  Rectangle {
    anchors.centerIn: parent
    width: parent.width
    height: Math.max(Style.space(24), parent.height - Style.space(8))
    radius: Style.space(6)
    color: root.hasTrack ? "#171717" : "transparent"
    border.width: root.hasTrack ? 1 : 0
    border.color: "#343434"

    Item {
      anchors.fill: parent
      visible: !root.hasTrack

      Text {
        anchors.centerIn: parent
        text: "󰗃"
        color: root.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.menuFamily
        font.pixelSize: Style.font.iconLarge
      }
      MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openPlayer() }
    }

    Row {
      anchors.fill: parent
      anchors.margins: Style.space(2)
      spacing: Style.space(3)
      visible: root.hasTrack

      Rectangle {
        width: parent.height
        height: parent.height
        radius: Style.space(4)
        color: "#2a2a2a"
        clip: true
        Image { anchors.fill: parent; source: root.thumbnail; fillMode: Image.PreserveAspectCrop; asynchronous: true }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openPlayer()
        }
      }

      Text {
        width: Style.space(52)
        anchors.verticalCenter: parent.verticalCenter
        text: root.title
        color: root.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
        MouseArea {
          anchors.fill: parent
          anchors.topMargin: -Style.space(5)
          anchors.bottomMargin: -Style.space(5)
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openPlayer()
        }
      }

      Item {
        width: Style.space(20)
        height: parent.height
        Text { anchors.centerIn: parent; text: "󰒮"; color: root.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.runAction("previous") }
      }

      Rectangle {
        width: Style.space(22)
        height: width
        radius: width / 2
        color: "transparent"
        border.width: 0
        anchors.verticalCenter: parent.verticalCenter
        Text { anchors.centerIn: parent; text: root.playing ? "󰏤" : "󰐊"; color: root.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (root.playerRunning) root.runAction("toggle")
            else root.openPlayer()
          }
        }
      }

      Item {
        width: Style.space(20)
        height: parent.height
        Text { anchors.centerIn: parent; text: "󰒭"; color: root.foreground; font.family: root.bar.fontFamily; font.pixelSize: Style.font.bodySmall }
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.runAction("next") }
      }

    }
  }

  FloatingWindow {
    id: playerWindow
    title: "YouTube Music Player"
    visible: root.popupOpen
    color: "#121212"
    implicitWidth: root.popupWidth
    implicitHeight: root.popupHeight
    minimumSize: Qt.size(implicitWidth, implicitHeight)
    maximumSize: Qt.size(implicitWidth, implicitHeight)

    onBackingWindowVisibleChanged: {
      if (!backingWindowVisible || !root.popupOpen) return
      Qt.callLater(function() {
        if (popupPlayerLoader.item && popupPlayerLoader.item.open) popupPlayerLoader.item.open("{}")
      })
    }

    onClosed: {
      if (root.popupOpen) root.close()
    }

    Loader {
      id: popupPlayerLoader
      anchors.fill: parent
      active: true
      source: Qt.resolvedUrl("Player.qml")
      onLoaded: item.closeCallback = function() { root.close() }
    }
  }

  Variants {
    model: root.popupOpen ? Quickshell.screens : []

    delegate: Component {
      PanelWindow {
        id: dismissWindow
        required property var modelData

        readonly property bool containsPlayer: playerWindow.screen
          && modelData.name === playerWindow.screen.name

        screen: modelData
        visible: root.popupOpen
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        WlrLayershell.namespace: "youtube-music-dismiss"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
          top: true
          bottom: true
          left: true
          right: true
        }

        // Keep the real player window interactive while catching every click
        // outside it. The small inset includes the compositor-owned border.
        mask: Region {
          width: dismissWindow.screen ? dismissWindow.screen.width : 0
          height: dismissWindow.screen ? dismissWindow.screen.height : 0

          Region {
            x: root.popupX - 2
            y: root.popupY - 2
            width: dismissWindow.containsPlayer ? root.popupWidth + 4 : 0
            height: dismissWindow.containsPlayer ? root.popupHeight + 4 : 0
            intersection: Intersection.Subtract
          }
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
          onPressed: root.close()
        }
      }
    }
  }

  Process {
    id: actionProc
    onExited: root.refreshStatus()
  }

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Timer {
    interval: 900
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  IpcHandler {
    target: root.moduleName

    function toggleSearch(): void {
      if (root.popupOpen && popupPlayerLoader.item)
        popupPlayerLoader.item.toggleSearch()
    }
  }
}
