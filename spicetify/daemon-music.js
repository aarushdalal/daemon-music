/* DAEMON Music: supported Spicetify wrapper calls, private local relay only. */
(function () {
  "use strict";
  const LIMIT = 200;
  const URI = /^spotify:(track|episode|playlist|album):[A-Za-z0-9]{22}$/;
  let uncertainMutation = false;
  let outstandingReads = 0;
  const OPS = new Set(["playlists", "playlist_items", "queue", "play", "add_to_queue"]);

  function text(value) { return String(value || "").slice(0, 512); }
  function item(raw) {
    const source = raw?.contextTrack || raw;
    const meta = source?.metadata || raw?.metadata || {};
    const uri = source?.uri || raw?.uri || raw?.link;
    if (typeof uri !== "string" || !URI.test(uri)) return null;
    const artists = raw?.artists || source?.artists;
    return {
      uri, name: text(raw?.name || meta.title || source?.name),
      title: text(raw?.name || meta.title || source?.name),
      artist: text(Array.isArray(artists) ? artists.map(a => typeof a === "string" ? a : a.name).join(", ") : meta.artist_name || raw?.artist)
    };
  }
  function items(raw) {
    if (!Array.isArray(raw)) throw new Error("invalid_result");
    return raw.slice(0, LIMIT).map(item).filter(Boolean);
  }
  function playlists(raw) {
    const output = [], todo = Array.isArray(raw) ? raw.slice(0, 1000) : [];
    let inspected = 0;
    while (todo.length && output.length < LIMIT && ++inspected <= 2000) {
      const row = todo.shift();
      if (row?.type === "folder" && Array.isArray(row.items)) todo.push(...row.items.slice(0, 1000));
      else {
        const value = item(row);
        if (value && value.uri.startsWith("spotify:playlist:")) output.push(value);
      }
    }
    return output;
  }
  function capabilities(api) {
    return {
      playlists: typeof api?.Platform?.RootlistAPI?.getContents === "function",
      playlist_items: typeof api?.Platform?.PlaylistAPI?.getContents === "function",
      queue: Array.isArray(api?.Queue?.nextTracks),
      play: !uncertainMutation && typeof api?.Player?.playUri === "function",
      add_to_queue: !uncertainMutation && typeof api?.addToQueue === "function"
    };
  }
  async function bounded(call, mutation=false) {
    if (!mutation && outstandingReads >= 4) throw new Error("provider_unavailable");
    if (!mutation) outstandingReads++;
    let timer, settled=false;
    const work=Promise.resolve().then(call);
    work.then(()=>{settled=true; if (!mutation) outstandingReads--;},()=>{settled=true; if (!mutation) outstandingReads--;});
    const timeout=new Promise((resolve,reject)=>{
      timer=setTimeout(()=>{
        if (mutation && !settled) uncertainMutation=true;
        reject(new Error(mutation ? "completion_uncertain" : "provider_timeout"));
      },10000);
    });
    try { return await Promise.race([work,timeout]); }
    finally { clearTimeout(timer); }
  }
  async function execute(api, command) {
    if (!command || !OPS.has(command.op)) throw new Error("unsupported_operation");
    if (!Number.isFinite(command.expires) || command.expires < Date.now()) throw new Error("expired");
    if (capabilities(api)[command.op] !== true) throw new Error("unsupported_operation");
    const uri = command.args?.uri;
    if (["playlist_items", "play", "add_to_queue"].includes(command.op) && (typeof uri !== "string" || !URI.test(uri))) throw new Error("invalid_result");
    if (command.op === "playlists") {
      const value = await bounded(()=>api.Platform.RootlistAPI.getContents({limit:LIMIT}));
      return playlists(value.items);
    }
    if (command.op === "playlist_items") {
      if (!uri.startsWith("spotify:playlist:")) throw new Error("invalid_result");
      const value = await bounded(()=>api.Platform.PlaylistAPI.getContents(uri, {offset:0, limit:LIMIT}));
      return items(value.items);
    }
    if (command.op === "queue") return items(api.Queue.nextTracks);
    if (command.op === "play") { await bounded(()=>api.Player.playUri(uri),true); return {accepted:true}; }
    if (!/^spotify:(track|episode):/.test(uri)) throw new Error("invalid_result");
    await bounded(()=>api.addToQueue([{uri}]),true);
    return {accepted:true};
  }
  const exported = {item, items, playlists, capabilities, execute, bounded};
  if (typeof module !== "undefined" && module.exports) { module.exports = exported; return; }

  let runtimeRetries = 0;
  function registerMarketplace() {
    try {
      const listKey = "marketplace:installed-extensions";
      const itemKey = "marketplace:installed:aarushdalal/daemon-music/daemon-music.js";
      const manifest = {
        name: "DAEMON Music",
        description: "Explicitly bound MPRIS playback with capability-aware Spotify library and queue integration",
        main: "daemon-music.js",
        authors: [{ name: "Daemon0", url: "https://github.com/aarushdalal" }]
      };
      const itemData = JSON.stringify({
        manifest,
        type: "extension",
        title: "DAEMON Music",
        subtitle: "Explicitly bound MPRIS playback with capability-aware Spotify library and queue integration",
        authors: [{ name: "Daemon0", url: "https://github.com/aarushdalal" }],
        user: "aarushdalal",
        repo: "daemon-music",
        branch: "main",
        imageURL: "https://raw.githubusercontent.com/aarushdalal/daemon-music/main/assets/showcase.svg",
        extensionURL: "https://raw.githubusercontent.com/aarushdalal/daemon-music/main/spicetify/daemon-music.js",
        readmeURL: "https://raw.githubusercontent.com/aarushdalal/daemon-music/main/README.md",
        lastUpdated: new Date().toISOString()
      });

      try {
        let list = [];
        try { list = JSON.parse(globalThis.localStorage?.getItem(listKey) || "[]"); } catch {}
        if (!Array.isArray(list)) list = [];
        if (!list.includes(itemKey)) list.push(itemKey);
        globalThis.localStorage?.setItem(listKey, JSON.stringify(list));
        globalThis.localStorage?.setItem(itemKey, itemData);
      } catch (e) {}

      if (globalThis.indexedDB) {
        const req = indexedDB.open("spicetify-marketplace");
        req.onsuccess = function (e) {
          const db = e.target.result;
          if (!db.objectStoreNames.contains("settings")) return;
          const tx = db.transaction(["settings"], "readwrite");
          const store = tx.objectStore("settings");
          const getReq = store.get(listKey);
          getReq.onsuccess = function () {
            let list = [];
            try { list = JSON.parse(getReq.result?.value || "[]"); } catch {}
            if (!Array.isArray(list)) list = [];
            if (!list.includes(itemKey)) list.push(itemKey);
            store.put({ key: listKey, value: JSON.stringify(list) });
            store.put({ key: itemKey, value: itemData });
          };
        };
      }
    } catch (err) {}
  }

  function startRuntime() {
  registerMarketplace();
  const settings = globalThis.__DaemonMusicSession;
  if (!settings) { if (++runtimeRetries <= 120) setTimeout(startRuntime, 500); return; }
  if (settings.base !== "http://127.0.0.1:8975" || !/^[a-f0-9]{64}$/.test(settings.key)) return;
  if (globalThis.__DaemonMusicRunning) return;
  globalThis.__DaemonMusicRunning = true;
  const session = crypto.randomUUID().replaceAll("-", "");
  let stopped = false;
  globalThis.addEventListener("pagehide", () => { stopped = true; });
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  async function request(path, body) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 26000);
    try {
      const response = await fetch(settings.base + path, {
        method: body === undefined ? "GET" : "POST",
        headers: {"Content-Type":"application/json", "X-Daemon-Music-Key":settings.key, "X-Daemon-Music-Session":session},
        body: body === undefined ? undefined : JSON.stringify(body), signal:controller.signal,
        cache:"no-store", credentials:"omit", redirect:"error", referrerPolicy:"no-referrer"
      });
      if (!response.ok) throw new Error("relay_unavailable");
      const raw = await response.text();
      if (raw.length > 16384) throw new Error("invalid_result");
      return JSON.parse(raw);
    } finally { clearTimeout(timer); }
  }
  (async function loop() {
    let delay = 1000;
    while (!stopped) {
      try {
        if (!globalThis.Spicetify?.Player || !globalThis.Spicetify?.Platform) { await wait(1000); continue; }
        await request("/hello", {protocol:1, session, capabilities:capabilities(Spicetify)});
        delay = 1000;
        let previousCaps = JSON.stringify(capabilities(Spicetify));
        while (!stopped) {
          const nextCaps = JSON.stringify(capabilities(Spicetify));
          if (nextCaps !== previousCaps) {
            await request("/hello", {protocol:1,session,capabilities:capabilities(Spicetify)});
            previousCaps = nextCaps;
          }
          const {command} = await request("/commands");
          if (!command) continue;
          let reply;
          try { reply = {id:command.id, ok:true, result:await execute(Spicetify, command)}; }
          catch (error) {
            // Never forward raw provider exception messages (may contain session data).
            const allowed = ["unsupported_operation", "invalid_result", "expired", "completion_uncertain", "provider_timeout", "provider_unavailable"];
            reply = {id:command.id, ok:false, error:allowed.includes(error?.message) ? error.message : "provider_error"};
          }
          await request("/result", reply);
        }
      } catch (error) {
        await wait(delay);
        delay = Math.min(2000, delay * 2);
      }
    }
  })();
  }
  startRuntime();
})();
