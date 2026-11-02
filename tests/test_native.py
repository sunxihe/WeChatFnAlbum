#!/usr/bin/env python3
"""Compile the actual Objective-C client on macOS and exercise real HTTP/WS boundaries.
All accounts, secrets and media in this suite are synthetic; no real NAS is used.
"""
import asyncio, base64, hashlib, hmac, json, logging, os, subprocess, sys, tempfile, threading, unittest
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qsl, urlencode
from Crypto.Cipher import AES, PKCS1_v1_5
from Crypto.PublicKey import RSA
from Crypto.Util.Padding import unpad, pad
from websockets.asyncio.server import serve
ROOT=Path(__file__).resolve().parents[1]
from protocol_reference import photo_authx

logging.getLogger('websockets').setLevel(logging.CRITICAL)

class NativeProtocol(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory();cls.directory=Path(cls.temp.name);cls.runner=cls.directory/'ProtocolRunner';cls.rsa=RSA.generate(2048)
        subprocess.run(['xcrun','clang',*(['-fsanitize=address','-fno-omit-frame-pointer']if os.environ.get('FN_TEST_SANITIZE')else[]),'-fobjc-arc','-fblocks','-Wno-deprecated-declarations','-Wno-mismatched-parameter-types','-DFN_SESSION_SERVICE=@"org.ac.WeChatFnAlbum.native-tests"','-I'+str(ROOT/'Sources'),str(ROOT/'Sources/FNProtocol.m'),str(ROOT/'Sources/FNImageDelivery.m'),str(ROOT/'Sources/FNMediaHandoff.m'),str(ROOT/'Sources/FNHost.m'),str(ROOT/'Sources/FNNASVideoPreview.m'),str(ROOT/'tests/ProtocolRunner.m'),'-framework','Foundation','-framework','Security','-o',str(cls.runner)],check=True)
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()
    def run_native(self,mode,fixture):
        path=self.directory/(mode+'.json');path.write_text(json.dumps(fixture))
        p=subprocess.run([str(self.runner),mode,str(path)],capture_output=True,text=True,timeout=10 if mode=='callbacks'else 60)
        self.assertEqual(p.returncode,0,p.stderr);return json.loads(p.stdout)
    def test_compact_video_preview_lifecycle(self):
        self.assertTrue(self.run_native('video-preview',{})['ok'])
    def test_media_handoff_routes_video_separately(self):
        self.assertTrue(self.run_native('handoff',{})['ok'])
    def test_token_renewal_transfer_recovery(self):
        from token_fixture import run_renewal
        for scenario in ['burst','offline','busy','malformed','terminal','repeated','logout','switch','routes']:
            with self.subTest(scenario=scenario): run_renewal(self,scenario)
    def test_resigned_bundle_id_host_detection(self):
        base={'CFBundleExecutable':'WeChat','CFBundlePackageType':'APPL'}
        rows=[{'info':dict(base,CFBundleIdentifier=bundle),'path':'/Payload/WeChat.app','expected':True}
              for bundle in ['com.tencent.xin','com.tencent.xin.multiple','cn.custom.wechat','org.example.anything']]
        rows += [{'info':dict(base,CFBundleIdentifier='com.tencent.xin',CFBundleExecutable=executable),
                  'path':path,'expected':False}
                 for executable,path in [('WeChatNotificationServiceExtension','/Payload/WeChat.app/PlugIns/WeChatNotificationServiceExtension.appex'),
                                        ('WeChat','/Payload/WeChat.app/PlugIns/Share.appex'),
                                        ('OtherApp','/Payload/Other.app'),('WeChat','/Payload/Plugin.bundle')]]
        rows += [{'info':{'CFBundleExecutable':'WeChat','CFBundlePackageType':'XPC!'},'path':'/Payload/WeChat.app','expected':False},
                 {'info':{},'path':'/Payload/WeChat.app','expected':False}]
        self.assertTrue(self.run_native('hosts',{'hosts':rows})['ok'])
    def test_media_models_and_category_filters(self):
        self.assertTrue(self.run_native('media',{})['ok'])
    def test_callbacks_outlive_native_caller(self):
        self.assertTrue(self.run_native('callbacks',{})['ok'])
    def test_signatures_endpoints_rsa_aes(self):
        inputs=[('192.168.2.126','http://192.168.2.126:5666'),('nas.local','http://nas.local:5666'),('https://nas.local','https://nas.local'),('nas.local:7777','http://nas.local:7777'),('::1','http://[::1]:5666'),('[::1]:7777','http://[::1]:7777'),('http://nas.local/','http://nas.local'),('',None),('ftp://nas.local',None),('http://u:p@nas.local',None),('nas.local/path',None),('nas.local:99999',None),('nas.local?foo=1',None)]
        urls=['http://nas.test/p/api/v1/album/list?offset=0&limit=60','http://nas.test/p/api/v1/gallery/getList?'+urlencode({'folder':'照片/旅途 + %','empty':'','limit':60}),'http://nas.test/p/api/v1/stream/p/t/123/s/uuid','http://nas.test/p/api/v1/album/list?limit=60&limit=100&offset=0']
        key=os.urandom(32);iv=os.urandom(16);payload={'req':'user.login','password':'synthetic','user':'测试'}
        f={'endpoints':[{'input':a,'output':b}for a,b in inputs],'signatures':[{'url':u,'expected':photo_authx(u,nonce='123456',timestamp='1793320000000')}for u in urls],'pub':self.rsa.public_key().export_key().decode(),'key':base64.b64encode(key).decode(),'iv':base64.b64encode(iv).decode(),'payload':payload}
        r=self.run_native('unit',f)
        self.assertEqual(PKCS1_v1_5.new(self.rsa).decrypt(base64.b64decode(r['rsa']),None),key)
        self.assertEqual(json.loads(unpad(AES.new(key,AES.MODE_CBC,iv).decrypt(base64.b64decode(r['aes'])),16)),payload)
    def integration(self,twofa,persist=False):
        errors=[];rsa=self.rsa;token='fixture-token';secret=b'fixture-session-secret-32-bytes!!'
        class HTTP(BaseHTTPRequestHandler):
            reverse_failed = False
            def log_message(self,*args):pass
            def do_POST(self):
                try:
                    raw=self.rfile.read(int(self.headers['Content-Length']))
                    request=json.loads(raw);auth=dict(parse_qsl(self.headers['authx']))
                    assert self.path in ['/p/api/v1/magic-search/do','/p/api/v1/gallery/batchGetByIds','/p/api/v1/search/results']
                    assert self.headers['accessToken']==token
                    assert self.headers['Content-Type'].startswith('application/json')
                    digest=hashlib.md5(raw).hexdigest()
                    expected=hashlib.md5(f"NDzZTVxnRKP8Z0jXg1VAMonaG8akvh_{self.path}_{auth['nonce']}_{auth['timestamp']}_{digest}_EAECCF25-80A6-4666-A7C2-A76904A74AB6".encode()).hexdigest()
                    assert auth['sign']==expected
                    if self.path.endswith('/search/results'):
                        assert request['viewMode']=='simple' and request['showFilterBar'] is False and request['antiFilters']==[]
                        f=request['filters'][0];assert f['filterBindingValue']==''
                        if f['filterName']=='person':assert f['filterValue']=='42';ids=[1002]
                        elif f['filterName']=='photo_location':
                            assert f['filterValue']=='China' and f['subFilters'][0]['filterName']=='China' and f['subFilters'][0]['filterValue']=='Shanghai';ids=[1003]
                        else:assert f['filterName']=='file_type' and f['filterValue']=='video';ids=[1001]
                        self.send_response(200);self.end_headers();self.wfile.write(json.dumps({'code':0,'data':{'list':[{'id':i}for i in ids],'idList':ids}}).encode());return
                    if self.path.endswith('/batchGetByIds'):
                        ids=request['ids'];assert 0<len(ids)<=60
                        # Reverse response order to verify the client retains NAS search ordering.
                        data={'list':[{'id':i,'fileName':f'{i}.gif','additional':{'thumbnail':{'originalUrl':f'/{i}.gif'}}}for i in reversed(ids)]}
                        for row in data['list']:
                            if row['id']==1001:
                                row['fileName']='video.mp4';row['fileType']='video'
                                row['additional']['thumbnail']={'originalUrl':'/poster.jpg','videoUrl':'/video.mp4','sUrl':'/small.jpg'}
                        self.send_response(200);self.end_headers();self.wfile.write(json.dumps({'code':0,'data':data}).encode());return
                    assert request['viewMode']=='simple'
                    if request['keyword']=='模型未安装':data={'errorCode':20701,'list':[]}
                    elif request['keyword']=='模型不统一':
                        self.send_response(200);self.end_headers();self.wfile.write(json.dumps({'code':4031,'data':None}).encode());return
                    elif request['keyword']=='分页搜索':data={'list':[{'id':i,'photoDateTime':'2026:10:30 00:00:00'}for i in range(1,66)],'idList':list(range(1,66))}
                    else:
                        assert request['keyword']=='海边日落 + "test"'
                        data={'list':[{'id':42,'fileName':'test.gif','additional':{'thumbnail':{'originalUrl':'/image.gif'}}}],'idList':[42]}
                    self.send_response(200);self.end_headers();self.wfile.write(json.dumps({'code':0,'data':data}).encode())
                except Exception as e:errors.append(repr(e));self.send_response(500);self.end_headers()
            def do_GET(self):
                try:
                    u=urlsplit(self.path);q=dict(parse_qsl(u.query));auth=dict(parse_qsl(self.headers.get('authx','')))
                    assert self.headers.get('accessToken')==token
                    expected=photo_authx('http://'+self.headers['Host']+self.path,nonce=auth['nonce'],timestamp=auth['timestamp'])
                    assert self.headers['authx']==expected
                    if u.path=='/fixture-media':
                        self.send_response(200);self.end_headers();self.wfile.write(b'synthetic media bytes');return
                    if u.path=='/redirect':self.send_response(302);self.send_header('Location','https://elsewhere.invalid/private');self.end_headers();return
                    if u.path.endswith('/ai-person/list'):
                        assert q['getAll']=='true' and q['orderBy']=='name';data={'list':[{'id':42,'name':'fixture-person','isHide':False}]}
                    elif u.path.endswith('/explore/geos'):
                        assert q['offset']=='0' and q['limit']=='60';data={'list':[{'country':'China','city':'Shanghai','itemCount':1}]}
                    elif u.path.endswith('/album/list'):
                        assert {'sort_by','sort_direction','offset','limit'}<=q.keys();data={'list':[{'albumId':1}]}
                    elif u.path.endswith('/album/photos'):
                        assert q['album_id']=='1' and q['sort_by']=='date_time' and q['sort_direction']=='desc'
                        offset=int(q['offset']);limit=int(q['limit'])
                        data={'list':[{'id':i,'fileName':str(i)+'.jpg'}for i in range(offset,min(72,offset+limit))],'hasNext':offset+limit<72}
                    elif u.path.endswith('/timeline'):
                        counts=(3,2)if q.get('is_collect')=='1'else(65,7)
                        data={'list':[{'year':2026,'month':10,'day':d,'itemCount':n}for d,n in zip((30,29),counts)]}
                    else:
                        assert {'start_time','end_time','mode','offset','limit'}<=q.keys();day=30 if q['start_time'].startswith('2026:10:30') else 29
                        total=({30:3,29:2}if q['mode']=='collect'else{30:65,29:7})[day];offset=int(q['offset']);limit=int(q['limit'])
                        if day==30 and offset==0 and limit==5 and q['mode']=='index' and not HTTP.reverse_failed:
                            HTTP.reverse_failed=True;self.send_response(503);self.end_headers();return
                        data={'list':[{'id':day*1000+i,'fileName':str(i)+'.jpg'}for i in range(offset,min(total,offset+limit))]}
                    self.send_response(200);self.end_headers();self.wfile.write(json.dumps({'code':0,'data':data}).encode())
                except Exception as e:errors.append(str(e));self.send_response(500);self.end_headers()
        http=ThreadingHTTPServer(('127.0.0.1',0),HTTP);threading.Thread(target=http.serve_forever,daemon=True).start()
        async def websocket(ws):
            async for raw in ws:
                signed=not raw.startswith('{')
                if signed:
                    assert raw[:44]==base64.b64encode(hmac.new(secret,raw[44:].encode(),hashlib.sha256).digest()).decode();raw=raw[44:]
                r=json.loads(raw)
                if r.get('req')=='encrypted':
                    key=PKCS1_v1_5.new(rsa).decrypt(base64.b64decode(r['rsa']),None);iv=base64.b64decode(r['iv']);r=json.loads(unpad(AES.new(key,AES.MODE_CBC,iv).decrypt(base64.b64decode(r['aes'])),16))
                    if r['req']=='user.login':
                        assert r['user']=='fixture-user'and r['password']=='fixture-password'
                        if twofa:response={'result':'succ','isBindTwofaSecret':True,'isTrustedDevice':False,'accessToken':'fixture-challenge'}
                        else:response={'result':'succ','token':token,'longToken':'fixture-long-token','secret':base64.b64encode(AES.new(key,AES.MODE_CBC,iv).encrypt(pad(secret,16))).decode()}
                    else:
                        assert r['req']=='user.2fa.loginVerify'and r['code']=='123456'and r['isTrustedDevice']is False
                        response={'result':'succ','token':token,'longToken':'fixture-long-token','secret':base64.b64encode(AES.new(key,AES.MODE_CBC,iv).encrypt(pad(secret,16))).decode()}
                else:
                    if r['req']=='user.authToken':
                        assert signed and r['token']==token;response={'result':'fail','errno':135168}
                    elif r['req']=='user.tokenLogin':
                        assert signed and r['token']=='fixture-long-token';response={'result':'succ','token':token,'longToken':'rotated-long-token'}
                    else:
                        assert r['req']=='util.crypto.getRSAPub';response={'pub':rsa.public_key().export_key().decode(),'si':'fixture-si'}
                response['reqid']=r['reqid'];await ws.send(json.dumps(response))
        # Same origin HTTP and WS: use a tiny reverse proxy for the handshake only.
        # NSURLSession connects WS on the NAS port; run an asyncio HTTP/WS server
        # through websockets' process_request, delegating HTTP to the fixture above.
        from websockets.http11 import Response
        from websockets.datastructures import Headers
        import urllib.request
        async def process(connection,request):
            if request.path.startswith('/websocket'):return None
            req=urllib.request.Request('http://127.0.0.1:'+str(http.server_port)+request.path,headers=dict(request.headers))
            # Preserve the outward Host so authx canonicalization sees the exact URL.
            try:
                class NoRedirect(urllib.request.HTTPRedirectHandler):
                    def redirect_request(self,*args):return None
                try:
                    res=await asyncio.to_thread(urllib.request.build_opener(NoRedirect).open,req)
                except urllib.error.HTTPError as e:res=e
                body=res.read();hs=[(k,v)for k,v in res.headers.items()if k.lower()not in ['connection','transfer-encoding','content-length']];hs.append(('Content-Length',str(len(body))));return Response(res.status,'Fixture',Headers(hs),body)
            except Exception as e:errors.append(str(e));return Response(500,'Fixture',Headers([('Content-Length','0')]),b'')
        async def run():
            async with serve(websocket,'127.0.0.1',0,process_request=process)as server:
                port=server.sockets[0].getsockname()[1]
                return await asyncio.to_thread(self.run_native,'integration',{'address':f'127.0.0.1:{port}','httpAddress':f'http://127.0.0.1:{http.server_port}','persist':persist})
        try:self.assertTrue(asyncio.run(run())['ok']);self.assertEqual(errors,[])
        finally:http.shutdown();http.server_close()
    def test_password_pagination_redirect_origin(self):self.integration(False)
    def test_two_factor(self):self.integration(True)
    def test_keychain_restore_long_token(self):self.integration(False,True)

if __name__=='__main__':unittest.main(verbosity=2)
