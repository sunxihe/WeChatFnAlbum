#!/usr/bin/env python3
"""Read decrypted arm64 ObjC metadata; never execute or change the input IPA."""
import argparse, json, struct, zipfile
from pathlib import Path

def inspect(path):
    with zipfile.ZipFile(path) as z:
        import plistlib
        info=plistlib.loads(z.read('Payload/WeChat.app/Info.plist'))
        d=z.read('Payload/WeChat.app/'+info['CFBundleExecutable'])
    if d[:4]!=b'\xcf\xfa\xed\xfe':raise ValueError('Expected thin 64-bit Mach-O')
    u32=lambda p:struct.unpack_from('<I',d,p)[0]
    def ptr(p):
        v=struct.unpack_from('<Q',d,p)[0]
        return 0x100000000+(v&0xfffffffff) if v>0x10000000000 else v
    segs=[];sections={};p=32
    for _ in range(u32(16)):
        cmd,size=struct.unpack_from('<II',d,p)
        if cmd==0x19:
            vm,vs,fo,fs=struct.unpack_from('<QQQQ',d,p+24);segs.append((vm,vs,fo,fs))
            for j in range(u32(p+64)):
                q=p+72+j*80;name=d[q:q+16].split(b'\0')[0].decode()
                addr,sz=struct.unpack_from('<QQ',d,q+32);sections[name]=(addr,sz,u32(q+48))
        if cmd==0x2c and u32(p+16):raise ValueError('Encrypted executable')
        p+=size
    def at(v):
        for vm,vs,fo,fs in segs:
            if vm<=v<vm+fs:return fo+v-vm
        raise ValueError(hex(v))
    def va(p):
        return next(vm+p-fo for vm,vs,fo,fs in segs if fo<=p<fo+fs)
    def cs(v):
        p=at(v);return d[p:d.index(b'\0',p)].decode(errors='replace')
    def methods(v):
        if not v:return []
        p=at(v);flags,count=struct.unpack_from('<II',d,p);step=flags&0xffff;out=[]
        if count>10000:raise ValueError('bad count')
        for i in range(count):
            q=p+8+i*step
            if flags&0x80000000:
                n=va(q)+struct.unpack_from('<i',d,q)[0]
                if not flags&0x40000000:n=ptr(at(n))
                t=va(q+4)+struct.unpack_from('<i',d,q+4)[0]
                imp=va(q+8)+struct.unpack_from('<i',d,q+8)[0]
            else:n,t,imp=ptr(q),ptr(q+8),ptr(q+16)
            out.append({'selector':cs(n),'types':cs(t),'imp':hex(imp)})
        return out
    _,sz,off=sections['__objc_classlist'];classes={}
    for i in range(sz//8):
        try:
            cp=at(ptr(off+i*8));ro=at(ptr(cp+32)&~7);name=cs(ptr(ro+24))
            classes[name]=methods(ptr(ro+32))
        except (ValueError,struct.error):continue
    return {'version':info['CFBundleShortVersionString'],'classes':classes}

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('ipa');ap.add_argument('--output');args=ap.parse_args()
    result=inspect(args.ipa)
    if args.output:Path(args.output).write_text(json.dumps(result,ensure_ascii=False,indent=2))
    for cls,methods in result['classes'].items():
        hits=[m for m in methods if any(k in m['selector'] for k in ['didFinishPickingWithAssetInfos','getImagePickerControllerWithOptionObj','SendImageMessageByMMAsset']) or ('ContentLogic' in cls and any(k in m['selector'].lower() for k in ['album','image','asset','photo']))]
        if hits:print(cls,json.dumps(hits,ensure_ascii=False))
