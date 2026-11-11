import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Ui as Ui
import qs.Commons
import qs.Commons as Palette
import "ProviderModel.js" as Model

Item {
  id: root
  property var shell: null
  property bool isOpen: false
  property Item popupAnchor: null
  property QtObject popupBar: null
  property string lastCapabilities: ""
  property string provider: "spotify"
  property var bindings: ({})
  property bool settingsReady: false
  property bool showSessions: false
  property string localError: ""
  property string tab: "playlists"
  property string playlistName: ""
  property string query: ""
  property string pendingProvider: ""
  property int switchAttempts: 0
  property real displayedPosition: 0
  readonly property var mediaService: shell ? shell.serviceFor("omarchy.media") : null
  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property string boundKey: String(bindings[provider] || "")
  readonly property var selectedPlayer: Model.boundPlayer(players, boundKey, provider)
  readonly property bool switching: pendingProvider !== ""
  readonly property bool controllable: !switching && !!selectedPlayer && selectedPlayer.canControl
  readonly property bool spotifyReady: provider === "spotify" && bridge.connected
  readonly property var rawItems: tab === "queue" ? bridge.queue : (tab === "tracks" ? bridge.playlistItems : bridge.playlists)
  readonly property var visibleItems: spotifyReady ? Model.filtered(rawItems, query) : []
  readonly property string settingsPath: Quickshell.env("DAEMON_MUSIC_SETTINGS_PATH") || Quickshell.env("HOME") + "/.config/omarchy/daemon-music.json"

  function resolvePopupAnchor() {
    popupAnchor = null;
    popupBar = null;
    var candidateBar = shell && shell.bar ? shell.bar : null;
    if (!candidateBar || candidateBar.barHidden || !candidateBar.moduleSlots || typeof candidateBar.slotWindow !== "function") return;
    var screenName = typeof candidateBar.focusedScreenName === "function" ? candidateBar.focusedScreenName() : "";
    var fallback = null;
    for (var i = 0; i < candidateBar.moduleSlots.length; i++) {
      var slot = candidateBar.moduleSlots[i];
      var item = slot && slot.activeItem;
      if (!item || item.visible === false || item.width <= 0) continue;
      var window = candidateBar.slotWindow(slot);
      if (!window || !window.screen) continue;
      if (!fallback) fallback = item;
      if (screenName && window.screen.name === screenName) {
        popupAnchor = item;
        popupBar = candidateBar;
        return;
      }
    }
    if (fallback && !screenName) { popupAnchor = fallback; popupBar = candidateBar; }
  }
  function open(payloadJson) {
    resolvePopupAnchor();
    isOpen = true;
    if (payloadJson) {
      try {
        var payload = JSON.parse(payloadJson);
        if (["spotify", "apple", "youtube"].indexOf(payload.provider) !== -1) chooseProvider(payload.provider);
        if (["playlists", "queue"].indexOf(payload.view) !== -1) selectTab(payload.view);
      } catch (e) { localError = "Invalid panel request."; }
    }
    Qt.callLater(function() { search.forceActiveFocus(); });
  }
  function close() { isOpen = false; }
  function requestClose() {
    if (shell) shell.hide("daemon0.music");
    else close();
  }
  function saveSettings() {
    if (!settingsReady) return;
    settingsFile.setText(JSON.stringify({schema:1, provider:provider, bindings:bindings}, null, 2) + "\n");
  }
  function bindSession(key) {
    var candidate = Model.findPlayer(players, key);
    if (!candidate) { localError = "That player session disappeared."; return; }
    if (!Model.compatiblePlayer(provider, candidate)) {
      localError = provider === "spotify" ? "Spotify requires the exact org.mpris.MediaPlayer2.spotify session." : "That session reports a media URL from a different service. Start the selected provider first.";
      return;
    }
    // A shared browser instance cannot be assigned to two different providers.
    var next = {};
    for (var name in bindings) if (bindings[name] !== key) next[name] = bindings[name];
    next[provider] = key;
    bindings = next;
    showSessions = false;
    localError = "";
    saveSettings();
  }
  function unbind() {
    var next = {};
    for (var name in bindings) if (name !== provider) next[name] = bindings[name];
    bindings = next;
    saveSettings();
  }
  function finishSwitch(destination) {
    pendingProvider = "";
    provider = destination;
    query = "";
    tab = "playlists";
    playlistName = "";
    localError = "";
    list.currentIndex = -1;
    saveSettings();
  }
  function chooseProvider(destination) {
    if (switching || destination === provider) return;
    var current = selectedPlayer;
    if (current && current.isPlaying) {
      if (!current.canPause) { localError = "Pause the current player before switching providers."; return; }
      current.pause();
      pendingProvider = destination;
      switchAttempts = 0;
      switchTimer.restart();
    } else finishSwitch(destination);
  }
  function otherProviderPlaying() {
    for (var name in bindings) {
      if (name === provider) continue;
      var other = Model.boundPlayer(players, bindings[name], name);
      if (other && other.isPlaying) return true;
    }
    return false;
  }
  function transport(action) {
    var p = selectedPlayer;
    if (!controllable || !p || p.dbusName !== boundKey) { localError = "The bound player is unavailable."; return; }
    if (action === "play" && otherProviderPlaying()) { localError = "Pause the other bound provider before starting playback."; return; }
    localError = "";
    if (action === "pause" && p.canPause) p.pause();
    else if (action === "play" && p.canPlay) p.play();
    else if (action === "next" && p.canGoNext) p.next();
    else if (action === "previous" && p.canGoPrevious) p.previous();
    else localError = "This player does not support that action.";
  }
  function seekTo(value) {
    var p = selectedPlayer;
    if (controllable && p.canSeek && p.positionSupported && p.lengthSupported) {
      p.position = Math.max(0, Math.min(p.length, value));
      displayedPosition = p.position;
    }
  }
  function setVolume(value) {
    var p = selectedPlayer;
    if (controllable && p.volumeSupported) p.volume = Math.max(0, Math.min(1, value));
  }
  function capability(name) { return spotifyReady && bridge.capabilities && bridge.capabilities[name] === true; }
  function refresh() {
    localError = "";
    if (tab === "queue" && capability("queue")) bridge.request("queue", {});
    else if (tab === "playlists" && capability("playlists")) bridge.request("playlists", {});
  }
  function selectTab(value) {
    tab = value; query = ""; list.currentIndex = -1;
    refresh();
  }
  function activateItem(item) {
    if (!item || switching) return;
    if (tab === "playlists") {
      if (!capability("playlist_items")) return;
      playlistName = Model.itemTitle(item);
      tab = "tracks"; query = "";
      bridge.request("playlist_items", {uri:item.uri});
    } else playUri(item.uri);
  }
  function playUri(uri) {
    if (!capability("play") || !uri || !selectedPlayer || switching) return;
    // Do not act on unrelated browser/meeting sessions. Only explicit bindings count.
    for (var name in bindings) {
      if (name === provider) continue;
      var other = Model.boundPlayer(players, bindings[name], name);
      if (other && other.isPlaying) {
        localError = "Pause the other bound provider before starting playback.";
        return;
      }
    }
    localError = "";
    bridge.request("play", {uri:uri});
  }
  function queueUri(uri) {
    if (capability("add_to_queue") && uri) bridge.request("add_to_queue", {uri:uri});
  }
  function providerLabel(value) { return value === "spotify" ? "Spotify" : (value === "apple" ? "Apple Music" : "YouTube Music"); }

  FileView {
    id: settingsFile
    path: root.settingsPath
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try {
        var saved = JSON.parse(text());
        if (saved.schema !== 1) throw new Error("Unsupported settings schema");
        root.bindings = Model.validBindings(saved.bindings);
        if (["spotify", "apple", "youtube"].indexOf(saved.provider) !== -1) root.provider = saved.provider;
      } catch (e) { root.localError = "Music settings could not be read; session binding starts empty."; }
      root.settingsReady = true;
    }
    onLoadFailed: root.settingsReady = true
  }
  SpotifyBridge { id: bridge; active: root.isOpen }
  Connections {
    target: bridge
    function onConnectedChanged() {
      if (!bridge.connected) root.lastCapabilities = "";
      if (bridge.connected && root.isOpen && root.provider === "spotify") root.refresh();
    }
    function onCapabilitiesChanged() {
      var signature = JSON.stringify(bridge.capabilities || {});
      var changed = signature !== root.lastCapabilities;
      root.lastCapabilities = signature;
      if (changed && bridge.connected && root.isOpen && root.provider === "spotify") root.refresh();
    }
  }
  Timer {
    id: switchTimer
    interval: 100
    onTriggered: {
      var old = root.selectedPlayer;
      if (!old || !old.isPlaying) root.finishSwitch(root.pendingProvider);
      else if (++root.switchAttempts >= 20) {
        root.pendingProvider = "";
        root.localError = "The current player did not confirm pause. Provider switch cancelled.";
      } else restart();
    }
  }
  Timer {
    interval: 1000
    running: root.isOpen && !!root.selectedPlayer && root.selectedPlayer.isPlaying
    repeat: true
    onTriggered: root.displayedPosition = root.selectedPlayer ? root.selectedPlayer.position : 0
  }
  onSelectedPlayerChanged: displayedPosition = selectedPlayer && selectedPlayer.positionSupported ? selectedPlayer.position : 0

  MusicKeyboardPanel {
    id: popup
    anchorItem: root.popupAnchor
    bar: root.popupBar
    centerOnBar: true
    owner: QtObject { function close() { root.requestClose(); } }
    open: root.isOpen
    focusTarget: search
    contentWidth: fittedContentWidth(Style.space(860))
    contentHeight: cappedContentHeight(Style.space(root.showSessions ? 780 : 760))

    ColumnLayout {
      anchors.fill: parent
      spacing: Style.space(6)
      Keys.onEscapePressed: root.requestClose()
      Keys.onPressed: function(event) {
        if (event.modifiers & Qt.ControlModifier) {
          if (event.key >= Qt.Key_1 && event.key <= Qt.Key_3) {
            root.chooseProvider(["spotify", "apple", "youtube"][event.key - Qt.Key_1]);
            event.accepted = true;
          } else if (event.key === Qt.Key_Q && root.provider === "spotify") { root.selectTab("queue"); search.forceActiveFocus(); event.accepted = true; }
          else if (event.key === Qt.Key_L && root.provider === "spotify") { root.selectTab("playlists"); search.forceActiveFocus(); event.accepted = true; }
          else if (event.key === Qt.Key_F) { search.forceActiveFocus(); event.accepted = true; }
        }
      }
      RowLayout {
        Layout.fillWidth: true
        MusicText { text: "DAEMON Music"; font.pixelSize: Style.font.title; font.bold: true; Layout.fillWidth:true }
        Ui.Button { text:"Close"; focusable:true; onClicked:root.requestClose() }
      }
      RowLayout {
        Layout.fillWidth: true
        Repeater {
          model: ["spotify", "apple", "youtube"]
          Ui.Button {
            required property string modelData
            text:root.providerLabel(modelData)
            Layout.fillWidth:true
            focusable:true
            selected:root.provider === modelData
            enabled:!root.switching
            onClicked:root.chooseProvider(modelData)
          }
        }
      }
      RowLayout {
        Layout.fillWidth:true
        MusicText {
          Layout.fillWidth:true
          text:root.switching ? "Waiting for current player to pause…" : (root.selectedPlayer ? String(root.selectedPlayer.identity || root.boundKey) : (root.boundKey && Model.findPlayer(root.players, root.boundKey) ? "Bound session belongs to another service; controls disabled" : "No connected player bound"))
          elide:Text.ElideRight
        }
        Ui.Button { text:root.showSessions ? "Hide sessions" : "Bind session"; focusable:true; enabled:!root.switching; onClicked:root.showSessions = !root.showSessions }
        Ui.Button { text:"Unbind"; visible:root.boundKey !== ""; focusable:true; enabled:!root.switching; onClicked:root.unbind() }
      }
      ColumnLayout {
        visible:root.showSessions
        Layout.fillWidth:true
        MusicText {
          Layout.fillWidth:true
          wrapMode:Text.Wrap
          text:root.provider === "spotify" ? "Spotify binds only to org.mpris.MediaPlayer2.spotify." : "Choose the exact session you started. Browser identity does not prove the service; conflicting media URLs disable its controls."
          opacity:0.8
        }
        ListView {
          Layout.fillWidth:true
          Layout.preferredHeight: Math.min(Style.space(112), contentHeight)
          clip:true
          model:root.players
          spacing:Style.space(2)
          delegate: Rectangle {
            required property var modelData
            width:ListView.view.width
            height:Style.space(42)
            radius:Style.cornerRadius
            color:activeFocus ? Style.focusFillFor(Palette.Color.foreground, Palette.Color.accent) : Style.normalFillFor(Palette.Color.foreground, Palette.Color.accent)
            activeFocusOnTab:true
            Keys.onReturnPressed:root.bindSession(String(modelData.dbusName))
            Keys.onSpacePressed:root.bindSession(String(modelData.dbusName))
            Column {
              anchors.fill:parent; anchors.margins:Style.space(4)
              MusicText { width:parent.width; elide:Text.ElideRight; text:String(modelData.identity || "Player") }
              MusicText { width:parent.width; elide:Text.ElideRight; font.pixelSize:Style.font.caption; text:String(modelData.dbusName || "") }
            }
            MouseArea { anchors.fill:parent; cursorShape:Qt.PointingHandCursor; onClicked:root.bindSession(String(modelData.dbusName)) }
          }
        }
        MusicText { visible:root.players.length === 0; text:"No MPRIS players available. Open a music application first."; Layout.fillWidth:true; wrapMode:Text.Wrap }
      }
      RowLayout {
        Layout.fillWidth:true
        spacing:Style.space(12)
        Rectangle {
          Layout.preferredWidth:Style.space(48); Layout.preferredHeight:Style.space(48)
          color:Style.normalFillFor(Palette.Color.foreground, Palette.Color.accent)
          radius:Style.cornerRadius
          Image {
            anchors.fill:parent
            source:root.selectedPlayer ? Model.safeArt(root.selectedPlayer.trackArtUrl) : ""
            fillMode:Image.PreserveAspectFit
            asynchronous:true
          }
          MusicText { anchors.centerIn:parent; visible:!root.selectedPlayer || !root.selectedPlayer.trackArtUrl; text:"♪"; font.pixelSize:Style.font.title }
        }
        ColumnLayout {
          Layout.fillWidth:true
          MusicText { Layout.fillWidth:true; text:root.selectedPlayer ? String(root.selectedPlayer.trackTitle || "Nothing playing") : "Open and bind a player"; font.bold:true; elide:Text.ElideRight }
          MusicText { Layout.fillWidth:true; text:root.selectedPlayer ? String(root.selectedPlayer.trackArtist || "") : "Transport controls follow the selected session only."; elide:Text.ElideRight; opacity:0.8 }
          MusicText { Layout.fillWidth:true; text:root.selectedPlayer ? String(root.selectedPlayer.trackAlbum || "") : ""; elide:Text.ElideRight; opacity:0.65 }
        }
      }
      RowLayout {
        Layout.fillWidth:true
        Ui.Button { text:"Previous"; focusable:true; enabled:root.controllable && root.selectedPlayer.canGoPrevious; onClicked:root.transport("previous") }
        Ui.Button {
          text:root.selectedPlayer && root.selectedPlayer.isPlaying ? "Pause" : "Play"
          focusable:true
          enabled:root.controllable && (root.selectedPlayer.isPlaying ? root.selectedPlayer.canPause : root.selectedPlayer.canPlay)
          onClicked:root.transport(root.selectedPlayer.isPlaying ? "pause" : "play")
        }
        Ui.Button { text:"Next"; focusable:true; enabled:root.controllable && root.selectedPlayer.canGoNext; onClicked:root.transport("next") }
        Item { Layout.fillWidth:true }
        Ui.Button {
          text:"Shuffle"
          focusable:true
          visible:!!root.selectedPlayer && root.selectedPlayer.shuffleSupported
          enabled:root.controllable
          selected:!!root.selectedPlayer && root.selectedPlayer.shuffle
          onClicked:if (root.controllable && root.selectedPlayer.shuffleSupported) root.selectedPlayer.shuffle = !root.selectedPlayer.shuffle
        }
        Ui.Button {
          text:root.selectedPlayer && root.selectedPlayer.loopState === MprisLoopState.Track ? "Repeat track" : (root.selectedPlayer && root.selectedPlayer.loopState === MprisLoopState.Playlist ? "Repeat all" : "Repeat off")
          focusable:true
          visible:!!root.selectedPlayer && root.selectedPlayer.loopSupported
          enabled:root.controllable
          onClicked:if (root.controllable && root.selectedPlayer.loopSupported) {
            var p=root.selectedPlayer;
            p.loopState = p.loopState === MprisLoopState.None ? MprisLoopState.Playlist : (p.loopState === MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None);
          }
        }
      }
      RowLayout {
        Layout.fillWidth:true
        visible:!!root.selectedPlayer && root.selectedPlayer.positionSupported && root.selectedPlayer.lengthSupported
        MusicText { text:Model.duration(root.displayedPosition); Layout.preferredWidth:Style.space(42) }
        Ui.PanelSlider {
          Layout.fillWidth:true
          enabled:root.controllable && root.selectedPlayer.canSeek
          minimum:0; maximum:root.selectedPlayer ? Math.max(1, root.selectedPlayer.length) : 1
          value:root.displayedPosition
          trackColor:Style.normalFillFor(Palette.Color.foreground, Palette.Color.accent)
          activeFocusOnTab:true
          Keys.onLeftPressed:root.seekTo(root.displayedPosition-10)
          Keys.onRightPressed:root.seekTo(root.displayedPosition+10)
          onReleased:function(value) { root.seekTo(value); }
        }
        MusicText { text:Model.duration(root.selectedPlayer ? root.selectedPlayer.length : 0) }
      }
      RowLayout {
        Layout.fillWidth:true
        visible:!!root.selectedPlayer && root.selectedPlayer.volumeSupported
        MusicText { text:"Player volume" }
        Ui.PanelSlider {
          Layout.fillWidth:true
          enabled:root.controllable
          minimum:0; maximum:1
          value:root.selectedPlayer ? root.selectedPlayer.volume : 0
          trackColor:Style.normalFillFor(Palette.Color.foreground, Palette.Color.accent)
          activeFocusOnTab:true
          Keys.onLeftPressed:root.setVolume(value-0.05)
          Keys.onRightPressed:root.setVolume(value+0.05)
          onMoved:function(value) { root.setVolume(value); }
        }
        MusicText { text:Math.round((root.selectedPlayer ? root.selectedPlayer.volume : 0)*100)+"%" }
      }
      MusicText {
        Layout.fillWidth:true
        wrapMode:Text.Wrap
        text:root.localError || bridge.lastError
        visible:text !== ""
        color:Palette.Color.urgent
      }
      MusicText {
        Layout.fillWidth:true
        wrapMode:Text.Wrap
        text:root.provider === "spotify" ? "Spotify extension: " + bridge.connectionStatus : "Library browsing is unavailable for this provider. Use its bound playback controls above."
        opacity:0.75
      }
      RowLayout {
        Layout.fillWidth:true
        visible:root.provider === "spotify"
        Ui.Button { text:"Playlists"; focusable:true; selected:root.tab === "playlists"; enabled:root.capability("playlists"); onClicked:root.selectTab("playlists") }
        Ui.Button { text:"Queue"; focusable:true; selected:root.tab === "queue"; enabled:root.capability("queue"); onClicked:root.selectTab("queue") }
        Ui.Button { text:"Back to playlists"; focusable:true; visible:root.tab === "tracks"; enabled:root.capability("playlists"); onClicked:root.selectTab("playlists") }
        Item { Layout.fillWidth:true }
        Ui.Button { text:"Refresh"; focusable:true; enabled:root.capability(root.tab === "queue" ? "queue" : "playlists") && root.tab !== "tracks"; onClicked:root.refresh() }
      }
      MusicText { Layout.fillWidth:true; text:root.playlistName; visible:root.tab === "tracks"; elide:Text.ElideRight; font.bold:true }
      Ui.TextField {
        id:search
        Layout.fillWidth:true
        visible:root.provider === "spotify"
        placeholderText:"Filter loaded playlists or tracks…"
        text:root.query
        onTextEdited:root.query = text
        Keys.onDownPressed: { if (list.count > 0) { list.currentIndex = 0; list.forceActiveFocus(); } }
        Keys.onEscapePressed:root.requestClose()
      }
      ListView {
        id:list
        Layout.fillWidth:true
        Layout.fillHeight:true
        Layout.minimumHeight:Style.space(40)
        clip:true
        spacing:Style.space(3)
        model:root.visibleItems
        keyNavigationEnabled:true
        activeFocusOnTab:true
        Keys.onReturnPressed:if (currentIndex >= 0 && currentIndex < count) root.activateItem(root.visibleItems[currentIndex])
        Keys.onEnterPressed:if (currentIndex >= 0 && currentIndex < count) root.activateItem(root.visibleItems[currentIndex])
        Keys.onPressed:function(event) {
          if (event.key === Qt.Key_J) { incrementCurrentIndex(); event.accepted=true; }
          else if (event.key === Qt.Key_K) { decrementCurrentIndex(); event.accepted=true; }
          else if (event.key === Qt.Key_Slash) { search.forceActiveFocus(); event.accepted=true; }
          else if (event.key === Qt.Key_Q && currentIndex >= 0 && root.tab !== "playlists") { root.queueUri(root.visibleItems[currentIndex].uri); event.accepted=true; }
        }
        delegate: Rectangle {
          id:entry
          required property var modelData
          required property int index
          width:ListView.view.width
          height:Style.space(44)
          color:ListView.isCurrentItem ? Style.selectedFillFor(Palette.Color.foreground, Palette.Color.accent) : Style.normalFillFor(Palette.Color.foreground, Palette.Color.accent)
          radius:Style.cornerRadius
          RowLayout {
            anchors.fill:parent; anchors.margins:Style.space(6)
            ColumnLayout {
              Layout.fillWidth:true
              MusicText { Layout.fillWidth:true; text:Model.itemTitle(entry.modelData); elide:Text.ElideRight }
              MusicText { Layout.fillWidth:true; text:Model.itemDetail(entry.modelData); elide:Text.ElideRight; font.pixelSize:Style.font.caption; opacity:0.7 }
            }
            Ui.Button {
              text:root.tab === "playlists" ? "Open" : "Play"
              focusable:true
              enabled:root.tab === "playlists" ? root.capability("playlist_items") : root.capability("play") && !!root.selectedPlayer && !root.switching
              onClicked:root.activateItem(entry.modelData)
            }
            Ui.Button { text:"Queue"; visible:root.tab !== "playlists" && root.capability("add_to_queue"); focusable:true; onClicked:root.queueUri(entry.modelData.uri) }
          }
          TapHandler { onTapped: { list.currentIndex = entry.index; list.forceActiveFocus(); } }
        }
        MusicText {
          anchors.centerIn:parent
          width:parent.width
          horizontalAlignment:Text.AlignHCenter
          wrapMode:Text.Wrap
          visible:list.count === 0
          text:root.provider !== "spotify" ? "Playback controls only" : (!bridge.connected ? "Connect the local Spotify extension to browse playlists and queue." : "No loaded items match. Use Refresh to request data.")
          opacity:0.65
        }
      }
      MusicText { text:"Ctrl+1/2/3 provider · Ctrl+Q queue · Ctrl+L playlists · Ctrl+F filter · Enter open/play · Q add to queue · Esc close"; Layout.fillWidth:true; wrapMode:Text.Wrap; font.pixelSize:Style.font.caption; opacity:0.6 }
    }
  }
  component MusicText: Text {
    textFormat:Text.PlainText
    color:Palette.Color.foreground
    font.family:Style.font.family
    font.pixelSize:Style.font.body
  }
}
