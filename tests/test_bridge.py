import asyncio
import importlib.util
import json
from pathlib import Path
import tempfile
import time
import unittest
import io
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('music_bridge', ROOT/'backend/music_bridge.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
TRACK = 'spotify:track:' + 'a'*22
PLAYLIST = 'spotify:playlist:' + 'b'*22


class BoundaryTests(unittest.TestCase):
    def test_request_allowlist_and_no_arbitrary_urls(self):
        self.assertEqual(m.validate_request({'id':'1','op':'play','args':{'uri':TRACK},'expires':time.time()*1000+10000})[1], 'play')
        for data in [[], {'id':'1','op':'execute'}, {'id':'1','op':'play','args':{'uri':'https://evil.invalid/'}}, {'id':'1','op':'playlist_items','args':{'uri':TRACK}}, {'id':'1','op':'queue','args':{'command':'sh'}}]:
            with self.assertRaises(ValueError):m.validate_request(data)

    def test_result_whitelist_and_bounding(self):
        result=m.normalize_items([{'uri':TRACK,'title':'<img src="https://evil.invalid">','token':'never forwarded'}], 'queue')
        self.assertNotIn('token',result[0])
        self.assertEqual(result[0]['title'],'<img src="https://evil.invalid">')
        for value in [[{'uri':TRACK,'title':'x'*513}], [{'uri':'file:///etc/passwd'}], [{}]*201, {'items':[]}]:
            with self.assertRaises(ValueError):m.normalize_items(value,'queue')

    def test_deadlines_and_malformed_operation_types(self):
        for op in ([], {}, None, 4):
            with self.assertRaises(ValueError):m.validate_request({'id':'1','op':op})
        for expiry in (0, time.time()*1000-1, time.time()*1000+60000, float('nan')):
            with self.assertRaises(ValueError):m.validate_request({'id':'1','op':'queue','expires':expiry})

    def test_unicode_stdout_within_qml_line_bound(self):
        items=m.normalize_items([{'uri':TRACK,'name':'界'*512,'title':'界'*512,'artist':'界'*512} for _ in range(100)],'queue')
        out=io.StringIO()
        with patch.object(m.sys,'stdout',out):m.Relay.stdout({'id':'1','ok':True,'result':items})
        self.assertLess(len(out.getvalue()),524288)
        self.assertNotIn('\\u754c',out.getvalue())

    def test_pairing_file_permissions(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/'state'
            key=m.private_key(path,initialize=True)
            self.assertEqual(len(key),64)
            self.assertEqual(path.stat().st_mode & 0o777,0o700)
            (path/'pairing.key').chmod(0o644)
            with self.assertRaises(ValueError):m.private_key(path)


class RelayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.events=[]
        self.relay=m.Relay('a'*64,8975,self.events.append)
        self.headers={'host':'127.0.0.1:8975','origin':m.ORIGIN,'x-daemon-music-key':'a'*64,'content-type':'application/json','x-daemon-music-session':'session1'}

    async def hello(self):
        return await self.relay.route('POST','/hello',self.headers,json.dumps({'protocol':1,'session':'session1','capabilities':{op:True for op in m.OPS}}))

    async def test_auth_origin_host_and_session_fail_closed(self):
        for field,value in [('origin','https://evil.invalid'),('origin','null'),('host','evil.invalid:8975'),('x-daemon-music-key','wrong')]:
            status,_=await self.relay.route('POST','/hello',dict(self.headers,**{field:value}),'{}')
            self.assertEqual(status,403)
        status,_=await self.hello();self.assertEqual(status,200)
        status,_=await self.relay.route('GET','/commands',dict(self.headers,**{'x-daemon-music-session':'wrong'}),'')
        self.assertEqual(status,403)

    async def test_roundtrip_exact_pending_id_and_duplicate_reply(self):
        await self.hello()
        pending=asyncio.create_task(self.relay.rpc({'id':'ui1','op':'queue','args':{},'expires':time.time()*1000+10000}))
        await asyncio.sleep(0)
        status,response=await self.relay.route('GET','/commands',self.headers,'')
        self.assertEqual(status,200)
        command=response['command']
        status,_=await self.relay.route('POST','/result',self.headers,json.dumps({'id':'unknown','ok':True,'result':[]}))
        self.assertEqual(status,409)
        body=json.dumps({'id':command['id'],'ok':True,'result':[{'uri':TRACK,'name':'Actual response fixture','accessToken':'must disappear'}]})
        status,_=await self.relay.route('POST','/result',self.headers,body)
        self.assertEqual(status,200)
        result=await pending
        self.assertTrue(result['ok'])
        self.assertNotIn('accessToken',result['result'][0])
        status,_=await self.relay.route('POST','/result',self.headers,body)
        self.assertEqual(status,409)

    async def test_disconnected_and_unsupported_are_real_failures(self):
        result=await self.relay.rpc({'id':'1','op':'queue','expires':time.time()*1000+10000})
        self.assertEqual(result['error'],'extension_unavailable')
        await self.hello();self.relay.capabilities['queue']=False
        result=await self.relay.rpc({'id':'2','op':'queue','expires':time.time()*1000+10000})
        self.assertEqual(result['error'],'unsupported_operation')

    async def test_malformed_result_and_private_error_redaction(self):
        await self.hello()
        status,_=await self.relay.route('POST','/result',self.headers,'[]')
        self.assertEqual(status,400)
        pending=asyncio.create_task(self.relay.rpc({'id':'3','op':'play','args':{'uri':TRACK},'expires':time.time()*1000+10000}))
        await asyncio.sleep(0)
        _,response=await self.relay.route('GET','/commands',self.headers,'')
        await self.relay.route('POST','/result',self.headers,json.dumps({'id':response['command']['id'],'ok':False,'error':'token=private'}))
        self.assertEqual((await pending)['error'],'provider_error')

    async def test_real_http_rejects_ambiguous_framing_and_no_cors_leak(self):
        server=await asyncio.start_server(self.relay.http,'127.0.0.1',0,limit=8192)
        self.relay.port=server.sockets[0].getsockname()[1]
        try:
            requests=[b'POST /hello HTTP/1.1\r\nContent-Length: -1\r\n\r\n', b'POST /hello HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n', b'POST /hello HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n']
            for request in requests:
                reader,writer=await asyncio.open_connection('127.0.0.1',self.relay.port)
                writer.write(request);await writer.drain()
                data=await asyncio.wait_for(reader.read(),3)
                self.assertIn(b'400',data)
                self.assertNotIn(b'Access-Control-Allow-Origin',data)
                writer.close();await writer.wait_closed()
        finally:
            server.close();await server.wait_closed()


if __name__=='__main__':unittest.main()
