// Pure helpers shared by the panel and Node tests. Never infer a browser's provider.
function findPlayer(players, key) {
  if (!key) return null;
  for (var i = 0; i < players.length; i++)
    if (players[i] && String(players[i].dbusName || "") === key) return players[i];
  return null;
}
function compatiblePlayer(provider, player) {
  if (!player) return false;
  if (provider === "spotify") return String(player.dbusName || "") === "org.mpris.MediaPlayer2.spotify";
  if (provider !== "apple" && provider !== "youtube") return false;
  var metadata = player.metadata || {};
  var mediaUrl = String(player.trackUrl || metadata["xesam:url"] || "").trim();
  // Missing URL is an explicit user binding, never evidence of authenticated support.
  if (!mediaUrl) return true;
  var match = mediaUrl.match(/^https?:\/\/([^\/:?#]+)(?:[\/:?#]|$)/i);
  if (!match) return false;
  var host = match[1].toLowerCase();
  if (provider === "apple") return host === "music.apple.com" || host === "beta.music.apple.com";
  return host === "music.youtube.com" || host === "www.youtube.com" || host === "youtube.com" || host === "youtu.be";
}
function boundPlayer(players, key, provider) {
  var candidate = findPlayer(players, key);
  return compatiblePlayer(provider, candidate) ? candidate : null;
}
function validBindings(input) {
  var output = {};
  ["spotify", "apple", "youtube"].forEach(function(provider) {
    var value = input && input[provider];
    if (typeof value === "string" && /^org\.mpris\.MediaPlayer2\.[A-Za-z0-9_.-]+$/.test(value) && (provider !== "spotify" || value === "org.mpris.MediaPlayer2.spotify"))
      output[provider] = value;
  });
  return output;
}
function filtered(items, query) {
  var needle = String(query || "").trim().toLowerCase();
  if (!Array.isArray(items)) return [];
  return items.filter(function(item) {
    return item && (!needle || [item.name || item.title || "", item.artist || "", item.album || ""].join(" ").toLowerCase().indexOf(needle) !== -1);
  });
}
function itemTitle(item) { return String(item && (item.title || item.name) || "Untitled"); }
function itemDetail(item) {
  if (!item) return "";
  var artist = item.artist;
  if (Array.isArray(item.artists)) artist = item.artists.map(function(a) { return typeof a === "string" ? a : a.name || ""; }).join(", ");
  return String(artist || item.description || "");
}
function duration(value) {
  var seconds = Math.max(0, Math.floor(Number(value) || 0));
  return Math.floor(seconds / 60) + ":" + (seconds % 60 < 10 ? "0" : "") + seconds % 60;
}
function safeArt(value) {
  var url = String(value || "");
  return /^https:\/\/(?:i\.scdn\.co|(?:[a-z0-9-]+\.)+mzstatic\.com|i\.ytimg\.com)\/[^\x00-\x20]*$/i.test(url) ? url : "";
}
if (typeof module !== "undefined") module.exports = {findPlayer:findPlayer, compatiblePlayer:compatiblePlayer, boundPlayer:boundPlayer, validBindings:validBindings, filtered:filtered, itemTitle:itemTitle, itemDetail:itemDetail, duration:duration, safeArt:safeArt};
