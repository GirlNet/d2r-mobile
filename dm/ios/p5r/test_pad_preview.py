#!/usr/bin/env python3
"""用生产 UIKit 视图在可用 iOS 模拟器验收布局；不读取游戏资源。
Validate production UIKit layouts on available iOS simulators without game assets.
"""
import argparse,json,platform,plistlib,subprocess,sys,time
from pathlib import Path
HERE=Path(__file__).resolve().parent
def run(*args,**kwargs):
    try:
        return subprocess.run([str(a) for a in args],check=True,capture_output=True,text=True,**kwargs).stdout
    except subprocess.CalledProcessError as error:
        print(error.stdout or '',file=sys.stderr);print(error.stderr or '',file=sys.stderr);raise
def main(output):
    output.mkdir(parents=True,exist_ok=True)
    runtimes=json.loads(run('xcrun','simctl','list','runtimes','-j'))['runtimes']
    runtimes=[r for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier'] and int(r['version'].split('.')[0])>=26]
    if not runtimes:
        (output/'result.json').write_text(json.dumps({'skipped':True,'reason':'No iOS 26 simulator runtime installed'})+'\n')
        print('::warning::UIKit rendering skipped: no iOS 26 simulator runtime installed.');return
    runtime=max(runtimes,key=lambda r:tuple(int(x) for x in r['version'].split('.')))
    types=json.loads(run('xcrun','simctl','list','devicetypes','-j'))['devicetypes']
    chosen=[next(t for t in reversed(types) if t['name'].startswith(prefix)) for prefix in ('iPhone','iPad')]
    app=output/'PadEditorTest.app';app.mkdir()
    sdk=run('xcrun','--sdk','iphonesimulator','--show-sdk-path').strip()
    run('xcrun','--sdk','iphonesimulator','clang','-arch',platform.machine(),'-isysroot',sdk,
        '-mios-simulator-version-min=26.0','-fobjc-arc','-fblocks','-Wall','-Werror=implicit-function-declaration','-DDM_P5R_ONLY=1',
        '-I'+str(HERE.parents[1]/'host'),HERE/'dm_pad.m',HERE/'pad_editor.m',HERE/'t_pad_editor.m',HERE.parents[1]/'host/dm_i18n.c',
        '-framework','UIKit','-framework','Foundation','-framework','QuartzCore','-framework','GameController','-framework','CoreText',
        '-framework','CoreGraphics','-framework','CoreFoundation',
        '-o',app/'PadEditorTest')
    bundle='org.p5r.control-editor-test'
    info=dict(CFBundleExecutable='PadEditorTest',CFBundleIdentifier=bundle,CFBundleName='PadEditorTest',CFBundleVersion='1',
        CFBundleShortVersionString='1',CFBundlePackageType='APPL',MinimumOSVersion='26.0',UIDeviceFamily=[1,2],
        UILaunchScreen={},UIRequiresFullScreen=True,UIInterfaceOrientation='UIInterfaceOrientationLandscapeRight',
        UISupportedInterfaceOrientations=['UIInterfaceOrientationLandscapeRight','UIInterfaceOrientationLandscapeLeft'])
    (app/'Info.plist').write_bytes(plistlib.dumps(info));run('codesign','--force','--sign','-',app)
    results=[]
    for device in chosen:
        name='iPad' if device['name'].startswith('iPad') else 'iPhone'
        udid=run('xcrun','simctl','create','P5R controls '+name,device['identifier'],runtime['identifier']).strip()
        try:
            run('xcrun','simctl','boot',udid);run('xcrun','simctl','bootstatus',udid,'-b',timeout=180)
            run('xcrun','simctl','install',udid,app);run('xcrun','simctl','launch',udid,bundle)
            container=Path(run('xcrun','simctl','get_app_container',udid,bundle,'data').strip())
            result=container/'Documents/pad-editor-result.json'
            deadline=time.monotonic()+30
            while not result.is_file() and time.monotonic()<deadline:time.sleep(.5)
            if not result.is_file():raise RuntimeError(name+' UIKit assertions did not complete')
            value=json.loads(result.read_text());assert value['passed'] and value['width']>value['height'],value
            value['device']=device['name'];results.append(value)
            (output/(name+'-result.json')).write_text(json.dumps(value,indent=2)+'\n')
            run('xcrun','simctl','io',udid,'screenshot',output/(name+'-controls.png'))
            print(name+' PAD EDITOR UIKit OK: '+', '.join(value['checks']),flush=True)
        finally:
            subprocess.run(['xcrun','simctl','shutdown',udid],capture_output=True)
            subprocess.run(['xcrun','simctl','delete',udid],capture_output=True)
    (output/'result.json').write_text(json.dumps({'skipped':False,'passed':True,'devices':results},indent=2)+'\n')
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('output',type=Path);main(parser.parse_args().output)
