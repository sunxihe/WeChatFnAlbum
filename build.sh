#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export THEOS="${THEOS:-$HOME/theos}"
export PATH="$THEOS/bin:$PATH"
mkdir -p dist/rootless dist/injection dist/logs
make clean THEOS_PACKAGE_SCHEME=rootless >dist/logs/clean-rootless.log 2>&1
make -j4 package THEOS_PACKAGE_SCHEME=rootless ARCHS="arm64 arm64e" >dist/logs/build-rootless.log 2>&1
cp packages/org.ac.wechatfnalbum_0.4.3_iphoneos-arm64.deb dist/rootless/WeChatFnAlbum-0.4.3-rootless.deb
make clean THEOS_PACKAGE_SCHEME= >dist/logs/clean-injection.log 2>&1
make -j4 package THEOS_PACKAGE_SCHEME= THEOS_PACKAGE_ARCH=iphoneos-arm ARCHS=arm64 >dist/logs/build-injection.log 2>&1
cp packages/org.ac.wechatfnalbum_0.4.3_iphoneos-arm.deb dist/injection/WeChatFnAlbum-0.4.3-injection.deb
cp .theos/obj/WeChatFnAlbum.dylib dist/injection/
cp -R Resources/WeChatFnAlbum.bundle dist/injection/
cp WeChatFnAlbum.plist dist/injection/
/usr/bin/python3 tools/verify_packages.py
/usr/bin/python3 tools/archive_release.py
printf 'Packages ready in %s/dist\n' "$PWD"
