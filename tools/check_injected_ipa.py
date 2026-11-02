#!/usr/bin/env python3
"""Read-only checks of the signed output IPA, including actual Mach-O load commands."""
import argparse
import hashlib
import json
import plistlib
import struct
import zipfile
from pathlib import Path


def macho(data):
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        wide = data[:4] == b'\xca\xfe\xba\xbf'
        count = struct.unpack_from('>I', data, 4)[0]
        result = []
        for i in range(count):
            offset = 8 + i * (32 if wide else 20)
            start, length = struct.unpack_from('>QQ' if wide else '>II', data, offset + 8)
            result.extend(macho(data[start:start + length]))
        return result
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a 64-bit Mach-O executable or dylib')
    cpu, subtype, _, count, size = struct.unpack_from('<IIIII', data, 4)
    if size > len(data) - 32:
        raise ValueError('Truncated Mach-O load commands')
    arch = ('arm64e' if subtype & 0xffffff == 2 else 'arm64') if cpu == 0x100000c else hex(cpu)
    loads, rpaths = [], []
    offset = 32
    for _ in range(count):
        cmd, length = struct.unpack_from('<II', data, offset)
        if length < 8 or offset + length > 32 + size:
            raise ValueError('Invalid Mach-O command size')
        if cmd in (0xc, 0x80000018, 0x8000001f, 0x80000023, 0x8000001c):
            start = struct.unpack_from('<I', data, offset + 8)[0]
            if start >= length:
                raise ValueError('Invalid Mach-O string offset')
            name = data[offset + start:offset + length].split(b'\0')[0].decode()
            if cmd == 0x8000001c:
                rpaths.append(name)
            else:
                loads.append({'path': name, 'weak': cmd == 0x80000018})
        offset += length
    return [{'architecture': arch, 'loads': loads, 'rpaths': rpaths}]


def inspect(path):
    with zipfile.ZipFile(path) as archive:
        infos = [n for n in archive.namelist() if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
        if len(infos) != 1:
            raise ValueError('Expected exactly one main application')
        root = infos[0].removesuffix('Info.plist')
        info = plistlib.loads(archive.read(infos[0]))
        main = macho(archive.read(root + info['CFBundleExecutable']))
        files = []
        for name in archive.namelist():
            if name.endswith('.dylib') and 'wechatfnalbum' in name.lower():
                payload = archive.read(name)
                files.append({'path': name, 'bytes': len(payload), 'sha256': hashlib.sha256(payload).hexdigest(),
                              'architectures': [s['architecture'] for s in macho(payload)],
                              'inMainApp': name.startswith(root) and '/PlugIns/' not in name})
        relevant = [{'architecture': s['architecture'], 'loads': [p for p in s['loads'] if 'wechatfnalbum' in p['path'].lower()],
                     'rpaths': s['rpaths']} for s in main]
        return {'ipa': str(path), 'bundleID': info.get('CFBundleIdentifier'), 'version': info.get('CFBundleShortVersionString'),
                'executable': info['CFBundleExecutable'], 'v023BundleIDGatePasses': info.get('CFBundleIdentifier') == 'com.tencent.xin',
                'pluginFiles': files, 'mainExecutableReferences': relevant,
                'note': 'File presence alone does not prove loading. Inspect the signed output, not the original input IPA. If no direct reference exists, check whether a separate loader loads the plugin.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    args = parser.parse_args()
    print(json.dumps(inspect(args.ipa), ensure_ascii=False, indent=2))
