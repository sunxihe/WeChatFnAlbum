#!/usr/bin/env python3
"""Inspect deb ar/tar contents and Mach-O dependencies without requiring dpkg."""
import io,json,subprocess,tarfile,hashlib,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def members(path):
    data=path.read_bytes();assert data[:8]==b'!<arch>\n';p=8;result={}
    while p<len(data):
        head=data[p:p+60];size=int(head[48:58]);name=head[:16].decode().strip().rstrip('/');start=p+60;result[name]=data[start:start+size];p=start+size+(size%2)
    return result
report=[]
for label,prefix,arch in [('rootless','var/jb/','iphoneos-arm64'),('injection','','iphoneos-arm')]:
    path=ROOT/'dist'/label/f'WeChatFnAlbum-0.4.3-{label}.deb';parts=members(path)
    data_name=next(k for k in parts if k.startswith('data.tar'));control_name=next(k for k in parts if k.startswith('control.tar'))
    with tarfile.open(fileobj=io.BytesIO(parts[data_name]),mode='r:*')as t:
        names=[m.name.removeprefix('./')for m in t.getmembers()]
        wanted=prefix+'Library/MobileSubstrate/DynamicLibraries/'
        assert wanted+'WeChatFnAlbum.dylib'in names,(label,names)
        assert wanted+'WeChatFnAlbum.plist'in names
        assert wanted+'WeChatFnAlbum.bundle/Info.plist'in names
        dylib=t.extractfile(next(m for m in t.getmembers()if m.name.removeprefix('./')==wanted+'WeChatFnAlbum.dylib')).read()
        assert all(probe not in dylib for probe in (b'asset-tests.json', b'asset-trace.json', b'ui-probe.json', b'video-read.json', b'video-stream-probe.json', b'video-render-probe.json')), 'Developer probes leaked into release'
        assert b'/p/api/v1/video/decode/play' not in dylib, 'Retired transcoding startup leaked into release'
        with tempfile.NamedTemporaryFile(suffix='.dylib')as tmp:
            tmp.write(dylib);tmp.flush();built_archs=subprocess.check_output(['xcrun','lipo','-archs',tmp.name],text=True).split()
        assert set(built_archs)==({'arm64','arm64e'}if label=='rootless'else{'arm64'}),built_archs
    with tarfile.open(fileobj=io.BytesIO(parts[control_name]),mode='r:*')as t:
        m=next(x for x in t.getmembers()if x.name.removeprefix('./')=='control');control=t.extractfile(m).read().decode();assert 'Architecture: '+arch in control
    report.append({'file':str(path.relative_to(ROOT)),'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'architecture':arch})
lib=ROOT/'dist/injection/WeChatFnAlbum.dylib'
deps=subprocess.check_output(['xcrun','otool','-L',str(lib)],text=True)
assert 'substrate'not in deps.lower()and '/var/jb'not in deps and '/Users/'not in '\n'.join(deps.splitlines()[1:])
assert '@rpath/WeChatFnAlbum.dylib'in deps or '@executable_path/WeChatFnAlbum.dylib'in deps
arches=subprocess.check_output(['xcrun','lipo','-archs',str(lib)],text=True).strip();assert arches=='arm64',arches
(ROOT/'dist'/'manifest.json').write_text(json.dumps({'packages':report,'injectionArchitectures':arches,'dependencies':deps.splitlines()[1:],'deviceValidation':'Dopamine iPadOS 15.2 / WeChat 8.0.75: user confirmed images, animated GIF, Live Photo, categories and portraits; 0.3.3 ordinary video sends and opens for playback with original unchecked. 0.3.4 preview progress and playback are user-confirmed. 0.3.5 token renewal passed synthetic HTTP/WS tests; real expiry remains unverified. 0.3.6 duration badges and SSID routing passed synthetic tests; actual Wi-Fi authorization and home/remote switching remain unverified. 0.3.7 preview audio session lifecycle passed simulated checks; actual audible playback remains pending. 0.3.9 photo zoom passed simulator geometry/gesture gating checks; physical pinch interaction remains pending. 0.4.1 explicitly requests H.264/AAC compatible HLS; actual NAS segment verified H.264 400x848 plus AAC, simulator verifies nonzero video dimensions and visible player output. User confirmed actual iPad picture, sound, buffer percentage and original size in 0.4.1. 0.4.2 bounded prewarm/session reuse passed synthetic single-flight and AVPlayer original-toggle-back checks; user reported startup still slow. 0.4.3 removes transcoding and prewarm, directly plays original video with HTTP Range; actual NAS returned 64 KiB of a 112747943-byte MP4 in 0.105s with HTTP 206. Simulator shows picture before full transfer, tests media-credential retry and stable original toggle; on 2026-11-02 user confirmed actual iPad startup is noticeably faster, picture/audio and playback seeking work. Original-quality video sending, mixed media and signed injection remain unverified on device.'},ensure_ascii=False,indent=2))
print(json.dumps(report,ensure_ascii=False,indent=2))
