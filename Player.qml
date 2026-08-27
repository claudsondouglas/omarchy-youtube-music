import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Item {
  id: root

  implicitWidth: Style.space(400)
  implicitHeight: Style.space(540)

  readonly property color ink: "#f7f7f7"
  readonly property color muted: "#a7a7a7"
  readonly property color dim: "#727272"
  readonly property color green: "#1ed760"
  readonly property color surface: "#121212"
  readonly property color raised: "#242424"

  property bool opened: false
  property bool searching: false
  property bool searchMode: false
  property bool searchExpanded: false
  property string errorMessage: ""
  property int selectedIndex: 0
  property int currentIndex: -1
  property string currentTitle: ""
  property string currentArtist: ""
  property string currentThumbnail: ""
  property string currentDuration: ""
  property bool currentIsLive: false
  property bool playing: false
  property bool playerRunning: false
  property real position: 0
  property real playbackDuration: 0
  property alias searchInput: searchField
  property var closeCallback: null
  property string scriptPath: Qt.resolvedUrl("bin/youtube-music").toString().replace("file://", "")

  function open(payloadJson) {
    opened = true
    errorMessage = ""
    searchExpanded = searchMode || searchField.text.trim() !== ""
    refreshStatus()
  }

  function close() {
    searchField.focus = false
    searchExpanded = false
    opened = false
  }
  function requestClose() {
    if (closeCallback) closeCallback()
    else close()
  }
  function toggle(payloadJson) { opened ? close() : open(payloadJson) }

  function formatTime(seconds) {
    var value = Math.max(0, Math.floor(Number(seconds) || 0))
    var hours = Math.floor(value / 3600)
    var minutes = Math.floor((value % 3600) / 60)
    var remainingSeconds = value % 60
    if (hours > 0)
      return hours + ":" + String(minutes).padStart(2, "0") + ":" + String(remainingSeconds).padStart(2, "0")
    return minutes + ":" + String(remainingSeconds).padStart(2, "0")
  }

  function isVideoId(value) {
    return /^[A-Za-z0-9_-]{11}$/.test(String(value || ""))
  }

  function durationLabel(duration, isLive) {
    var value = String(duration || "").trim()
    if (isLive || value.toUpperCase() === "NA" || value.toUpperCase() === "N/A") return "LIVE"
    return value || "--:--"
  }

  function expandSearch() {
    searchExpanded = true
    Qt.callLater(function() {
      searchField.forceActiveFocus()
      focusTimer.restart()
    })
  }

  function collapseSearch() {
    searchField.focus = false
    searchExpanded = false
    root.forceActiveFocus()
    Qt.callLater(function() { root.forceActiveFocus() })
  }

  function toggleSearch() {
    if (!opened) return false
    if (searchExpanded) collapseSearch()
    else expandSearch()
    return true
  }

  function search() {
    var query = searchField.text.trim()
    if (!query) return
    if (searchProc.running) {
      searchProc.pendingQuery = query
      return
    }
    startSearch(query)
  }

  function startSearch(query) {
    searchDebounce.stop()
    searchProc.activeQuery = query
    searchProc.pendingQuery = ""
    searchMode = true
    searching = true
    errorMessage = ""
    results.clear()
    selectedIndex = 0
    searchProc.command = ["bash", scriptPath, "search", query]
    searchProc.running = true
  }

  function queueJson() {
    var queue = []
    for (var i = 0; i < results.count; i++) {
      var row = results.get(i)
      queue.push({
        videoId: row.videoId,
        title: row.title,
        artist: row.artist,
        thumbnail: row.thumbnail,
        duration: row.duration,
        isLive: row.isLive
      })
    }
    return JSON.stringify(queue)
  }

  function playAt(index) {
    if (index < 0 || index >= results.count) return
    var track = results.get(index)
    currentIndex = index
    currentTitle = track.title
    currentArtist = track.artist
    currentThumbnail = track.thumbnail
    currentDuration = track.duration
    currentIsLive = track.isLive === true
    position = 0
    playbackDuration = 0
    playing = true
    playerRunning = true
    searchDebounce.stop()
    searchMode = false
    collapseSearch()
    actionProc.command = ["bash", scriptPath, "queue", queueJson(), String(index)]
    actionProc.running = true
  }

  function runAction(action) {
    if (actionProc.running) return
    actionProc.command = ["bash", scriptPath, action]
    actionProc.running = true
  }

  function next() { runAction("next") }
  function previous() { runAction("previous") }

  function togglePlayback() {
    if (!playerRunning && results.count > 0) {
      playAt(Math.max(0, selectedIndex))
      return
    }
    runAction("toggle")
    playing = !playing
  }

  function refreshStatus() {
    if (statusProc.running) return
    statusProc.command = ["bash", scriptPath, "status"]
    statusProc.running = true
  }

  function applyStatus(raw) {
    try {
      var status = JSON.parse(String(raw || "{}"))
      playerRunning = status.running === true
      playing = playerRunning && status.paused !== true
      position = Number(status.position) || 0
      playbackDuration = Number(status.playbackDuration) || 0
      if (status.title) currentTitle = String(status.title)
      if (status.artist) currentArtist = String(status.artist)
      if (status.thumbnail) currentThumbnail = String(status.thumbnail)
      if (status.duration) currentDuration = String(status.duration)
      if (status.isLive !== undefined) currentIsLive = status.isLive === true
      else if (String(status.duration || "").toUpperCase() === "NA") currentIsLive = true
      if (status.index !== undefined) currentIndex = Number(status.index)
      if (status.queue && status.queue.length > 0 && results.count === 0 && !searching && !searchMode) {
        for (var i = 0; i < status.queue.length; i++) {
          var row = status.queue[i]
          var videoId = String(row.videoId || "")
          if (!root.isVideoId(videoId)) continue
          var duration = String(row.duration || "")
          results.append({
            videoId: videoId,
            title: String(row.title || "Untitled"),
            artist: String(row.artist || "YouTube"),
            duration: duration,
            isLive: row.isLive === true || duration.toUpperCase() === "NA",
            thumbnail: String(row.thumbnail || "")
          })
        }
      }
    } catch (error) {
      console.warn("YouTube Music: invalid player status", error)
    }
  }

  ListModel { id: results }

  Process {
    id: searchProc
    property string collected: ""
    property string activeQuery: ""
    property string pendingQuery: ""
    stdout: SplitParser { onRead: function(line) { searchProc.collected += line + "\n" } }
    stderr: StdioCollector { id: searchError; waitForEnd: true }
    onStarted: collected = ""
    onExited: function(code) {
      var currentQuery = searchField.text.trim()
      if (pendingQuery && pendingQuery !== activeQuery) {
        root.startSearch(pendingQuery)
        return
      }
      if (!currentQuery || currentQuery !== activeQuery) {
        searching = false
        searchMode = currentQuery !== ""
        results.clear()
        if (currentQuery) root.startSearch(currentQuery)
        else root.refreshStatus()
        return
      }
      searching = false
      var lines = collected.trim().split("\n")
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i]) continue
        var fields = lines[i].split("\t")
        if (fields.length < 2) continue
        var videoId = fields[0]
        if (!root.isVideoId(videoId)) continue
        var duration = fields[3] || ""
        var isLive = fields[5] === "is_live" || duration.toUpperCase() === "NA"
        results.append({
          videoId: videoId,
          title: fields[1] || "Untitled",
          artist: fields[2] || "YouTube",
          duration: duration,
          isLive: isLive,
          thumbnail: (!fields[4] || fields[4] === "NA")
            ? "https://i.ytimg.com/vi/" + videoId + "/hqdefault.jpg"
            : fields[4]
        })
        if (results.count >= 10) break
      }
      if (code !== 0) errorMessage = searchError.text.trim() || "Search failed"
      else if (results.count === 0) errorMessage = "No tracks found"
      else if (!playerRunning) resultList.forceActiveFocus()
    }
  }

  Process {
    id: actionProc
    onExited: refreshStatus()
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
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  Timer {
    id: focusTimer
    interval: 90
    repeat: false
    onTriggered: searchField.forceActiveFocus()
  }

  Timer {
    id: searchDebounce
    interval: 550
    repeat: false
    onTriggered: root.search()
  }

  Rectangle {
      id: card
      anchors.fill: parent
      color: root.surface
      clip: true

      Image {
        anchors.fill: parent
        source: root.currentThumbnail
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        opacity: root.currentThumbnail ? 0.04 : 0
      }
      Rectangle { anchors.fill: parent; color: "#d6121212" }
      MouseArea { anchors.fill: parent; onClicked: root.collapseSearch() }

      Item {
        anchors.fill: parent
        anchors.margins: Style.space(16)

        Column {
          anchors.fill: parent
          spacing: Style.space(7)

          Item {
            id: header
            width: parent.width
            height: Style.space(36)

            Text {
              text: "YouTube Music"
              color: root.ink
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              anchors.left: parent.left
              anchors.right: searchBox.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
            }

            Rectangle {
              id: searchBox
              property real collapsedWidth: Style.space(32)
              property real expandedWidth: Math.min(parent.width - Style.space(112), Style.space(252))

              width: collapsedWidth
              height: Style.space(32)
              radius: height / 2
              color: root.searchExpanded ? root.raised : (searchHitArea.containsMouse ? "#242424" : "transparent")
              border.width: root.searchExpanded && searchField.activeFocus ? 1 : 0
              border.color: root.ink
              clip: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              state: root.searchExpanded ? "expanded" : "collapsed"

              states: [
                State {
                  name: "collapsed"
                  PropertyChanges { target: searchBox; width: searchBox.collapsedWidth }
                },
                State {
                  name: "expanded"
                  PropertyChanges { target: searchBox; width: searchBox.expandedWidth }
                }
              ]

              transitions: [
                Transition {
                  from: "collapsed"
                  to: "expanded"
                  NumberAnimation {
                    target: searchBox
                    property: "width"
                    duration: 145
                    easing.type: Easing.OutExpo
                  }
                },
                Transition {
                  from: "expanded"
                  to: "collapsed"
                  NumberAnimation {
                    target: searchBox
                    property: "width"
                    duration: 110
                    easing.type: Easing.OutCubic
                  }
                }
              ]

              Behavior on color {
                ColorAnimation { duration: 120 }
              }

              TextInput {
                id: searchField
                anchors.left: parent.left
                anchors.leftMargin: Style.space(13)
                anchors.right: searchIcon.left
                anchors.rightMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                color: root.ink
                selectionColor: root.green
                selectedTextColor: "#08150c"
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.bodySmall
                clip: true
                enabled: root.searchExpanded
                opacity: root.searchExpanded ? 1 : 0

                Behavior on opacity {
                  NumberAnimation { duration: 120 }
                }

                onTextChanged: {
                  var query = text.trim()
                  if (!root.opened) return
                  if (!query) {
                    searchDebounce.stop()
                    searchProc.pendingQuery = ""
                    root.searchMode = false
                    root.errorMessage = ""
                    if (!searchProc.running) {
                      results.clear()
                      root.refreshStatus()
                    }
                  } else if (query.length >= 2) {
                    searchDebounce.restart()
                  }
                }

                Text {
                  text: "Search music…"
                  color: root.muted
                  font: searchField.font
                  visible: root.searchExpanded && !searchField.text
                }

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) { root.requestClose(); event.accepted = true }
                  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { searchDebounce.stop(); root.search(); event.accepted = true }
                  else if (event.key === Qt.Key_Down && results.count > 0) { root.selectedIndex = Math.min(results.count - 1, root.selectedIndex + 1); resultList.forceActiveFocus(); event.accepted = true }
                }
              }

              Text {
                id: searchIcon
                width: Style.space(32)
                height: parent.height
                text: "󰍉"
                color: root.searchExpanded ? root.ink : root.muted
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.iconLarge
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                anchors.right: parent.right

                MouseArea {
                  id: searchHitArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (!root.searchExpanded) root.expandSearch()
                    else {
                      searchField.forceActiveFocus()
                      if (searchField.text.trim()) root.search()
                    }
                  }
                }
              }
            }
          }

          Item {
            id: playerArea
            width: parent.width
            height: parent.height - header.height - parent.spacing

            Column {
              id: nowPlaying
              anchors.fill: parent
              visible: root.currentTitle !== "" && !root.searchMode
              spacing: Style.space(7)

              Item {
                width: parent.width
                height: Math.min(Style.space(220), Math.max(Style.space(180), playerArea.height * 0.42))

                Rectangle {
                  width: parent.height
                  height: parent.height
                  anchors.horizontalCenter: parent.horizontalCenter
                  radius: Style.space(9)
                  color: "#292929"
                  clip: true
                  Image {
                    anchors.fill: parent
                    source: root.currentThumbnail
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                  }
                }
              }

              Item {
                width: parent.width
                height: Style.space(42)

                Column {
                  width: parent.width
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)
                  Text { width: parent.width; text: root.currentTitle; color: root.ink; font.family: Style.font.menuFamily; font.pixelSize: Style.font.title; font.bold: true; elide: Text.ElideRight }
                  Text { width: parent.width; text: root.currentArtist; color: root.muted; font.family: Style.font.menuFamily; font.pixelSize: Style.font.bodySmall; elide: Text.ElideRight }
                }
              }

              Row {
                id: timeRow
                width: parent.width
                height: Style.space(14)
                spacing: Style.space(7)
                readonly property bool showsHours: root.position >= 3600 || root.playbackDuration >= 3600
                readonly property int labelWidth: showsHours ? Style.space(58) : Style.space(34)
                Text { width: timeRow.labelWidth; text: root.formatTime(root.position); color: root.muted; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
                Rectangle {
                  width: Math.max(Style.space(40), parent.width - timeRow.labelWidth * 2 - timeRow.spacing * 2)
                  height: Style.space(3)
                  radius: height / 2
                  color: "#555555"
                  anchors.verticalCenter: parent.verticalCenter
                  Rectangle {
                    width: parent.width * Math.min(1, root.position / Math.max(1, root.playbackDuration))
                    height: parent.height
                    radius: height / 2
                    color: root.green
                  }
                }
                Text { width: timeRow.labelWidth; horizontalAlignment: Text.AlignRight; text: root.playbackDuration > 0 ? root.formatTime(root.playbackDuration) : root.durationLabel(root.currentDuration, root.currentIsLive); color: root.muted; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption; anchors.verticalCenter: parent.verticalCenter }
              }

              Item {
                width: parent.width
                height: Style.space(46)

                Row {
                  anchors.centerIn: parent
                  spacing: Style.space(22)
                  Text {
                    text: "󰒮"; color: root.ink; font.family: Style.font.menuFamily; font.pixelSize: Style.font.iconLarge; anchors.verticalCenter: parent.verticalCenter
                    MouseArea { anchors.fill: parent; anchors.margins: -Style.space(8); cursorShape: Qt.PointingHandCursor; onClicked: { root.collapseSearch(); root.previous() } }
                  }
                  Rectangle {
                    width: Style.space(42); height: width; radius: width / 2; color: "transparent"; border.width: 1; border.color: root.green; anchors.verticalCenter: parent.verticalCenter
                    Text { anchors.centerIn: parent; text: root.playing ? "󰏤" : "󰐊"; color: root.ink; font.family: Style.font.menuFamily; font.pixelSize: Style.font.iconLarge }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.collapseSearch(); root.togglePlayback() } }
                  }
                  Text {
                    text: "󰒭"; color: root.ink; font.family: Style.font.menuFamily; font.pixelSize: Style.font.iconLarge; anchors.verticalCenter: parent.verticalCenter
                    MouseArea { anchors.fill: parent; anchors.margins: -Style.space(8); cursorShape: Qt.PointingHandCursor; onClicked: { root.collapseSearch(); root.next() } }
                  }
                }
              }

              Rectangle { width: parent.width; height: 1; color: "#343434" }
              Text { text: "Up next"; color: root.ink; font.family: Style.font.menuFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }

              ListView {
                id: upNextList
                width: parent.width
                height: parent.height - y
                model: results
                clip: true
                spacing: Style.space(2)
                delegate: TrackRow { }
              }
            }

            Item {
              anchors.fill: parent
              visible: root.currentTitle === "" || root.searchMode

              Text {
                anchors.centerIn: parent
                visible: root.searching || (results.count === 0 && root.errorMessage === "")
                text: root.searching ? "Searching YouTube…" : "Search for something worth hearing"
                color: root.muted
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
              }

              Text {
                anchors.centerIn: parent
                visible: root.errorMessage !== ""
                text: root.errorMessage
                color: "#ff7a7a"
                font.family: Style.font.menuFamily
                font.pixelSize: Style.font.body
              }

              ListView {
                id: resultList
                anchors.fill: parent
                model: results
                clip: true
                spacing: Style.space(3)
                visible: results.count > 0
                currentIndex: root.selectedIndex
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) { root.requestClose(); event.accepted = true }
                  else if (event.key === Qt.Key_Up) { if (root.selectedIndex === 0) searchField.forceActiveFocus(); else root.selectedIndex--; event.accepted = true }
                  else if (event.key === Qt.Key_Down) { root.selectedIndex = Math.min(results.count - 1, root.selectedIndex + 1); event.accepted = true }
                  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.playAt(root.selectedIndex); event.accepted = true }
                }
                delegate: TrackRow { expanded: true }
              }
            }
          }
        }
      }
  }

  component TrackRow: Rectangle {
    id: trackRow
    required property int index
    required property string title
    required property string artist
    required property string duration
    required property bool isLive
    required property string thumbnail
    property bool expanded: false
    width: ListView.view ? ListView.view.width : 0
    height: (!expanded && index === root.currentIndex) ? 0 : (expanded ? Style.space(50) : Style.space(38))
    visible: height > 0
    radius: Style.space(7)
    color: index === root.selectedIndex ? "#292929" : (trackArea.containsMouse ? "#222222" : "transparent")

    Row {
      anchors.fill: parent
      anchors.leftMargin: Style.space(4)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(7)

      Rectangle {
        width: expanded ? Style.space(40) : Style.space(30)
        height: width
        radius: Style.space(5)
        color: "#292929"
        clip: true
        anchors.verticalCenter: parent.verticalCenter
        Image { anchors.fill: parent; source: trackRow.thumbnail; fillMode: Image.PreserveAspectCrop; asynchronous: true }
      }

      Column {
        width: parent.width - (expanded ? Style.space(91) : Style.space(81))
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Text { width: parent.width; text: trackRow.title; color: trackRow.index === root.currentIndex ? root.green : root.ink; font.family: Style.font.menuFamily; font.pixelSize: Style.font.bodySmall; font.bold: trackRow.index === root.currentIndex; elide: Text.ElideRight }
        Text { width: parent.width; text: trackRow.artist; color: root.muted; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
      }

      Text { width: Style.space(38); text: root.durationLabel(trackRow.duration, trackRow.isLive); color: trackRow.isLive ? root.green : root.muted; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption; horizontalAlignment: Text.AlignRight; anchors.verticalCenter: parent.verticalCenter }
    }

    MouseArea {
      id: trackArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: { root.collapseSearch(); root.selectedIndex = trackRow.index; root.playAt(trackRow.index) }
    }
  }
}
