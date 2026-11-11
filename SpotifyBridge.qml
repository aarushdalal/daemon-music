import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  property bool active: false
  property bool connected: false
  property string connectionStatus: "Spotify extension not connected"
  property string lastError: ""
  property var capabilities: ({})
  property var playlists: []
  property var playlistItems: []
  property var queue: []
  property int serial: 0
  property var pending: ({})
  property var latest: ({})
  readonly property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("backend/music_bridge.py")).replace(/^file:\/\//, ""))
  readonly property string stateDirectory: Quickshell.env("DAEMON_MUSIC_STATE_DIR") || Quickshell.env("HOME") + "/.local/state/daemon-music"

  function reset() {
    connected = false;
    capabilities = ({});
    pending = ({}); latest = ({});
    playlists = []; playlistItems = []; queue = [];
  }
  function request(operation, argumentsObject) {
    if (!active || !worker.running || !connected || capabilities[operation] !== true) {
      lastError = "Spotify capability unavailable: " + operation;
      return "";
    }
    if (Object.keys(pending).length >= 8) { lastError = "Music relay busy; wait for pending requests."; return ""; }
    var identifier = String(++serial);
    var next = Object.assign({}, pending);
    next[identifier] = {op:operation, started:Date.now()};
    var last = Object.assign({}, latest); last[operation] = identifier; latest = last;
    if (operation === "playlist_items") playlistItems = [];
    pending = next;
    worker.write(JSON.stringify({id:identifier, op:operation, args:argumentsObject || {}, expires:Date.now()+15000}) + "\n");
    return identifier;
  }
  function receive(line) {
    if (line.length > 524288) { pending = ({}); lastError = "Music relay response exceeded its limit."; return; }
    try {
      var value = JSON.parse(line);
      if (value.event === "status") {
        connected = value.connected === true;
        connectionStatus = String(value.connectionStatus || "Unavailable").slice(0, 160);
        capabilities = connected && value.capabilities && typeof value.capabilities === "object" ? value.capabilities : ({});
        if (!connected) { playlists=[]; playlistItems=[]; queue=[]; }
        return;
      }
      var entry = pending[String(value.id)];
      if (!entry) return;
      var operation = entry.op;
      var next = Object.assign({}, pending); delete next[String(value.id)]; pending = next;
      if (["playlists","playlist_items","queue"].indexOf(operation) !== -1 && latest[operation] !== String(value.id)) return;
      if (value.ok !== true) { lastError = value.error === "completion_uncertain" ? "Spotify did not confirm this change. Check Spotify before trying again." : (value.error === "unsupported_operation" ? "This Spotify version does not support that action." : (value.error === "expired_or_invalid_deadline" ? "This request expired before it could run. Try again." : "Spotify could not confirm this request. Try refreshing later.")); return; }
      lastError = "";
      if (operation === "playlists") playlists = value.result;
      else if (operation === "playlist_items") playlistItems = value.result;
      else if (operation === "queue") queue = value.result;
    } catch (error) { lastError = "Invalid music relay response."; }
  }
  onActiveChanged: {
    reset();
    connectionStatus = active ? "Connecting Spotify extension…" : "Panel closed";
    lastError = "";
  }
  Timer {
    interval: 1000; repeat: true
    running: root.active && Object.keys(root.pending).length > 0
    onTriggered: {
      var next = Object.assign({}, root.pending), expired = false;
      for (var key in next) if (Date.now()-next[key].started > 18000) { delete next[key]; expired=true; }
      if (expired) { root.pending=next; root.lastError="Spotify request timed out; playback changes may require checking the app."; }
    }
  }
  Process {
    id: worker
    command: ["/usr/bin/python3", root.scriptPath, "--state-dir", root.stateDirectory]
    running: root.active
    stdinEnabled: true
    stdout: SplitParser { onRead: function(line) { root.receive(String(line)); } }
    // Do not bind raw provider error output or process environment into UI/logs.
    onExited: function(exitCode, exitStatus) {
      root.reset();
      if (root.active && exitCode !== 0) root.connectionStatus = "Music relay stopped; close and reopen to retry.";
    }
  }
}
