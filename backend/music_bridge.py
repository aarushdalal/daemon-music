#!/usr/bin/env python3
"""Panel-owned Spicetify relay. Control enters only via the parent's stdio pipe."""
import argparse
import asyncio
import contextlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import time

OPS = {'playlists', 'playlist_items', 'queue', 'play', 'add_to_queue'}
READ_OPS = {'playlists', 'playlist_items', 'queue'}
MAX_BODY = 512 * 1024
ORIGIN = 'https://xpui.app.spotify.com'
URI = re.compile(r'spotify:(track|episode|playlist|album):[A-Za-z0-9]{22}')
IDENT = re.compile(r'[A-Za-z0-9_-]{1,64}')


def normalize_items(value, kind):
    if not isinstance(value, list) or len(value) > 200:
        raise ValueError('invalid_collection')
    result = []
    for item in value:
        if not isinstance(item, dict):
            raise ValueError('invalid_item')
        uri = item.get('uri', '')
        if not isinstance(uri, str) or not URI.fullmatch(uri):
            raise ValueError('invalid_uri')
        if kind == 'playlists' and not uri.startswith('spotify:playlist:'):
            raise ValueError('invalid_playlist_uri')
        fields = {'uri': uri}
        for key in ('title', 'name', 'artist'):
            text = item.get(key, '')
            if not isinstance(text, str) or len(text) > 512:
                raise ValueError('invalid_text')
            fields[key] = text
        # Artwork is deliberately omitted; native MPRIS supplies current artwork.
        result.append(fields)
    return result


def validate_request(data):
    if not isinstance(data, dict) or not isinstance(data.get('id'), str) or not IDENT.fullmatch(data['id']):
        raise ValueError('invalid_request_id')
    op = data.get('op')
    if not isinstance(op, str) or (op not in OPS and op != 'status'):
        raise ValueError('unsupported_operation')
    if op != 'status':
        expiry = data.get('expires')
        if type(expiry) not in (int, float) or not time.time()*1000 < expiry <= time.time()*1000+16000:
            raise ValueError('expired_or_invalid_deadline')
    args = data.get('args', {})
    if not isinstance(args, dict) or set(args) - {'uri'}:
        raise ValueError('invalid_arguments')
    if op in {'playlist_items', 'play', 'add_to_queue'}:
        uri = args.get('uri')
        if not isinstance(uri, str) or not URI.fullmatch(uri):
            raise ValueError('invalid_uri')
        if op == 'playlist_items' and not uri.startswith('spotify:playlist:'):
            raise ValueError('invalid_playlist_uri')
        if op == 'add_to_queue' and not uri.startswith(('spotify:track:', 'spotify:episode:')):
            raise ValueError('invalid_queue_uri')
    elif args:
        raise ValueError('unexpected_arguments')
    return data['id'], op, args


