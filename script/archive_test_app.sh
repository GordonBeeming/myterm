#!/usr/bin/env bash
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo 'usage: archive_test_app.sh <retired-myterm-app> [archive-directory]' >&2
  exit 2
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT_DIR" "$@" <<'PY'
from pathlib import Path
import os,plistlib,subprocess,sys,uuid
root=Path(sys.argv[1])
source=Path(sys.argv[2]).expanduser().resolve()
archive=(Path(sys.argv[3]).expanduser() if len(sys.argv)==4 else
         Path.home()/'Library/Application Support/myterm/AppArchives').resolve()
if source.suffix.lower()!='.app' or source.name.lower() in {'myterm.app','myterm-dev.app'}:
    raise SystemExit('Only a named retired test copy can be archived; keep the installed app in place.')
info=plistlib.loads((source/'Contents/Info.plist').read_bytes())
if not info.get('CFBundleIdentifier','').startswith('com.gordonbeeming.myterm'):
    raise SystemExit('This is not a MyTerm app copy.')
if archive.is_relative_to(Path('/Applications')) or archive.is_relative_to(Path.home()/'Applications') or archive.is_relative_to(source):
    raise SystemExit('Archives must be outside Applications and outside the app being archived.')
executable=str(source/'Contents/MacOS'/info['CFBundleExecutable'])
for row in subprocess.check_output(['ps','-axo','comm='],text=True).splitlines():
    if row.strip()==executable:
        raise SystemExit('Quit this test copy before archiving it.')
schemes={s for t in info.get('CFBundleURLTypes',[]) for s in t.get('CFBundleURLSchemes',[]) if s.startswith('myterm')}
for scheme in schemes:
    result=subprocess.run(['bash',str(root/'script/check_callback_routing.sh'),str(source),scheme],capture_output=True,text=True)
    if result.returncode==0:
        raise SystemExit('This copy is the current callback handler. Repair the installed app’s route before archiving it.')
    if 'macOS is routing sign-in to another app copy' not in result.stderr:
        raise SystemExit('Could not verify that this copy is inactive; it was left in place.')
archive.mkdir(parents=True,exist_ok=True)
target=archive/(source.name+'.'+str(uuid.uuid4())+'.disabled')
register='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
result=subprocess.run([register,'-u',str(source)],capture_output=True,text=True)
if result.returncode and '-10814' not in result.stdout+result.stderr:
    raise SystemExit('Could not unregister the test copy; it was left in place.')
try:
    os.rename(source,target)
except OSError:
    subprocess.run([register,'-f',str(source)],check=True)
    raise
print('Preserved retired app at',target)
PY
