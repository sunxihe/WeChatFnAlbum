#!/usr/bin/env python3
"""Read only relevant runtime class signatures. Never read chat content or credentials."""
import argparse,json
import frida
p=argparse.ArgumentParser();p.add_argument('--remote',default='127.0.0.1:27043');p.add_argument('--pid',type=int,required=True);p.add_argument('--output');a=p.parse_args()
d=frida.get_device_manager().add_remote_device(a.remote);session=d.attach(a.pid)
script=session.create_script(r'''
rpc.exports.probe=function(){
 const names=['ImageController','MMAsset','MMAssetForLocalImage','MMAssetInfo','BaseMsgContentLogicController','WeixinContentLogicController','BaseMsgContentViewController'];
 const result={};
 for(const name of names){const c=ObjC.classes[name];result[name]=c?c.$ownMethods.map(n=>({selector:n,types:c[n].types})):null;}
 result.host={bundle:ObjC.classes.NSBundle.mainBundle().bundleIdentifier().toString(),version:ObjC.classes.NSBundle.mainBundle().objectForInfoDictionaryKey_('CFBundleShortVersionString').toString()};
 return result;
};
''')
try:
 script.load();r=script.exports_sync.probe()
 if a.output:open(a.output,'w').write(json.dumps(r,ensure_ascii=False,indent=2))
 for cls,ms in r.items():
  if cls=='host':print(cls,ms);continue
  for m in ms or []:
   if any(t in m['selector'] for t in ['OpenMediaBrowser','didSelectMMAsset','initWithAssetId','getViewController','m_nsUsrName','processInsertedAsset','LivePhoto','livePhoto']):print(cls,m)
finally:session.detach()
