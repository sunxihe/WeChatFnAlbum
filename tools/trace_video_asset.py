#!/usr/bin/env python3
"""Observe only this plugin's local video adapter. Never invoke chat-send APIs."""
import argparse, json, time
from pathlib import Path
import frida

p = argparse.ArgumentParser()
p.add_argument('--pid', type=int, required=True)
p.add_argument('--remote', default='127.0.0.1:27043')
p.add_argument('--seconds', type=int, default=180)
p.add_argument('--output', required=True)
a = p.parse_args()
events = []
def message(m, data):
    events.append(m.get('payload', m))
    Path(a.output).write_text(json.dumps(events, ensure_ascii=False, indent=2))
session = frida.get_device_manager().add_remote_device(a.remote).attach(a.pid)
script = session.create_script(r'''
const C = ObjC.classes;
function blockSignature(p) {
    if (p.isNull()) return 'nil';
    const flags = p.add(8).readU32();
    if (!(flags & (1 << 30))) return 'unknown';
    let d = p.add(24).readPointer().add(16);
    if (flags & (1 << 25)) d = d.add(16);
    return d.readPointer().readUtf8String();
}
const hooked = new Set();
function watchBlock(p, name) {
    if (p.isNull()) return;
    const signature = blockSignature(p);
    send({event:'block', method:name, signature});
    const invoke = p.add(16).readPointer();
    const key = invoke.toString();
    if (hooked.has(key)) return;
    hooked.add(key);
    Interceptor.attach(invoke, {onEnter(args) {
        // Record invocation only; do not inspect media bytes or unrelated callback values.
        send({event:'callback', method:name, signature});
    }});
}
const selectors = [
 ['getVideoUrl',[]], ['getThumbnail',[]], ['videoDuration',[]], ['originVideoSize',[]],
 ['uniformTypeIdentifier',[]], ['getEditVideoAttr',[]], ['copyWithZone:',[]],
 ['asyncGetVideoAssetWithBlock:',[2]], ['asyncGetVideoAsset:withBlock:',[3]],
 ['asyncGetVideoAsset:successBlock:errorBlock:',[3,4]],
 ['_asyncGetVideoAsset:successBlock:errorBlock:',[3,4]],
 ['asyncGetVideoFileSizeWithBlock:',[2]], ['asyncGetIsSpatial:',[2]],
 ['asyncGetMetadata:',[2]], ['asyncGetThumbnail:',[2]], ['asyncGetImageExifLogInfo:',[2]],
 ['getVideoDurationForDisplayWithCompletion:',[2]],
 ['getBigImageWithCompressConfig:ProcessBlock:ResultBlock:ErrorBlock:',[3,4,5]]
];
const seenMethods = new Set();
for (const [name, blocks] of selectors) {
 const method = C.ACFNLocalVideoAsset['- '+name];
 if (!method || seenMethods.has(method.implementation.toString())) continue;
 seenMethods.add(method.implementation.toString());
 try { Interceptor.attach(method.implementation, {
  onEnter(args) {
   this.mine = new ObjC.Object(args[0]).$className === 'ACFNLocalVideoAsset';
   if (!this.mine) return;
   send({event:'call', method:name});
   for (const index of blocks) {try {watchBlock(args[index], name+':'+index);} catch(e) {send({event:'probeError',method:name,error:String(e)});}}
  },
  onLeave(ret) {
   if (!this.mine) return;
   if (name === 'originVideoSize') send({event:'return',method:name,value:ret.toString()});
  }
 }); } catch(e) { send({event:'unhookable',method:name,error:String(e)}); }
}
send({event:'ready'});
''')
script.on('message', message)
try:
    script.load()
    print('Video callback tracing ready', flush=True)
    time.sleep(min(a.seconds, 600))
finally:
    session.detach()
