import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.Commons
import qs.Ui

Item {
  id: root

  implicitWidth: Style.space(400)
  implicitHeight: Style.space(540)

  readonly property color ink: "#f7f7f7"
  readonly property color muted: "#a7a7a7"
  readonly property color dim: "#727272"
  // The theme accent (theme/colors.toml -> accent) instead of a fixed Spotify
  // green, so changing the Omarchy theme repaints the player along with the
  // rest of the shell.
  readonly property color accent: Color.accent
  // Text drawn on top of the accent (the search selection). The accent can be
  // light or dark depending on the theme, so the contrast colour is derived
  // from its luminance rather than fixed -- fixing it would put white text on
  // a light accent.
  readonly property color onAccent: (0.299 * accent.r + 0.587 * accent.g + 0.114 * accent.b) > 0.6 ? "#101010" : "#ffffff"
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
  property string currentVideoId: ""
  property bool mixLoading: false
  property bool mixPrefetching: false
  property bool currentIsLive: false
  property bool playing: false
  property bool playerRunning: false
  property real position: 0
  property real playbackDuration: 0
  // 0-100, mirrored from mpv and persisted by the script so it survives the
  // next track. `scrubbing` holds the status poll off the progress bar while a
  // drag is in flight.
  property int volume: 70
  property bool scrubbing: false
  property alias searchInput: searchField
  property var closeCallback: null
  property string scriptPath: Qt.resolvedUrl("bin/youtube-music").toString().replace("file://", "")

  // The playlist store as read back from `bin/youtube-music playlists`. A plain
  // array so the lists below can bind straight to it and repaint the moment a
  // track is saved.
  property var playlists: []
  property var playlistQueue: []
  property bool homeMode: false
  property string openPlaylistId: ""
  property bool playlistPickerOpen: false
  property bool homeCreating: false
  property bool pickerCreating: false

  // Which of the three panels fills the body. Home wins whenever nothing is
  // playing: an empty player showing only "search for something" was a dead
  // end, and the saved playlists are the one thing worth offering there.
  readonly property bool showSearch: searchMode
  readonly property bool showHome: !searchMode && (homeMode || currentTitle === "")
  readonly property bool showPlayer: !showSearch && !showHome

  readonly property bool currentLiked: playlistHas(playlistById("liked"), currentVideoId)
  // Drives the bookmark glyph: filled once the track sits in any playlist other
  // than "Liked songs", which has its own button.
  readonly property bool currentSaved: {
    for (var i = 0; i < playlists.length; i++)
      if (playlists[i].id !== "liked" && playlistHas(playlists[i], currentVideoId)) return true
    return false
  }
  readonly property bool libraryEmpty: {
    for (var i = 0; i < playlists.length; i++)
      if (playlists[i].tracks && playlists[i].tracks.length > 0) return false
    return true
  }

  focus: true
  // Only keys the focused item left unhandled reach this far, which is what
  // keeps the transport shortcuts out of the text fields: a TextInput consumes
  // space and the horizontal arrows itself.
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Escape) {
      // Escape peels one layer at a time instead of closing the window
      // outright: dismissing the picker or stepping out of a playlist is what
      // the user means far more often than "close the player".
      if (playlistPickerOpen) closePicker()
      else if (openPlaylistId !== "") openPlaylistId = ""
      else requestClose()
      event.accepted = true
      return
    }
    if (playlistPickerOpen) return
    if (event.key === Qt.Key_Space) {
      togglePlayback()
      event.accepted = true
    } else if (event.key === Qt.Key_Left) {
      nudge(-5)
      event.accepted = true
    } else if (event.key === Qt.Key_Right) {
      nudge(5)
      event.accepted = true
    }
  }

  function open(payloadJson) {
    opened = true
    errorMessage = ""
    searchExpanded = searchMode || searchField.text.trim() !== ""
    refreshStatus()
    loadPlaylists()
  }

  function close() {
    searchField.focus = false
    searchExpanded = false
    closePicker()
    opened = false
  }
  function requestClose() {
    if (closeCallback) closeCallback()
    else close()
  }
  function toggle(payloadJson) { opened ? close() : open(payloadJson) }

  // YouTube's hqdefault/sddefault thumbnails are a 4:3 canvas with black bars
  // above and below the 16:9 frame. A square crop mostly hides them; the
  // spinning disc does not -- the bars sweep past as two dark wedges. The mq
  // variant is the same frame with no bars.
  function discArt(url) {
    return String(url || "").replace(/\/(hq|sd)?default\.jpg/, "/mqdefault.jpg")
  }

  // YouTube titles arrive as "DUPE - Creep (Cangaco Sessions Vol. 2 - Deluxe
  // Edition)" while the artist line right underneath repeats "DUPE". Inside a
  // mix, where every row shares one artist, that prefix is the first thing on
  // every row and the song name is exactly what falls off the end -- six rows
  // that read the same for their first eight characters. Both the prefix and
  // the version tail come off the strong text and are shown, demoted, where
  // they carry their weight.
  function trackParts(title, artist) {
    var name = String(title || "")
    // "Artist - Topic" is how YouTube names the auto-generated channel; the
    // prefix in the title is the bare artist.
    var lead = String(artist || "").replace(/\s*-\s*Topic\s*$/i, "").trim()
    if (lead !== "" && name.slice(0, lead.length).toLowerCase() === lead.toLowerCase()) {
      // Only when a separator follows, so a song whose name simply opens with
      // the artist's name ("Radiohead Forever") is never cut mid-sentence.
      var rest = name.slice(lead.length).match(/^\s*[-\u2013\u2014:|\u00b7]\s*(\S.*)$/)
      if (rest) name = rest[1]
    }
    // Everything from the first bracket on is the tail: "(Cangaco Sessions
    // Vol. 2 - Deluxe Edition)", "(Official Video) ft. Kendrick Lamar". Kept
    // rather than dropped -- two versions of one song in the same mix are told
    // apart by precisely this -- but demoted. The brackets themselves go: what
    // is left is already visibly a subtitle, and a stray ")" from a mid-title
    // group would be the only thing they added.
    var tail = ""
    var split = name.match(/^(.*?\S)\s*[\(\[](.*)$/)
    if (split) {
      name = split[1]
      tail = split[2].replace(/[\(\)\[\]]/g, " ").replace(/\s+/g, " ").trim()
    }
    return { name: name, tail: tail }
  }

  // StyledText markup for a one-line row: the song in the row's own colour and
  // the version tail behind it in `tailColor`.
  function trackMarkup(title, artist, tailColor) {
    var parts = trackParts(title, artist)
    var markup = escapeMarkup(parts.name)
    if (parts.tail !== "")
      markup += " <font color=\"" + tailColor + "\">" + escapeMarkup(parts.tail) + "</font>"
    return markup
  }

  function escapeMarkup(value) {
    return String(value || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

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

  // `mix` returns exactly the same TSV as `search`, so all three paths (search,
  // the mix button and the automatic mix) share this parser. It returns an array
  // instead of touching `results` directly because the automatic mix has to
  // inspect the list BEFORE replacing the queue that is on screen -- an empty
  // mix must not wipe anything out.
  function parseTracks(raw, limit) {
    var out = []
    var lines = String(raw || "").trim().split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i]) continue
      var fields = lines[i].split("\t")
      if (fields.length < 2) continue
      var videoId = fields[0]
      if (!isVideoId(videoId)) continue
      var duration = fields[3] || ""
      out.push({
        videoId: videoId,
        title: fields[1] || "Untitled",
        artist: fields[2] || "YouTube",
        duration: duration,
        isLive: fields[5] === "is_live" || duration.toUpperCase() === "NA",
        thumbnail: (!fields[4] || fields[4] === "NA")
          ? "https://i.ytimg.com/vi/" + videoId + "/hqdefault.jpg"
          : fields[4]
      })
      if (out.length >= limit) break
    }
    return out
  }

  function fillResults(raw, limit) {
    var tracks = parseTracks(raw, limit)
    for (var i = 0; i < tracks.length; i++) results.append(tracks[i])
  }

  // Builds a mix from a seed track and starts playing it right away. YouTube
  // returns the seed as the first item, so playAt(0) keeps playing what the user
  // picked and queues the rest behind it.
  function startMix(videoId) {
    if (!isVideoId(videoId) || mixLoading) return
    searchDebounce.stop()
    searchProc.mode = "mix"
    searchProc.activeQuery = ""
    searchProc.pendingQuery = ""
    searchMode = false
    searching = true
    mixLoading = true
    errorMessage = ""
    results.clear()
    selectedIndex = 0
    collapseSearch()
    searchProc.command = ["bash", scriptPath, "mix", videoId]
    searchProc.running = true
  }

  // The single entry point for "the user picked this row". Picking a SEARCH
  // result turns into a mix: that is what YouTube Music does when you open a
  // song -- it builds a mix around it instead of leaving the rest of the search
  // results in the queue. Picking inside "up next" only jumps to the track, as
  // that list is already a mix (or a queue the user built), and rebuilding it on
  // every click would throw away what they were listening to.
  function selectTrack(index) {
    if (index < 0 || index >= results.count) return
    var fromSearch = searchMode
    var videoId = results.get(index).videoId
    collapseSearch()
    selectedIndex = index
    playAt(index)
    if (fromSearch) prefetchMix(videoId)
  }

  // Unlike the mix button (startMix), this interrupts nothing: the chosen track
  // has been playing since playAt, and yt-dlp takes seconds to resolve the mix.
  // When it arrives, only the queue is swapped.
  function prefetchMix(videoId) {
    if (!isVideoId(videoId) || mixLoading) return
    // Same pattern as the search pendingQuery: if the user picks another track
    // before yt-dlp finishes, dropping the new request would leave that track
    // with no mix at all. Hold it and fire when the current process exits.
    if (mixProc.running) { mixProc.pending = videoId; return }
    mixProc.pending = ""
    mixProc.seed = videoId
    mixPrefetching = true
    mixProc.command = ["bash", scriptPath, "mix", videoId]
    mixProc.running = true
  }

  // Swaps the queue for the mix while the track on air keeps playing. YouTube
  // usually returns the seed as the first item, but not always -- hence the
  // search, and the fallback that puts it in front. Without that currentIndex
  // would point at a different song and `next` would skip to the wrong one.
  function applyMix(raw, seed) {
    var mix = parseTracks(raw, 40)
    if (mix.length === 0) return
    var seedAt = -1
    for (var i = 0; i < mix.length; i++) {
      if (mix[i].videoId === seed) { seedAt = i; break }
    }
    if (seedAt < 0) {
      mix.unshift({
        videoId: seed,
        title: currentTitle,
        artist: currentArtist,
        duration: currentDuration,
        isLive: currentIsLive,
        thumbnail: currentThumbnail
      })
      seedAt = 0
    }
    results.clear()
    for (var j = 0; j < mix.length; j++) results.append(mix[j])
    currentIndex = seedAt
    selectedIndex = seedAt
    // `requeue`, not `queue`: the latter relaunches mpv, which would cut the
    // audio of the track the user chose seconds ago.
    requeueProc.command = ["bash", scriptPath, "requeue", queueJson(), String(seedAt)]
    requeueProc.running = true
  }

  function loadPlaylists() {
    if (playlistsProc.running) return
    playlistsProc.command = ["bash", scriptPath, "playlists"]
    playlistsProc.running = true
  }

  function applyPlaylists(raw) {
    try {
      var store = JSON.parse(String(raw || "{}"))
      root.playlists = (store && store.playlists instanceof Array) ? store.playlists : []
    } catch (error) {
      console.warn("YouTube Music: invalid playlist store", error)
    }
  }

  function playlistById(id) {
    for (var i = 0; i < playlists.length; i++)
      if (playlists[i].id === id) return playlists[i]
    return null
  }

  function playlistHas(playlist, videoId) {
    if (!playlist || !playlist.tracks || !isVideoId(videoId)) return false
    for (var i = 0; i < playlist.tracks.length; i++)
      if (playlist.tracks[i].videoId === videoId) return true
    return false
  }

  function playlistCount(playlist) {
    var count = (playlist && playlist.tracks) ? playlist.tracks.length : 0
    return count === 1 ? "1 song" : count + " songs"
  }

  function currentTrack() {
    return {
      videoId: currentVideoId,
      title: currentTitle,
      artist: currentArtist,
      thumbnail: currentThumbnail,
      duration: currentDuration,
      isLive: currentIsLive
    }
  }

  // Writes go to disk, but the store is only re-read once the process exits --
  // a whole spawn later. Applying the same change to the local copy first is
  // what makes the heart fill on the click rather than a beat after it; the
  // reload that follows is the confirmation.
  function patchPlaylists(id, videoId, track) {
    var patched = []
    for (var i = 0; i < playlists.length; i++) {
      var entry = playlists[i]
      if (entry.id !== id) { patched.push(entry); continue }
      var tracks = (entry.tracks || []).filter(function(item) { return item.videoId !== videoId })
      if (track) tracks.push(track)
      patched.push({ id: entry.id, name: entry.name, builtin: entry.builtin === true, tracks: tracks })
    }
    playlists = patched
  }

  function addToPlaylist(id, track) {
    if (!id || !track || !isVideoId(track.videoId)) return
    patchPlaylists(id, track.videoId, track)
    runPlaylistCommand(["playlist-add", id, JSON.stringify(track)])
  }

  function removeFromPlaylist(id, videoId) {
    if (!id || !isVideoId(videoId)) return
    patchPlaylists(id, videoId, null)
    runPlaylistCommand(["playlist-remove", id, videoId])
  }

  function toggleLike() {
    if (!isVideoId(currentVideoId)) return
    if (currentLiked) removeFromPlaylist("liked", currentVideoId)
    else addToPlaylist("liked", currentTrack())
  }

  function togglePlaylistMembership(id) {
    if (!isVideoId(currentVideoId)) return
    if (playlistHas(playlistById(id), currentVideoId)) removeFromPlaylist(id, currentVideoId)
    else addToPlaylist(id, currentTrack())
  }

  // `withCurrent` is what turns "new playlist" inside the save sheet into one
  // gesture: the playlist is created with the track already in it, so the shell
  // never has to hand an id back for a second call.
  function createPlaylist(name, withCurrent) {
    var clean = String(name || "").trim()
    if (!clean) return
    var args = ["playlist-create", clean]
    if (withCurrent && isVideoId(currentVideoId)) args.push(JSON.stringify(currentTrack()))
    runPlaylistCommand(args)
  }

  function deletePlaylist(id) {
    if (!id || id === "liked") return
    if (openPlaylistId === id) openPlaylistId = ""
    playlists = playlists.filter(function(entry) { return entry.id !== id })
    runPlaylistCommand(["playlist-delete", id])
  }

  function openPlaylist(id) {
    homeMode = true
    openPlaylistId = id
  }

  function toggleHome() {
    collapseSearch()
    closePicker()
    openPlaylistId = ""
    if (homeMode && currentTitle !== "") { homeMode = false; return }
    homeMode = true
    if (searchField.text !== "") searchField.text = ""
    searchMode = false
    loadPlaylists()
  }

  function openPicker() {
    if (!isVideoId(currentVideoId)) return
    collapseSearch()
    pickerCreating = false
    loadPlaylists()
    playlistPickerOpen = true
  }

  function closePicker() {
    playlistPickerOpen = false
    pickerCreating = false
  }

  // A playlist becomes the queue as it stands. Unlike selectTrack there is no
  // mix afterwards: the list is one the user assembled by hand, and swapping it
  // for a YouTube mix would throw that away.
  function playPlaylist(id, index) {
    var playlist = playlistById(id)
    if (!playlist || !playlist.tracks || playlist.tracks.length === 0) return
    results.clear()
    for (var i = 0; i < playlist.tracks.length; i++) {
      var track = playlist.tracks[i]
      if (!isVideoId(String(track.videoId || ""))) continue
      results.append({
        videoId: String(track.videoId),
        title: String(track.title || "Untitled"),
        artist: String(track.artist || "YouTube"),
        duration: String(track.duration || ""),
        isLive: track.isLive === true,
        thumbnail: String(track.thumbnail || "")
      })
    }
    if (results.count === 0) return
    homeMode = false
    openPlaylistId = ""
    searchMode = false
    playAt(Math.max(0, Math.min(index, results.count - 1)))
  }

  // Serialised on this side too. The shell locks the file, so the store is
  // never corrupted, but firing several Processes at a single `Process` element
  // would simply lose every command after the first.
  function runPlaylistCommand(args) {
    var pending = playlistQueue.slice()
    pending.push(args)
    playlistQueue = pending
    drainPlaylistQueue()
  }

  function drainPlaylistQueue() {
    if (playlistProc.running || playlistQueue.length === 0) return
    var pending = playlistQueue.slice()
    var args = pending.shift()
    playlistQueue = pending
    playlistProc.command = ["bash", scriptPath].concat(args)
    playlistProc.running = true
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
    currentVideoId = track.videoId
    currentIsLive = track.isLive === true
    position = 0
    playbackDuration = 0
    playing = true
    playerRunning = true
    searchDebounce.stop()
    searchMode = false
    // The single point where something starts playing, so it is also where the
    // body switches back to the player. Without this, picking a search result
    // while home was open would start the track and leave the playlists on
    // screen.
    homeMode = false
    openPlaylistId = ""
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

  // mpv answers a seek within a frame, but the status poll behind it only runs
  // every 900ms, so for up to one interval the script still reports the old
  // position. Without the settle window the bar would snap back to where the
  // track was before the click and only then jump forward.
  function sendSeek(seconds) {
    if (seekProc.running) { seekProc.pending = seconds; return }
    seekProc.pending = -1
    seekProc.command = ["bash", scriptPath, "seek", String(Math.round(seconds)), "absolute"]
    seekProc.running = true
  }

  function seekTo(seconds) {
    if (!playerRunning || playbackDuration <= 0) return
    var target = Math.max(0, Math.min(playbackDuration, seconds))
    position = target
    seekSettle.restart()
    sendSeek(target)
  }

  // Dragging only moves the local position; the seek itself goes out on
  // release. Each one costs a bash and a socat, and firing per pixel would
  // queue dozens of them behind a drag.
  function scrub(fraction) {
    if (playbackDuration <= 0) return
    scrubbing = true
    position = Math.max(0, Math.min(1, fraction)) * playbackDuration
  }

  function commitScrub(fraction) {
    scrubbing = false
    if (playbackDuration <= 0) return
    seekTo(Math.max(0, Math.min(1, fraction)) * playbackDuration)
  }

  function nudge(delta) {
    if (playbackDuration <= 0) return
    seekTo(position + delta)
  }

  function sendVolume(value) {
    if (volumeProc.running) { volumeProc.pending = value; return }
    volumeProc.pending = -1
    volumeProc.command = ["bash", scriptPath, "volume", String(value)]
    volumeProc.running = true
  }

  function setVolume(value) {
    var level = Math.max(0, Math.min(100, Math.round(value)))
    if (level === volume) return
    volume = level
    volumeSettle.restart()
    sendVolume(level)
  }

  // Mute remembers the level it came from, so the speaker button is a toggle
  // rather than a one-way trip to zero.
  property int volumeBeforeMute: 70
  function toggleMute() {
    if (volume > 0) { volumeBeforeMute = volume; setVolume(0) }
    else setVolume(volumeBeforeMute > 0 ? volumeBeforeMute : 70)
  }

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
      if (!scrubbing && !seekSettle.running) position = Number(status.position) || 0
      playbackDuration = Number(status.playbackDuration) || 0
      if (status.volume !== undefined && !volumeSettle.running) volume = Math.max(0, Math.min(100, Math.round(Number(status.volume))))
      if (status.title) currentTitle = String(status.title)
      if (status.artist) currentArtist = String(status.artist)
      if (status.thumbnail) currentThumbnail = String(status.thumbnail)
      if (status.duration) currentDuration = String(status.duration)
      if (status.videoId) currentVideoId = String(status.videoId)
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
    property string mode: "search"
    stdout: SplitParser { onRead: function(line) { searchProc.collected += line + "\n" } }
    stderr: StdioCollector { id: searchError; waitForEnd: true }
    onStarted: collected = ""
    onExited: function(code) {
      // A mix does not go through the guards below: they compare the result
      // against the search field text, which is empty here, and would discard
      // the whole list.
      if (mode === "mix") {
        mode = "search"
        searching = false
        mixLoading = false
        root.fillResults(collected, 40)
        if (results.count > 0) root.playAt(0)
        else errorMessage = searchError.text.trim() || "No mix for this track"
        return
      }
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
      root.fillResults(collected, 10)
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
    id: mixProc
    property string collected: ""
    property string seed: ""
    property string pending: ""
    stdout: SplitParser { onRead: function(line) { mixProc.collected += line + "\n" } }
    onStarted: collected = ""
    onExited: function(code) {
      root.mixPrefetching = false
      var pendingSeed = pending
      pending = ""
      if (pendingSeed && pendingSeed !== seed) { root.prefetchMix(pendingSeed); return }
      // If the user already changed track while yt-dlp was resolving, the mix
      // arrived late and is no longer valid: swapping the queue now would pull
      // the rug from under what they just chose.
      if (code !== 0 || root.currentVideoId !== seed) return
      root.applyMix(collected, seed)
    }
  }

  Process {
    id: requeueProc
    onExited: refreshStatus()
  }

  Process {
    id: seekProc
    // A seek fired while the previous one is still running is not dropped: the
    // last position asked for is what the user wants, so it is replayed on exit.
    property real pending: -1
    onExited: if (pending >= 0) { var target = pending; pending = -1; root.sendSeek(target) }
  }

  Process {
    id: volumeProc
    property real pending: -1
    onExited: if (pending >= 0) { var level = pending; pending = -1; root.sendVolume(level) }
  }

  Timer { id: seekSettle; interval: 1400; repeat: false }
  Timer { id: volumeSettle; interval: 1400; repeat: false }

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: playlistProc
    // Deliberately not draining from inside onExited: that would restart the
    // very Process element whose exit is being handled. The timer lets it
    // settle first.
    onExited: playlistDrain.restart()
  }

  Process {
    id: playlistsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPlaylists(text)
    }
  }

  Timer {
    id: playlistDrain
    interval: 30
    repeat: false
    onTriggered: {
      root.drainPlaylistQueue()
      if (!playlistProc.running) root.loadPlaylists()
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
              anchors.right: libraryButton.left
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              elide: Text.ElideRight
            }

            // The way back to the playlists once a track is on air. Without it
            // home would only ever be reachable on an empty player.
            Item {
              id: libraryButton
              width: Style.space(30)
              height: Style.space(30)
              anchors.right: searchBox.left
              anchors.rightMargin: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter

              Text {
                anchors.centerIn: parent
                text: "󰉹"
                color: root.showHome ? root.accent : (libraryArea.containsMouse ? root.ink : root.muted)
                font.family: Style.font.menuFamily
                // Nudged up to draw at the same ink height as the magnifier
                // next to it, which fills more of its em box.
                font.pixelSize: Math.round(Style.font.iconLarge * 1.2)
              }

              MouseArea {
                id: libraryArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleHome()
              }
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
                selectionColor: root.accent
                selectedTextColor: root.onAccent
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
              visible: root.showPlayer
              spacing: Style.space(7)

              // Cover and name on one line. The square hero art pushed the
              // controls and the queue down the panel without telling the user
              // anything the small cover does not, and the room it gives back
              // is what lets the title run to two lines.
              Item {
                id: nowRow
                width: parent.width
                height: Style.space(84)

                Item {
                  id: disc
                  width: parent.height
                  height: width
                  anchors.verticalCenter: parent.verticalCenter

                  // A picture disc rather than a black platter: at this size a
                  // centre label would leave the cover unreadable, so the whole
                  // record is the artwork. Paused rather than stopped while the
                  // track is paused, so it picks the angle back up instead of
                  // snapping to zero.
                  RotationAnimator on rotation {
                    from: 0
                    to: 360
                    duration: 9000
                    loops: Animation.Infinite
                    // Only while the panel is actually up: the widget stays
                    // loaded with the shell, and a rotation ticking behind a
                    // closed popup buys nothing.
                    running: root.opened
                    paused: !root.playing
                  }

                  // ClippingRectangle and not a Rectangle with `clip`: a plain
                  // Item clips to its bounding box, so the artwork kept its
                  // square corners and the "record" turned as a spinning
                  // square. This one clips along the radius.
                  ClippingRectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: "#292929"
                    Image {
                      anchors.fill: parent
                      source: root.discArt(root.currentThumbnail)
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                    }
                  }

                  // Grooves, a rim and a spindle hub. Without them a turning
                  // circle just reads as a wobbling thumbnail; the rings are
                  // the whole reason it registers as a record. They alternate
                  // light and dark so they stay visible over artwork of any
                  // brightness -- a single light ring vanishes on pale covers.
                  Rectangle { anchors.centerIn: parent; width: parent.width * 0.9; height: width; radius: width / 2; color: "transparent"; border.width: 1; border.color: "#59000000" }
                  Rectangle { anchors.centerIn: parent; width: parent.width * 0.86; height: width; radius: width / 2; color: "transparent"; border.width: 1; border.color: "#40ffffff" }
                  Rectangle { anchors.centerIn: parent; width: parent.width * 0.74; height: width; radius: width / 2; color: "transparent"; border.width: 1; border.color: "#59000000" }
                  Rectangle { anchors.centerIn: parent; width: parent.width * 0.7; height: width; radius: width / 2; color: "transparent"; border.width: 1; border.color: "#40ffffff" }
                  Rectangle { anchors.centerIn: parent; width: parent.width * 0.56; height: width; radius: width / 2; color: "transparent"; border.width: 1; border.color: "#59000000" }

                  // The label and its spindle hole. The label is what sells the
                  // shape at this size: a disc whose art runs edge to edge and
                  // centre reads as a coin.
                  Rectangle {
                    anchors.centerIn: parent
                    width: parent.width * 0.34
                    height: width
                    radius: width / 2
                    color: "#141414"
                    border.width: 1
                    border.color: "#4dffffff"
                    Rectangle { anchors.centerIn: parent; width: parent.width * 0.3; height: width; radius: width / 2; color: "#000000" }
                  }
                }

                // Sheen and rim, deliberately outside the turning item: the
                // light in the room does not spin with the record. The sheen
                // gives the platter its gloss, and the rim is doing real work
                // -- the clip along the radius is not antialiased, so without a
                // ring drawn over it the edge of the disc comes out jagged.
                ClippingRectangle {
                  anchors.fill: disc
                  radius: width / 2
                  color: "transparent"
                  Rectangle {
                    anchors.fill: parent
                    gradient: Gradient {
                      GradientStop { position: 0.0; color: "#26ffffff" }
                      GradientStop { position: 0.5; color: "#00ffffff" }
                      GradientStop { position: 1.0; color: "#1f000000" }
                    }
                  }
                }
                Rectangle {
                  anchors.fill: disc
                  radius: width / 2
                  color: "transparent"
                  border.width: Math.max(2, Math.round(width * 0.035))
                  border.color: "#f0101010"
                }

                Item {
                  anchors.left: disc.right
                  anchors.leftMargin: Style.space(14)
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  height: titleColumn.height

                  Column {
                    id: titleColumn
                    width: parent.width
                    spacing: Style.space(2)
                    readonly property var parts: root.trackParts(root.currentTitle, root.currentArtist)
                    // Two lines are still allowed: with the artist prefix and
                    // the version tail moved to the line below, the song name
                    // fits on one nearly every time, and the second line is
                    // there for the ones that do not.
                    Text {
                      width: parent.width
                      text: titleColumn.parts.name
                      color: root.ink
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.title
                      font.bold: true
                      wrapMode: Text.WordWrap
                      maximumLineCount: 2
                      elide: Text.ElideRight
                    }
                    // Artist and version share one muted line: which release
                    // this is matters, but never as much as which song it is.
                    Text {
                      width: parent.width
                      text: titleColumn.parts.tail === "" ? root.currentArtist
                                                          : root.currentArtist + "  ·  " + titleColumn.parts.tail
                      color: root.muted
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }
                  }
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
                // Click and drag to seek. The drawn bar stays thin, but the
                // hit area is the full row height: a 3px target is a miss more
                // often than a hit, and this is the control people reach for
                // most after play.
                Item {
                  id: seekBar
                  width: Math.max(Style.space(40), parent.width - timeRow.labelWidth * 2 - timeRow.spacing * 2)
                  height: timeRow.height
                  anchors.verticalCenter: parent.verticalCenter

                  readonly property bool seekable: root.playbackDuration > 0
                  readonly property real ratio: seekable ? Math.max(0, Math.min(1, root.position / root.playbackDuration)) : 0
                  readonly property bool hot: seekable && (seekArea.containsMouse || seekArea.pressed)

                  Rectangle {
                    id: seekTrack
                    width: parent.width
                    height: seekBar.hot ? Style.space(5) : Style.space(3)
                    radius: height / 2
                    color: "#555555"
                    anchors.verticalCenter: parent.verticalCenter
                    Behavior on height { NumberAnimation { duration: 90 } }
                    Rectangle {
                      width: parent.width * seekBar.ratio
                      height: parent.height
                      radius: height / 2
                      color: root.accent
                    }
                  }

                  Rectangle {
                    width: Style.space(10)
                    height: width
                    radius: width / 2
                    color: root.accent
                    anchors.verticalCenter: parent.verticalCenter
                    x: seekTrack.width * seekBar.ratio - width / 2
                    opacity: seekBar.hot ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 90 } }
                  }

                  MouseArea {
                    id: seekArea
                    anchors.fill: parent
                    enabled: seekBar.seekable
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPressed: function(mouse) { root.scrub(mouse.x / seekBar.width) }
                    onPositionChanged: function(mouse) { if (pressed) root.scrub(mouse.x / seekBar.width) }
                    onReleased: function(mouse) { root.commitScrub(mouse.x / seekBar.width) }
                    onCanceled: root.scrubbing = false
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
                    width: Style.space(42); height: width; radius: width / 2; color: "transparent"; border.width: 1; border.color: root.accent; anchors.verticalCenter: parent.verticalCenter
                    Text { anchors.centerIn: parent; text: root.playing ? "󰏤" : "󰐊"; color: root.ink; font.family: Style.font.menuFamily; font.pixelSize: Style.font.iconLarge }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.collapseSearch(); root.togglePlayback() } }
                  }
                  Text {
                    text: "󰒭"; color: root.ink; font.family: Style.font.menuFamily; font.pixelSize: Style.font.iconLarge; anchors.verticalCenter: parent.verticalCenter
                    MouseArea { anchors.fill: parent; anchors.margins: -Style.space(8); cursorShape: Qt.PointingHandCursor; onClicked: { root.collapseSearch(); root.next() } }
                  }
                }

                // Deliberately outside the Row: that keeps prev/play/next
                // centred in the panel while the save controls sit in the
                // corners, one on each side.
                Row {
                  id: leftControls
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(2)
                  spacing: Style.space(10)

                  Text {
                    id: likeGlyph
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.currentLiked ? "󰋑" : "󰋕"
                    visible: root.isVideoId(root.currentVideoId)
                    color: root.currentLiked ? root.accent : (likeArea.containsMouse ? root.ink : root.dim)
                    font.family: Style.font.menuFamily
                    // The three corner glyphs are sized to draw at the same ink
                    // height (~12px next to the 11px arrows), not to the same
                    // nominal size: each fills a different share of its em box,
                    // so equal pixelSize renders them visibly unequal. The
                    // multipliers come from measuring the rendered glyphs.
                    font.pixelSize: Math.round(Style.font.iconLarge * 1.3)

                    // A short kick on the way in only. The heart is the one
                    // control in this row that changes stored state rather than
                    // playback, and the beat is its acknowledgement.
                    onTextChanged: if (root.currentLiked) likeBeat.restart()
                    SequentialAnimation {
                      id: likeBeat
                      NumberAnimation { target: likeGlyph; property: "scale"; to: 1.3; duration: 110; easing.type: Easing.OutQuad }
                      NumberAnimation { target: likeGlyph; property: "scale"; to: 1.0; duration: 150; easing.type: Easing.OutBack }
                    }

                    MouseArea {
                      id: likeArea
                      anchors.fill: parent
                      anchors.margins: -Style.space(8)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.toggleLike()
                    }

                    PanelToolTip {
                      visible: likeArea.containsMouse
                      text: root.currentLiked ? "Remove from Liked songs" : "Add to Liked songs"
                    }
                  }

                  // The slider stays folded behind the speaker until it is
                  // wanted: at this width a permanent one would crowd the
                  // transport row, and volume is set far less often than it is
                  // glanced at.
                  Item {
                    id: volumeControl
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property bool open: volumeArea.containsMouse || volumeSliderArea.containsMouse || volumeSliderArea.pressed
                    width: volumeGlyph.width + (open ? Style.space(6) + volumeSlider.width : 0)
                    height: Style.space(20)
                    clip: true
                    Behavior on width { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

                    Text {
                      id: volumeGlyph
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.left: parent.left
                      text: root.volume === 0 ? "󰝟" : (root.volume < 34 ? "󰕿" : (root.volume < 67 ? "󰖀" : "󰕾"))
                      color: root.volume === 0 ? root.accent : (volumeControl.open ? root.ink : root.dim)
                      font.family: Style.font.menuFamily
                      // Same measured-ink sizing as the other corner glyphs.
                      font.pixelSize: Math.round(Style.font.iconLarge * 1.15)

                      MouseArea {
                        id: volumeArea
                        anchors.fill: parent
                        anchors.margins: -Style.space(6)
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleMute()
                        // The wheel is what people try on a speaker icon before
                        // they find the slider.
                        onWheel: function(wheel) { root.setVolume(root.volume + (wheel.angleDelta.y > 0 ? 5 : -5)) }
                      }

                      PanelToolTip {
                        visible: volumeArea.containsMouse
                        text: root.volume === 0 ? "Unmute" : "Volume " + root.volume + "%"
                      }
                    }

                    Item {
                      id: volumeSlider
                      anchors.left: volumeGlyph.right
                      anchors.leftMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(46)
                      height: parent.height
                      opacity: volumeControl.open ? 1 : 0
                      Behavior on opacity { NumberAnimation { duration: 110 } }

                      Rectangle {
                        id: volumeTrack
                        width: parent.width
                        height: Style.space(3)
                        radius: height / 2
                        color: "#555555"
                        anchors.verticalCenter: parent.verticalCenter
                        Rectangle {
                          width: parent.width * (root.volume / 100)
                          height: parent.height
                          radius: height / 2
                          color: root.accent
                        }
                      }

                      Rectangle {
                        width: Style.space(8)
                        height: width
                        radius: width / 2
                        color: root.accent
                        anchors.verticalCenter: parent.verticalCenter
                        x: volumeTrack.width * (root.volume / 100) - width / 2
                      }

                      MouseArea {
                        id: volumeSliderArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onPressed: function(mouse) { root.setVolume(mouse.x / width * 100) }
                        onPositionChanged: function(mouse) { if (pressed) root.setVolume(mouse.x / width * 100) }
                        onWheel: function(wheel) { root.setVolume(root.volume + (wheel.angleDelta.y > 0 ? 5 : -5)) }
                      }
                    }
                  }
                }

                Row {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(2)
                  spacing: Style.space(12)
                  visible: root.isVideoId(root.currentVideoId)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    // Outline when the track is in no playlist, filled when it
                    // is -- the same empty/full language as the heart beside
                    // it, rather than one solid shape that always reads as on.
                    text: root.currentSaved ? "󰃀" : "󰃃"
                    color: root.currentSaved ? root.accent : (saveArea.containsMouse ? root.ink : root.dim)
                    font.family: Style.font.menuFamily
                    // The tallest of the three glyphs by a wide margin, so it
                    // takes the smallest multiplier to land on the same ink
                    // height. See the heart above.
                    font.pixelSize: Math.round(Style.font.iconLarge * 0.9)
                    MouseArea {
                      id: saveArea
                      anchors.fill: parent
                      anchors.margins: -Style.space(8)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openPicker()
                    }

                    PanelToolTip { visible: saveArea.containsMouse; text: "Save to playlist" }
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰀃"
                    color: root.mixLoading ? root.accent : (mixArea.containsMouse ? root.ink : root.dim)
                    font.family: Style.font.menuFamily
                    // Deliberately larger than its iconLarge neighbours: the
                    // access-point glyph fills much less of its em box than the
                    // arrows and the play icon, so at the same nominal size it
                    // looks smaller -- at 1.7x its drawn height matches the 18px
                    // arrows. Kept a multiple of the token so it still follows
                    // the theme.
                    font.pixelSize: Math.round(Style.font.iconLarge * 1.7)
                    opacity: root.mixLoading ? 0.6 : 1
                    SequentialAnimation on scale {
                      running: root.mixLoading
                      loops: Animation.Infinite
                      NumberAnimation { to: 0.86; duration: 480; easing.type: Easing.InOutQuad }
                      NumberAnimation { to: 1.0; duration: 480; easing.type: Easing.InOutQuad }
                    }
                    MouseArea {
                      id: mixArea
                      anchors.fill: parent
                      anchors.margins: -Style.space(8)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.startMix(root.currentVideoId)
                    }

                    // The one glyph in the panel nobody reads on sight.
                    PanelToolTip {
                      visible: mixArea.containsMouse
                      text: root.mixLoading ? "Building mix…" : "Start radio from this song"
                    }
                  }
                }
              }

              Rectangle { width: parent.width; height: 1; color: "#343434" }
              // Not "Up next": the track on air stays in this list, with the
              // ones already played dimmed above it, so the heading has to name
              // the whole queue rather than what follows.
              Text { text: (root.mixLoading || root.mixPrefetching) ? "Building mix…" : "Queue"; color: root.ink; font.family: Style.font.menuFamily; font.pixelSize: Style.font.bodySmall; font.bold: true }

              ListView {
                id: upNextList
                width: parent.width
                height: parent.height - y
                model: results
                clip: true
                // The track on air now moves down the list as the mix
                // advances; without following it, it would scroll out of view
                // after a handful of songs.
                currentIndex: root.currentIndex
                onCurrentIndexChanged: if (currentIndex >= 0 && currentIndex < count) positionViewAtIndex(currentIndex, ListView.Contain)
                spacing: Style.space(2)
                delegate: TrackRow { }
              }
            }

            Item {
              anchors.fill: parent
              visible: root.showSearch

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
                  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.selectTrack(root.selectedIndex); event.accepted = true }
                }
                delegate: TrackRow { expanded: true }
              }
            }

            // Home. The library root, or one playlist opened from it.
            Item {
              anchors.fill: parent
              visible: root.showHome

              Column {
                anchors.fill: parent
                spacing: Style.space(7)
                visible: root.openPlaylistId === ""

                Item {
                  width: parent.width
                  height: Style.space(26)

                  Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Playlists"
                    color: root.ink
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰐕"
                    color: root.homeCreating ? root.accent : (homeNewArea.containsMouse ? root.ink : root.dim)
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.iconLarge

                    MouseArea {
                      id: homeNewArea
                      anchors.fill: parent
                      anchors.margins: -Style.space(6)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.homeCreating = !root.homeCreating
                        if (root.homeCreating) homeNameInput.begin()
                      }
                    }
                  }
                }

                NameInput {
                  id: homeNameInput
                  width: parent.width
                  visible: root.homeCreating
                  // An empty playlist made from home: there is no current track
                  // to seed it with, unlike the one made from the save sheet.
                  submit: function(name) { root.createPlaylist(name, false); root.homeCreating = false }
                  cancel: function() { root.homeCreating = false }
                }

                ListView {
                  id: playlistList
                  width: parent.width
                  height: parent.height - y
                  model: root.playlists
                  clip: true
                  spacing: Style.space(2)
                  delegate: PlaylistRow { }

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.verticalCenterOffset: Style.space(20)
                    width: parent.width - Style.space(40)
                    visible: root.libraryEmpty
                    text: "Search for something worth hearing,\nthen keep it with 󰋕 or 󰃀"
                    color: root.muted
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.bodySmall
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                  }
                }
              }

              Column {
                id: playlistDetail
                anchors.fill: parent
                spacing: Style.space(7)
                visible: root.openPlaylistId !== ""
                readonly property var playlist: root.playlistById(root.openPlaylistId)

                Item {
                  width: parent.width
                  height: Style.space(30)

                  Text {
                    id: backGlyph
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰅁"
                    color: backArea.containsMouse ? root.ink : root.muted
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.iconLarge

                    MouseArea {
                      id: backArea
                      anchors.fill: parent
                      anchors.margins: -Style.space(6)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openPlaylistId = ""
                    }
                  }

                  Column {
                    anchors.left: backGlyph.right
                    anchors.leftMargin: Style.space(9)
                    anchors.right: detailPlay.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)
                    Text {
                      width: parent.width
                      text: playlistDetail.playlist ? playlistDetail.playlist.name : ""
                      color: root.ink
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                      elide: Text.ElideRight
                    }
                    Text {
                      width: parent.width
                      text: root.playlistCount(playlistDetail.playlist)
                      color: root.muted
                      font.family: Style.font.menuFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  Text {
                    id: detailPlay
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰐊"
                    visible: playlistDetail.playlist && playlistDetail.playlist.tracks
                             && playlistDetail.playlist.tracks.length > 0
                    color: detailPlayArea.containsMouse ? root.accent : root.ink
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.iconLarge

                    MouseArea {
                      id: detailPlayArea
                      anchors.fill: parent
                      anchors.margins: -Style.space(7)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.playPlaylist(root.openPlaylistId, 0)
                    }
                  }
                }

                Rectangle { width: parent.width; height: 1; color: "#343434" }

                ListView {
                  width: parent.width
                  height: parent.height - y
                  model: playlistDetail.playlist ? playlistDetail.playlist.tracks : []
                  clip: true
                  spacing: Style.space(2)
                  delegate: PlaylistTrackRow { }

                  Text {
                    anchors.centerIn: parent
                    visible: parent.count === 0
                    text: "Nothing saved here yet"
                    color: root.muted
                    font.family: Style.font.menuFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }
        }
      }

      // The save sheet, drawn over the whole card rather than as a menu hanging
      // off the bookmark: the card is 400px wide and that button sits at
      // mid-height, so an anchored popup would have nowhere to grow.
      Rectangle {
        anchors.fill: parent
        color: "#cc0f0f0f"
        visible: root.playlistPickerOpen
        z: 20

        MouseArea { anchors.fill: parent; onClicked: root.closePicker() }

        Rectangle {
          anchors.centerIn: parent
          width: parent.width - Style.space(56)
          height: Math.min(parent.height - Style.space(64),
                           Style.space(118) + root.playlists.length * Style.space(40)
                             + (root.pickerCreating ? Style.space(41) : 0))
          radius: Style.space(10)
          color: "#1c1c1c"
          border.width: 1
          border.color: "#3a3a3a"

          // Swallows clicks so they do not reach the dimmer behind and close
          // the sheet the moment the user aims at a row.
          MouseArea { anchors.fill: parent }

          Column {
            anchors.fill: parent
            anchors.margins: Style.space(14)
            spacing: Style.space(7)

            Text {
              width: parent.width
              text: "Save to playlist"
              color: root.ink
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Text {
              width: parent.width
              text: root.currentTitle
              color: root.muted
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            NameInput {
              id: pickerNameInput
              width: parent.width
              visible: root.pickerCreating
              // Created with the track already in it, so "new playlist" from
              // here stays one gesture instead of create-then-tick.
              submit: function(name) { root.createPlaylist(name, true); root.pickerCreating = false }
              cancel: function() { root.pickerCreating = false }
            }

            ListView {
              id: pickerList
              width: parent.width
              height: parent.height - y - pickerNewRow.height - parent.spacing
              model: root.playlists
              clip: true
              spacing: Style.space(2)
              delegate: PickerRow { }
            }

            Item {
              id: pickerNewRow
              width: parent.width
              height: Style.space(32)

              Rectangle {
                anchors.fill: parent
                radius: Style.space(6)
                color: pickerNewArea.containsMouse ? "#262626" : "transparent"
              }

              Row {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰐕"
                  color: root.pickerCreating ? root.accent : root.muted
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.iconLarge
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "New playlist"
                  color: root.ink
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              MouseArea {
                id: pickerNewArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.pickerCreating = !root.pickerCreating
                  if (root.pickerCreating) pickerNameInput.begin()
                }
              }
            }
          }
        }
      }
  }

  // Shared by home and the save sheet: same field, different destination, so
  // the caller hands in what to do on Enter and on Escape.
  component NameInput: Rectangle {
    id: nameInput
    property var submit: null
    property var cancel: null
    height: Style.space(34)
    radius: Style.space(7)
    color: root.raised
    border.width: nameField.activeFocus ? 1 : 0
    border.color: root.ink

    function begin() {
      nameField.text = ""
      nameField.forceActiveFocus()
    }

    TextInput {
      id: nameField
      anchors.fill: parent
      anchors.leftMargin: Style.space(11)
      anchors.rightMargin: Style.space(11)
      verticalAlignment: TextInput.AlignVCenter
      color: root.ink
      selectionColor: root.accent
      selectedTextColor: root.onAccent
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.bodySmall
      maximumLength: 60
      clip: true

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "Playlist name"
        color: root.muted
        font: nameField.font
        visible: !nameField.text
      }

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (nameInput.submit) nameInput.submit(nameField.text)
          nameField.text = ""
          event.accepted = true
        } else if (event.key === Qt.Key_Escape) {
          nameField.text = ""
          if (nameInput.cancel) nameInput.cancel()
          event.accepted = true
        }
      }
    }
  }

  component PlaylistRow: Rectangle {
    id: playlistRow
    required property int index
    required property var modelData
    readonly property bool builtin: modelData.builtin === true
    readonly property int trackCount: modelData.tracks ? modelData.tracks.length : 0
    // The first track's artwork stands in for a cover. An empty playlist falls
    // back to a glyph rather than a grey square.
    readonly property string cover: trackCount > 0 ? String(modelData.tracks[0].thumbnail || "") : ""
    width: ListView.view ? ListView.view.width : 0
    height: Style.space(46)
    radius: Style.space(7)
    color: (playlistArea.containsMouse || playlistPlayArea.containsMouse || playlistDeleteArea.containsMouse)
           ? "#222222" : "transparent"

    Row {
      z: 2
      anchors.fill: parent
      anchors.leftMargin: Style.space(4)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(7)

      Rectangle {
        width: Style.space(36)
        height: width
        radius: Style.space(5)
        color: "#292929"
        clip: true
        anchors.verticalCenter: parent.verticalCenter

        Image {
          anchors.fill: parent
          source: playlistRow.cover
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          visible: playlistRow.cover !== ""
        }

        Text {
          anchors.centerIn: parent
          visible: playlistRow.cover === ""
          text: playlistRow.builtin ? "󰋑" : "󰲹"
          color: playlistRow.builtin ? root.accent : root.dim
          font.family: Style.font.menuFamily
          font.pixelSize: Math.round(Style.font.bodySmall * 1.5)
        }
      }

      Column {
        width: parent.width - Style.space(103)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Text {
          width: parent.width
          text: playlistRow.modelData.name
          color: root.ink
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: root.playlistCount(playlistRow.modelData)
          color: root.muted
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Item {
        width: Style.space(22)
        height: parent.height

        Text {
          anchors.centerIn: parent
          text: "󰆴"
          color: playlistDeleteArea.containsMouse ? "#ff7a7a" : root.dim
          font.family: Style.font.menuFamily
          font.pixelSize: Math.round(Style.font.bodySmall * 1.4)
          // "Liked songs" cannot be deleted -- the shell refuses it too, so the
          // button simply never appears rather than failing silently.
          opacity: (!playlistRow.builtin
                    && (playlistArea.containsMouse || playlistDeleteArea.containsMouse
                        || playlistPlayArea.containsMouse)) ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 90 } }
        }

        MouseArea {
          id: playlistDeleteArea
          anchors.fill: parent
          enabled: !playlistRow.builtin
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.deletePlaylist(playlistRow.modelData.id)
        }
      }

      Item {
        width: Style.space(24)
        height: parent.height

        Text {
          anchors.centerIn: parent
          text: "󰐊"
          color: playlistPlayArea.containsMouse ? root.accent : root.ink
          font.family: Style.font.menuFamily
          font.pixelSize: Math.round(Style.font.bodySmall * 1.5)
          opacity: (playlistRow.trackCount > 0
                    && (playlistArea.containsMouse || playlistPlayArea.containsMouse
                        || playlistDeleteArea.containsMouse)) ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 90 } }
        }

        MouseArea {
          id: playlistPlayArea
          anchors.fill: parent
          enabled: playlistRow.trackCount > 0
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.playPlaylist(playlistRow.modelData.id, 0)
        }
      }
    }

    MouseArea {
      id: playlistArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openPlaylist(playlistRow.modelData.id)
    }
  }

  // The rows inside one open playlist. Close to TrackRow, but its model is a
  // plain JS array off the store rather than the `results` ListModel, and its
  // hover action removes the track instead of starting a mix.
  component PlaylistTrackRow: Rectangle {
    id: savedRow
    required property int index
    required property var modelData
    width: ListView.view ? ListView.view.width : 0
    height: Style.space(44)
    radius: Style.space(7)
    color: (savedArea.containsMouse || savedRemoveArea.containsMouse) ? "#222222" : "transparent"

    Row {
      z: 2
      anchors.fill: parent
      anchors.leftMargin: Style.space(4)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(7)

      Rectangle {
        id: savedThumb
        width: Style.space(34)
        height: width
        radius: Style.space(5)
        color: "#292929"
        clip: true
        anchors.verticalCenter: parent.verticalCenter
        Image {
          anchors.fill: parent
          source: String(savedRow.modelData.thumbnail || "")
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
        }
      }

      // Measured off the siblings, for the same reason as the queue row.
      Column {
        width: parent.width - savedThumb.width - savedRemoveSlot.width - savedDuration.width - parent.spacing * 3
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Text {
          width: parent.width
          textFormat: Text.StyledText
          text: root.trackMarkup(savedRow.modelData.title || "Untitled", savedRow.modelData.artist, root.dim)
          color: savedRow.modelData.videoId === root.currentVideoId ? root.accent : root.ink
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: String(savedRow.modelData.artist || "YouTube")
          color: root.muted
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Item {
        id: savedRemoveSlot
        width: Style.space(22)
        height: parent.height

        Text {
          anchors.centerIn: parent
          text: "󰅖"
          color: savedRemoveArea.containsMouse ? "#ff7a7a" : root.dim
          font.family: Style.font.menuFamily
          font.pixelSize: Math.round(Style.font.bodySmall * 1.3)
          opacity: (savedArea.containsMouse || savedRemoveArea.containsMouse) ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 90 } }
        }

        MouseArea {
          id: savedRemoveArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.removeFromPlaylist(root.openPlaylistId, String(savedRow.modelData.videoId || ""))
        }
      }

      Text {
        id: savedDuration
        width: Style.space(38)
        text: root.durationLabel(savedRow.modelData.duration, savedRow.modelData.isLive === true)
        color: savedRow.modelData.isLive === true ? root.accent : root.muted
        font.family: Style.font.menuFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      id: savedArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.playPlaylist(root.openPlaylistId, savedRow.index)
    }
  }

  component PickerRow: Rectangle {
    id: pickerRow
    required property int index
    required property var modelData
    readonly property bool checked: root.playlistHas(modelData, root.currentVideoId)
    width: ListView.view ? ListView.view.width : 0
    height: Style.space(38)
    radius: Style.space(6)
    color: pickerRowArea.containsMouse ? "#262626" : "transparent"

    Row {
      anchors.fill: parent
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(18)
        text: pickerRow.checked ? "󰄬" : (pickerRow.modelData.id === "liked" ? "󰋕" : "󰲹")
        color: pickerRow.checked ? root.accent : root.dim
        font.family: Style.font.menuFamily
        font.pixelSize: Math.round(Style.font.bodySmall * 1.4)
        horizontalAlignment: Text.AlignHCenter
      }

      Column {
        width: parent.width - Style.space(34)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)
        Text {
          width: parent.width
          text: pickerRow.modelData.name
          color: root.ink
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Text {
          width: parent.width
          text: root.playlistCount(pickerRow.modelData)
          color: root.muted
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      id: pickerRowArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.togglePlaylistMembership(pickerRow.modelData.id)
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
    required property string videoId
    property bool expanded: false
    width: ListView.view ? ListView.view.width : 0
    height: expanded ? Style.space(50) : Style.space(38)
    // The track on air no longer disappears from the list, and the ones already
    // played stay behind, only dimmed -- you can go back to them, and you can
    // still see where you are inside the mix. Skipped for `expanded`, which is
    // the search list, where "already played" does not exist.
    opacity: (!expanded && root.currentIndex >= 0 && index < root.currentIndex) ? 0.45 : 1
    Behavior on opacity { NumberAnimation { duration: 140 } }
    radius: Style.space(7)
    color: index === root.selectedIndex ? "#292929" : ((trackArea.containsMouse || rowMixArea.containsMouse) ? "#222222" : "transparent")

    // z above trackArea (declared later) so the mix button gets the click; the
    // rest of the Row has no MouseArea, so clicks fall through to trackArea as
    // before.
    Row {
      z: 2
      anchors.fill: parent
      anchors.leftMargin: Style.space(4)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(7)

      Rectangle {
        id: rowThumb
        width: expanded ? Style.space(40) : Style.space(30)
        height: width
        radius: Style.space(5)
        color: "#292929"
        clip: true
        anchors.verticalCenter: parent.verticalCenter
        Image { anchors.fill: parent; source: trackRow.thumbnail; fillMode: Image.PreserveAspectCrop; asynchronous: true }
      }

      // Measured off the siblings rather than counted by hand: the constant
      // that used to sit here was 8px short, which pushed the duration past
      // the row's right edge and let the list clip the last digit off it.
      Column {
        width: parent.width - rowThumb.width - rowMixSlot.width - rowDuration.width - parent.spacing * 3
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)
        Text {
          width: parent.width
          textFormat: Text.StyledText
          text: root.trackMarkup(trackRow.title, trackRow.artist, root.dim)
          color: trackRow.index === root.currentIndex ? root.accent : root.ink
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: trackRow.index === root.currentIndex
          elide: Text.ElideRight
        }
        Text { width: parent.width; text: trackRow.artist; color: root.muted; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
      }

      Item {
        id: rowMixSlot
        width: Style.space(22)
        height: parent.height
        Text {
          anchors.centerIn: parent
          text: "󰀃"
          color: rowMixArea.containsMouse ? root.accent : root.dim
          font.family: Style.font.menuFamily
          // Same reason as the transport button; 1.7x still fits the
          // Style.space(22) slot reserved by the Column width beside it.
          font.pixelSize: Math.round(Style.font.bodySmall * 1.7)
          opacity: (trackArea.containsMouse || rowMixArea.containsMouse) ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 90 } }
        }
        MouseArea {
          id: rowMixArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.startMix(trackRow.videoId)
        }

        PanelToolTip { visible: rowMixArea.containsMouse; text: "Start radio from this song" }
      }

      Text { id: rowDuration; width: Style.space(38); text: root.durationLabel(trackRow.duration, trackRow.isLive); color: trackRow.isLive ? root.accent : root.muted; font.family: Style.font.menuFamily; font.pixelSize: Style.font.caption; horizontalAlignment: Text.AlignRight; anchors.verticalCenter: parent.verticalCenter }
    }

    MouseArea {
      id: trackArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.selectTrack(trackRow.index)
    }
  }
}
