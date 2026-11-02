"""Same-origin HTTP + WS NAS fixture; all credentials and media are synthetic."""
import asyncio, base64, hashlib, hmac, json, threading, time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, urlsplit
from Crypto.Cipher import AES, PKCS1_v1_5
from Crypto.Util.Padding import pad, unpad
from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed
from protocol_reference import photo_authx


def run_renewal(test, scenario):
    secret = b'fixture-renewal-secret-32-bytes!!'
    state = {'short': 'initial-token', 'long': 'long-0', 'renewals': 0, 'auths': 0, 'requests': []}
    errors = []
    lock = threading.Lock()

    class HTTP(BaseHTTPRequestHandler):
        def log_message(self, *args): pass

        def handle_request(self):
            try:
                raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
                path = urlsplit(self.path).path
                token = self.headers.get('accessToken')
                assert self.headers.get('Authorization') == token
                assert self.headers.get('Cookie') == 'mode=relay;fnos-token=' + token
                auth = dict(parse_qsl(self.headers['authx']))
                if self.command == 'GET':
                    assert self.headers['authx'] == photo_authx(
                        'http://' + self.headers['Host'] + self.path,
                        nonce=auth['nonce'], timestamp=auth['timestamp'])
                else:
                    assert path == '/p/api/v1/gallery/batchGetByIds' and json.loads(raw) == {'ids': [77]}
                    digest = hashlib.md5(raw).hexdigest()
                    expected = hashlib.md5(f"NDzZTVxnRKP8Z0jXg1VAMonaG8akvh_{self.path}_{auth['nonce']}_{auth['timestamp']}_{digest}_EAECCF25-80A6-4666-A7C2-A76904A74AB6".encode()).hexdigest()
                    assert auth['sign'] == expected
                with lock:
                    state['requests'].append((path, token))
                    valid = token == state['short'] and token != 'initial-token'
                if path == '/fixture/late' and not valid: time.sleep(.5)
                if not valid or scenario == 'repeated':
                    status, body = 401, b'expired'
                elif path == '/fixture/image': status, body = 200, b'fixture image'
                elif path in ('/fixture/video', '/fixture/cancel'): status, body = 200, b'x' * 65536
                else:
                    status, body = 200, json.dumps({'code': 0, 'data': {'ok': True, 'list': [{'id': 77}]}}).encode()
                self.send_response(status)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                if path == '/fixture/video' and status == 200:
                    for offset in range(0, len(body), 4096):
                        self.wfile.write(body[offset:offset+4096]); self.wfile.flush(); time.sleep(.03)
                else: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass  # A cancelled logical transfer.
            except Exception as error:
                errors.append(repr(error)); self.send_response(500); self.end_headers()

        do_GET = handle_request
        do_POST = handle_request

    http = ThreadingHTTPServer(('127.0.0.1', 0), HTTP)
    threading.Thread(target=http.serve_forever, daemon=True).start()

    async def websocket(ws):
        try:
            async for wire in ws:
                signed = not wire.startswith('{')
                if signed:
                    assert wire[:44] == base64.b64encode(hmac.new(secret, wire[44:].encode(), hashlib.sha256).digest()).decode()
                    wire = wire[44:]
                request = json.loads(wire)
                if request.get('req') == 'encrypted':
                    key = PKCS1_v1_5.new(test.rsa).decrypt(base64.b64decode(request['rsa']), None)
                    iv = base64.b64decode(request['iv'])
                    request = json.loads(unpad(AES.new(key, AES.MODE_CBC, iv).decrypt(base64.b64decode(request['aes'])), 16))
                    assert request['req'] == 'user.login'
                    user = request['user']
                    assert (user, request['password']) in [('fixture-user', 'fixture-password'), ('fixture-other', 'other-password')]
                    if user == 'fixture-other': state.update(short='other-token', long='other-long')
                    response = {'result': 'succ', 'token': state['short'], 'longToken': state['long'],
                                'secret': base64.b64encode(AES.new(key, AES.MODE_CBC, iv).encrypt(pad(secret, 16))).decode()}
                elif request['req'] == 'util.crypto.getRSAPub':
                    response = {'pub': test.rsa.public_key().export_key().decode(), 'si': 'renew-si'}
                elif request['req'] == 'user.authToken':
                    assert signed
                    state['auths'] += 1
                    response = {'result': 'succ'} if request['token'] == state['short'] and state['short'] != 'initial-token' else {'result': 'fail', 'errno': 135168}
                else:
                    assert signed and request['req'] == 'user.tokenLogin' and request['token'] == state['long']
                    state['renewals'] += 1
                    count = state['renewals']
                    await asyncio.sleep(.6 if scenario in ('logout', 'switch') else .15)
                    if scenario == 'offline' and count == 1:
                        await ws.close(); continue
                    if scenario == 'terminal': response = {'result': 'fail', 'errno': 135168}
                    elif scenario == 'busy' and count == 1: response = {'result': 'fail', 'errno': 999}
                    elif scenario == 'malformed' and count == 1: response = {'result': 'succ', 'token': None}
                    else:
                        # A closed old socket may still finish its server-side renewal.
                        if scenario not in ('logout', 'switch'):
                            state.update(short='fresh-token', long='long-rotated')
                        response = {'result': 'succ', 'token': 'fresh-token', 'longToken': 'long-rotated'}
                response['reqid'] = request['reqid']
                await ws.send(json.dumps(response))
        except ConnectionClosed: pass
        except Exception as error: errors.append(repr(error))

    async def run():
        async with serve(websocket, '127.0.0.1', 0) as ws_server:
            ws_port = ws_server.sockets[0].getsockname()[1]

            async def proxy(reader, writer):
                upstream = None
                try:
                    header = await reader.readuntil(b'\r\n\r\n')
                    port = ws_port if b' /websocket?' in header.split(b'\r\n', 1)[0] else http.server_port
                    remote, upstream = await asyncio.open_connection('127.0.0.1', port)
                    upstream.write(header); await upstream.drain()

                    async def pipe(source, destination):
                        try:
                            while data := await source.read(65536):
                                destination.write(data); await destination.drain()
                        finally: destination.close()

                    await asyncio.gather(pipe(reader, upstream), pipe(remote, writer))
                except (asyncio.IncompleteReadError, ConnectionError): pass
                finally:
                    writer.close()
                    if upstream: upstream.close()

            async with await asyncio.start_server(proxy, '127.0.0.1', 0) as server, await asyncio.start_server(proxy, '127.0.0.1', 0) as second_server:
                address = '127.0.0.1:' + str(server.sockets[0].getsockname()[1])
                result = await asyncio.to_thread(test.run_native, 'renewal', {'address': address, 'secondAddress': '127.0.0.1:' + str(second_server.sockets[0].getsockname()[1]), 'scenario': scenario})
                await asyncio.sleep(.05)
                return result

    try:
        test.assertTrue(asyncio.run(run())['ok'])
        test.assertEqual(errors, [])
        paths = Counter(path for path, token in state['requests'])
        if scenario == 'burst':
            test.assertEqual(state['renewals'], 1, state)
            test.assertEqual(state['auths'], 1, state)  # Cold restore used rotated short token.
            for path in ['/fixture/a', '/fixture/late', '/fixture/image', '/fixture/video', '/p/api/v1/gallery/batchGetByIds']:
                test.assertEqual(paths[path], 2, state)
            test.assertLessEqual(paths['/fixture/cancel'], 1, state)
        elif scenario == 'routes':
            test.assertEqual(state['renewals'], 1, state)
            test.assertEqual(state['auths'], 3, state)
            test.assertEqual(paths['/fixture/image'], 1, state)
        elif scenario in ('offline', 'busy', 'malformed'): test.assertEqual(state['renewals'], 2, state)
        elif scenario == 'repeated':
            test.assertEqual(state['renewals'], 1, state)
            test.assertEqual(paths['/fixture/a'], 2, state)
        elif scenario in ('terminal', 'logout', 'switch'):
            test.assertEqual(state['renewals'], 1, state)
            test.assertEqual(paths['/fixture/a'], 1, state)
    finally:
        http.shutdown(); http.server_close()
