#!/usr/bin/env python3
"""Archive distributable source/resources only; exclude research and device logs."""
import re
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
version = re.search(r'^Version:\s*(\S+)', (root / 'control').read_text(), re.M).group(1)
with zipfile.ZipFile(root / 'dist' / f'WeChatFnAlbum-{version}-source.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for base in ['Sources', 'Resources', 'docs', 'tests', 'tools']:
        for path in (root / base).rglob('*'):
            if path.is_file() and '__pycache__' not in path.parts:
                z.write(path, Path('WeChatFnAlbum') / path.relative_to(root))
    for name in ['README.md', 'Makefile', 'control', 'Tweak.xm', 'WeChatFnAlbum.plist',
                 'build.sh', '.gitignore', '.clang-format', 'LICENSE', 'requirements-test.txt']:
        z.write(root / name, Path('WeChatFnAlbum') / name)
with zipfile.ZipFile(root / 'dist' / f'WeChatFnAlbum-{version}-injection.zip', 'w', zipfile.ZIP_DEFLATED) as z:
    for path in (root / 'dist/injection').rglob('*'):
        if path.is_file() and (path.suffix != '.deb' or path.name == f'WeChatFnAlbum-{version}-injection.deb'):
            z.write(path, path.relative_to(root / 'dist/injection'))
    z.write(root / 'README.md', 'README.md')
print(f'Source and injection archives ready: {version}')
