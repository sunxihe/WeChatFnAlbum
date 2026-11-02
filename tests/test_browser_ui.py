#!/usr/bin/env python3
"""Run actual browser views in a booted iOS simulator; synthetic media only."""
import json, os, plistlib, subprocess, tempfile, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
DEVICE = os.environ.get('FN_UI_SIMULATOR', 'booted')
def run(*args):
    return subprocess.check_output(args, text=True).strip()
with tempfile.TemporaryDirectory(prefix='fnalbum-ui-') as tmp:
    app = Path(tmp) / 'FNBrowserUI.app'
    app.mkdir()
    (app/'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier':'org.ac.fnalbum-ui-tests', 'CFBundleExecutable':'FNBrowserUI',
        'CFBundleName':'FNBrowserUI', 'CFBundlePackageType':'APPL', 'CFBundleVersion':'1',
        'CFBundleShortVersionString':'1', 'MinimumOSVersion':'15.0', 'UIDeviceFamily':[1,2],
        'UILaunchScreen':{}, 'UIRequiresFullScreen':True,
    }))
    sdk = run('xcrun','--sdk','iphonesimulator','--show-sdk-path')
    subprocess.run(['xcrun','clang','-target','arm64-apple-ios15.0-simulator','-isysroot',sdk,
        '-fobjc-arc','-fblocks','-Wno-deprecated-declarations','-Wno-mismatched-parameter-types',
        '-I'+str(ROOT/'Sources'),str(ROOT/'tests/BrowserUIHarness.m'),
        str(ROOT/'Sources/FNBrowser.m'),str(ROOT/'Sources/FNCategories.m'),str(ROOT/'Sources/FNTimelineScrubber.m'),str(ROOT/'Sources/FNPreviewLoadingView.m'),str(ROOT/'Sources/FNPreviewAudio.m'),str(ROOT/'Sources/FNZoomImageView.m'),str(ROOT/'Sources/FNNASVideoPreview.m'),str(ROOT/'Sources/FNProtocol.m'),str(ROOT/'Sources/FNNetworkRouting.m'),
        '-framework','CoreLocation','-framework','NetworkExtension','-framework','UIKit','-framework','Foundation','-framework','Security','-framework','AVKit',
        '-framework','AVFoundation','-framework','ImageIO','-framework','WebKit','-framework','CoreGraphics','-framework','CoreMedia','-o',str(app/'FNBrowserUI')],check=True)
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
    run('xcrun','simctl','install',DEVICE,str(app))
    run('xcrun','simctl','launch',DEVICE,'org.ac.fnalbum-ui-tests')
    container = Path(run('xcrun','simctl','get_app_container',DEVICE,'org.ac.fnalbum-ui-tests','data'))
    report = container/'Documents/ui-report.json'
    deadline = time.monotonic()+20
    while time.monotonic()<deadline:
        if report.exists():
            result = json.loads(report.read_text())
            if len(result)==39 and result.get('keyboardShown'): break
        time.sleep(.25)
    result = json.loads(report.read_text())
    print(json.dumps(result,indent=2))
    assert len(result)==39 and all(value == True for value in result.values()), result
    run('xcrun','simctl','terminate',DEVICE,'org.ac.fnalbum-ui-tests')
    run('xcrun','simctl','uninstall',DEVICE,'org.ac.fnalbum-ui-tests')