class Relay:
    def __init__(self, key, port, emit=None):
        self.key = key
        self.port = port
        self.emit = emit or self.stdout
        self.session = ''
        self.last_seen = 0
        self.capabilities = {}
        self.commands = asyncio.Queue(maxsize=16)
        self.pending = {}
        self.connections = 0
        self.polling = False
        self.was_connected = False

    @staticmethod
    def stdout(value):
        sys.stdout.write(json.dumps(value, separators=(',', ':'), ensure_ascii=False) + '\n')
        sys.stdout.flush()

    def connected(self):
        return bool(self.session) and time.monotonic() - self.last_seen < 35

    def state(self):
        return {'event': 'status', 'connected': self.connected(),
                'connectionStatus': 'connected' if self.connected() else 'Spotify extension not connected',
                'capabilities': self.capabilities if self.connected() else {}}

    async def rpc(self, data):
        request_id = data.get('id', '') if isinstance(data, dict) else ''
        try:
            request_id, op, args = validate_request(data)
            if op == 'status':
                return {'id': request_id, 'ok': True, 'result': self.state()}
            if not self.connected():
                raise ValueError('extension_unavailable')
            if self.capabilities.get(op) is not True:
                raise ValueError('unsupported_operation')
            if len(self.pending) >= 16:
                raise ValueError('busy')
            command_id = secrets.token_hex(16)
            future = asyncio.get_running_loop().create_future()
            self.pending[command_id] = (op, future, self.session)
            command = {'id': command_id, 'op': op, 'args': args, 'expires': min(data['expires'], int(time.time() * 1000) + 12000)}
            try:
                self.commands.put_nowait(command)
                result = await asyncio.wait_for(future, min(13, max(.001, (data['expires']-time.time()*1000)/1000)))
            finally:
                self.pending.pop(command_id, None)
            return {'id': request_id, 'ok': True, 'op': op, 'result': result}
        except (ValueError, asyncio.TimeoutError, asyncio.QueueFull) as error:
            code = str(error) if isinstance(error, ValueError) else 'provider_timeout_or_busy'
            return {'id': request_id[:64] if isinstance(request_id, str) else '', 'ok': False, 'error': code}

    async def route(self, method, path, headers, body):
        if headers.get('host') != f'127.0.0.1:{self.port}' or headers.get('origin') != ORIGIN:
            return 403, {'error': 'origin_or_host_rejected'}
        if method == 'OPTIONS':
            if headers.get('access-control-request-method') not in ('GET', 'POST'):
                return 403, {'error': 'method_rejected'}
            requested = {s.strip().lower() for s in headers.get('access-control-request-headers', '').split(',') if s.strip()}
            if requested - {'content-type', 'x-daemon-music-key', 'x-daemon-music-session'}:
                return 403, {'error': 'headers_rejected'}
            return 204, {}
        if not hmac.compare_digest(headers.get('x-daemon-music-key', ''), self.key):
            return 403, {'error': 'authentication_required'}
        if method == 'POST' and not headers.get('content-type', '').startswith('application/json'):
            return 415, {'error': 'json_required'}
        if path == '/hello' and method == 'POST':
            try:
                data = json.loads(body)
                session = data['session']
                caps = data['capabilities']
                if data.get('protocol') != 1 or not isinstance(session, str) or not IDENT.fullmatch(session):
                    raise ValueError()
                if not isinstance(caps, dict) or set(caps) - OPS or any(type(v) is not bool for v in caps.values()):
                    raise ValueError()
            except (ValueError, KeyError, TypeError):
                return 400, {'error': 'invalid_hello'}
            if self.session and self.session != session:
                for _, future, _ in self.pending.values():
                    if not future.done():future.set_exception(ValueError('extension_reconnected'))
            self.session = session
            self.capabilities = caps
            self.last_seen = time.monotonic()
            self.emit(self.state())
            return 200, {'protocol': 1}
        if headers.get('x-daemon-music-session') != self.session or not self.session:
            return 403, {'error': 'session_rejected'}
        self.last_seen = time.monotonic()
        if path == '/commands' and method == 'GET':
            if self.polling:
                return 409, {'error': 'poll_already_active'}
            self.polling = True
            poll_session = self.session
            try:
                deadline = time.monotonic() + 20
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:return 200, {'command': None}
                    try:command = await asyncio.wait_for(self.commands.get(), remaining)
                    except asyncio.TimeoutError:return 200, {'command': None}
                    if self.session != poll_session:
                        self.commands.put_nowait(command)
                        return 409, {'error': 'session_changed'}
                    pending = self.pending.get(command['id'])
                    if pending and pending[2] == self.session and not pending[1].done():
                        return 200, {'command': command}
            finally:
                self.polling = False
        if path == '/result' and method == 'POST':
            try:
                data = json.loads(body)
                if not isinstance(data, dict):raise ValueError('invalid_result')
                identifier = data.get('id')
                pending = self.pending.get(identifier)
                if pending is None or pending[2] != self.session or pending[1].done():
                    return 409, {'error': 'unknown_or_completed_request'}
                op, future, _ = pending
                if data.get('ok') is not True:
                    code = data.get('error')
                    if code not in ('unsupported_operation', 'provider_unavailable', 'provider_error', 'invalid_result', 'expired', 'rate_limited', 'completion_uncertain', 'provider_timeout'):
                        code = 'provider_error'
                    future.set_exception(ValueError(code))
                else:
                    result = normalize_items(data.get('result'), op) if op in READ_OPS else {'accepted': True}
                    future.set_result(result)
            except (ValueError, TypeError, KeyError):
                return 400, {'error': 'invalid_result'}
            return 200, {'accepted': True}
        return 404, {'error': 'not_found'}

    async def http(self, reader, writer):
        if self.connections >= 8:
            writer.close()
            return
        self.connections += 1
        cors = False
        try:
            header = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 4)
            if len(header) > 8192:raise ValueError('headers_too_large')
            lines = header.decode('ascii').split('\r\n')
            method, path, version = lines[0].split(' ')
            if version != 'HTTP/1.1' or path not in ('/hello', '/commands', '/result'):
                raise ValueError('invalid_request')
            headers = {}
            for line in lines[1:]:
                if not line:continue
                key, value = line.split(':', 1)
                key = key.strip().lower()
                if key in headers:raise ValueError('duplicate_header')
                headers[key] = value.strip()
            if 'transfer-encoding' in headers:raise ValueError('chunked_unsupported')
            raw = headers.get('content-length', '0')
            if not re.fullmatch(r'[0-9]{1,7}', raw) or int(raw) > MAX_BODY:
                raise ValueError('invalid_length')
            body = await asyncio.wait_for(reader.readexactly(int(raw)), 4)
            cors = headers.get('origin') == ORIGIN and headers.get('host') == f'127.0.0.1:{self.port}'
            status, result = await self.route(method, path, headers, body)
        except (ValueError, UnicodeError, asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            status, result = 400, {'error': 'invalid_http_request'}
        try:
            encoded = json.dumps(result, separators=(',', ':')).encode()
            extra = f'Access-Control-Allow-Origin: {ORIGIN}\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, X-Daemon-Music-Key, X-Daemon-Music-Session\r\nAccess-Control-Allow-Private-Network: true\r\nAccess-Control-Max-Age: 600\r\nVary: Origin\r\n' if cors else ''
            writer.write(f'HTTP/1.1 {status} Response\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: {len(encoded)}\r\n{extra}\r\n'.encode() + encoded)
            await asyncio.wait_for(writer.drain(), 3)
        except (OSError, asyncio.TimeoutError):pass
        finally:
            writer.close()
            with contextlib.suppress(OSError):await writer.wait_closed()
            self.connections -= 1

    async def stdin(self):
        reader = asyncio.StreamReader(limit=4096)
        protocol = asyncio.StreamReaderProtocol(reader)
        await asyncio.get_running_loop().connect_read_pipe(lambda: protocol, sys.stdin.buffer)
        while True:
            try:line = await reader.readline()
            except ValueError:break
            if not line:break
            try:data = json.loads(line)
            except ValueError:
                self.emit({'ok': False, 'error': 'invalid_json'})
                continue
            self.emit(await self.rpc(data))

    async def monitor(self):
        while True:
            await asyncio.sleep(2)
            now = self.connected()
            if now != self.was_connected:
                self.was_connected = now
                self.emit(self.state())


def private_key(state_dir, initialize=False):
    if state_dir.is_symlink():raise ValueError('unsafe_state_directory')
    if initialize:state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = state_dir.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError('state_directory_not_private')
    path = state_dir/'pairing.key'
    if initialize and not path.exists():
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w') as stream:stream.write(secrets.token_hex(32))
    if path.is_symlink():raise ValueError('unsafe_key_file')
    info = path.stat()
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError('key_not_private')
    key = path.read_text().strip()
    if not re.fullmatch(r'[a-f0-9]{64}', key):raise ValueError('invalid_key')
    return key


async def main_async(args):
    try:key = private_key(args.state_dir)
    except (OSError, ValueError):
        Relay.stdout({'event':'status','connected':False,'connectionStatus':'Spotify extension setup required','capabilities':{}})
        return
    relay = Relay(key, args.port)
    try:server = await asyncio.start_server(relay.http, '127.0.0.1', args.port, limit=8192)
    except OSError:
        Relay.stdout({'event':'status','connected':False,'connectionStatus':'Music relay port unavailable','capabilities':{}})
        return
    relay.emit(relay.state())
    monitor = asyncio.create_task(relay.monitor())
    try:
        async with server:await relay.stdin()
    finally:
        monitor.cancel()
        with contextlib.suppress(asyncio.CancelledError):await monitor


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8975)
    parser.add_argument('--state-dir', type=Path, default=Path.home()/'.local/state/daemon-music')
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:raise SystemExit('Invalid local port')
    try:asyncio.run(main_async(args))
    except (BrokenPipeError, KeyboardInterrupt):pass
