#!/usr/bin/env python3
"""Actual AVPlayer progressive original playback against a synthetic localhost NAS; no user media."""
import io, json, os, plistlib, subprocess, tempfile, threading, time
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
ROOT=Path(__file__).resolve().parents[1]
DEVICE=os.environ.get('FN_UI_SIMULATOR','booted')
def run(*args): return subprocess.check_output(args,text=True).strip()
with tempfile.TemporaryDirectory(prefix='fnalbum-stream-ui-') as tmp:
    tmp=Path(tmp); media=tmp/'media';media.mkdir()
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i','testsrc2=size=320x240:rate=24','-f','lavfi','-i','anullsrc=r=44100:cl=stereo','-t','48','-c:v','libx264','-preset','ultrafast','-g','48','-c:a','aac',*(['-movflags','+faststart'] if not os.environ.get('FN_STREAM_TAIL_MOOV') else []),str(media/'original.mp4')],check=True)
    original=(media/'original.mp4').read_bytes()
    force_retry=bool(os.environ.get('FN_STREAM_FORCE_RETRY'))
    events={'bytes':0,'ranges':0,'started':False,'renew':0,'authorized':not force_retry};errors=[]
    class HTTP(BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def handle_request(self,head=False):
            try:
                path=urlsplit(self.path).path
                if path=='/fixture/mark-start':
                    assert 0<events['bytes']<len(original),'playback must begin before complete file transfer'
                    events['started']=True
                    self.send_response(200);self.send_header('Content-Length','2');self.end_headers();self.wfile.write(b'ok');return
                if path=='/p/api/v1/gallery/batchGetByIds':
                    assert force_retry and self.headers.get('accessToken')=='fixture-token'
                    assert json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))=={'ids':[7]}
                    events['renew']+=1;events['authorized']=True
                    body=json.dumps({'code':0,'data':{'list':[{'id':7,'fileName':'fixture.mp4','fileType':'video','additional':{'thumbnail':{'videoUrl':'/original.mp4'}}}]}}).encode()
                    self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
                if path=='/original.mp4' and not events['authorized']:
                    self.send_response(401);self.send_header('Content-Length','0');self.end_headers();return
                assert path=='/original.mp4','unexpected NAS API call: '+path
                cookies=SimpleCookie(self.headers.get('Cookie',''))
                assert cookies.get('fnos-token') and cookies['fnos-token'].value=='fixture-token','missing scoped media cookie'
                start=0;end=len(original)-1;status=200
                if self.headers.get('Range'):
                    events['ranges']+=1
                    bounds=self.headers['Range'].removeprefix('bytes=').split('-');start=int(bounds[0]);end=min(end,int(bounds[1]) if bounds[1] else end);status=206
                self.send_response(status);self.send_header('Content-Type','video/mp4');self.send_header('Content-Length',str(end-start+1));self.send_header('Accept-Ranges','bytes')
                if status==206:self.send_header('Content-Range',f'bytes {start}-{end}/{len(original)}')
                self.end_headers()
                if not head:
                    for offset in range(start,end+1,16384):
                        data=original[offset:min(end+1,offset+16384)]
                        self.wfile.write(data);self.wfile.flush();events['bytes']+=len(data);time.sleep(.02)
            except (BrokenPipeError,ConnectionResetError):pass
            except Exception as error:
                errors.append(repr(error));self.send_response(500);self.end_headers()
        do_GET=handle_request
        do_POST=handle_request
        def do_HEAD(self):self.handle_request(True)
    server=ThreadingHTTPServer(('127.0.0.1',0),HTTP);threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        app=tmp/'FNStreamingUI.app';app.mkdir()
        (app/'fixture.txt').write_text(f'http://127.0.0.1:{server.server_port}')
        (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.ac.fnalbum-stream-ui','CFBundleExecutable':'FNStreamingUI','CFBundleName':'FNStreamingUI','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1','MinimumOSVersion':'15.0','UIDeviceFamily':[1,2],'UILaunchScreen':{},'NSAppTransportSecurity':{'NSAllowsArbitraryLoads':True}}))
        sdk=run('xcrun','--sdk','iphonesimulator','--show-sdk-path')
        sources=['FNBrowser','FNCategories','FNTimelineScrubber','FNPreviewLoadingView','FNPreviewAudio','FNZoomImageView','FNProtocol','FNNetworkRouting']
        subprocess.run(['xcrun','clang','-target','arm64-apple-ios15.0-simulator','-isysroot',sdk,'-fobjc-arc','-fblocks','-Wno-deprecated-declarations','-Wno-mismatched-parameter-types','-I'+str(ROOT/'Sources'),str(ROOT/'tests/StreamingUIHarness.m'),*[str(ROOT/'Sources'/f'{name}.m') for name in sources],*[x for fw in ['UIKit','Foundation','Security','AVKit','AVFoundation','ImageIO','WebKit','CoreGraphics','CoreMedia','CoreLocation','NetworkExtension'] for x in ['-framework',fw]],'-o',str(app/'FNStreamingUI')],check=True)
        subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
        run('xcrun','simctl','install',DEVICE,str(app));run('xcrun','simctl','launch',DEVICE,'org.ac.fnalbum-stream-ui')
        container=Path(run('xcrun','simctl','get_app_container',DEVICE,'org.ac.fnalbum-stream-ui','data'));report=container/'Documents/stream-report.json'
        deadline=time.monotonic()+45
        while time.monotonic()<deadline:
            if report.exists():break
            time.sleep(.25)
        result=json.loads(report.read_text());print(json.dumps(result,indent=2))
        assert result.get('done') and not result.get('failed') and all(result.get(k) for k in ['remoteOriginalPlayback','noCompleteFileDownload','originalToggleDoesNotRestart','loadingMaskHiddenAfterFirstFrame']),result
        assert events['started'] and events['ranges']>0 and events['renew']==int(force_retry) and not errors,(events,errors)
        print('Original video displays before full transfer; Range/cookies work, no transcoding API calls, original toggle does not restart playback.')
    finally:
        server.shutdown();server.server_close()
        subprocess.run(['xcrun','simctl','terminate',DEVICE,'org.ac.fnalbum-stream-ui'],capture_output=True)
        subprocess.run(['xcrun','simctl','uninstall',DEVICE,'org.ac.fnalbum-stream-ui'],capture_output=True)
