const assert = require('node:assert/strict');
const x = require('../spicetify/daemon-music.js');
const track = 'spotify:track:' + 'a'.repeat(22);
const playlist = 'spotify:playlist:' + 'b'.repeat(22);
(async () => {
  assert.equal(x.item({uri:'https://evil.invalid'}),null);
  assert.deepEqual(x.item({contextTrack:{uri:track,metadata:{title:'Track',artist_name:'Artist',access_token:'private'}}}),{uri:track,title:'Track',name:'Track',artist:'Artist'});
  assert.equal(x.items(Array.from({length:500},()=>({uri:track}))).length,200);
  assert.equal(x.playlists([{type:'folder',items:[{type:'playlist',uri:playlist,name:'Saved'}]}])[0].name,'Saved');
  const api = {Queue:{nextTracks:[{uri:track,name:'Queue'}]},Platform:{RootlistAPI:{getContents:async()=>({items:[{uri:playlist,name:'Library'}]})},PlaylistAPI:{getContents:async()=>({items:[{uri:track,name:'Item'}]})}},Player:{playUri:async(uri)=>{assert.equal(uri,track);}},addToQueue:async items=>{assert.equal(items[0].uri,track);}};
  const cmd=(op,args={})=>({op,args,expires:Date.now()+10000});
  assert.equal((await x.execute(api,cmd('queue')))[0].name,'Queue');
  assert.equal((await x.execute(api,cmd('playlists')))[0].name,'Library');
  assert.equal((await x.execute(api,cmd('playlist_items',{uri:playlist})))[0].name,'Item');
  await x.execute(api,cmd('play',{uri:track}));
  await x.execute(api,cmd('add_to_queue',{uri:track}));
  await assert.rejects(()=>x.execute(api,{op:'play',args:{uri:track},expires:0}),/expired/);
  await assert.rejects(()=>x.execute(api,cmd('execute')),/unsupported_operation/);
  await assert.rejects(()=>x.execute({},cmd('queue')),/unsupported_operation/);
  const nativeTimer=global.setTimeout;
  global.setTimeout=(fn,ms,...args)=>nativeTimer(fn,ms===10000?5:ms,...args);
  try {
    await assert.rejects(()=>x.bounded(()=>new Promise(()=>{})),/provider_timeout/);
    await assert.rejects(()=>x.bounded(()=>new Promise(()=>{}),true),/completion_uncertain/);
    assert.equal(x.capabilities(api).play,false);
    assert.equal(x.capabilities(api).add_to_queue,false);
  } finally { global.setTimeout=nativeTimer; }
  console.log('Spicetify normalization/dispatch unit checks passed; fixture APIs are NOT authenticated integration evidence.');
})();
