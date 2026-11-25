"""Prepare explicit launchd test definitions. Does not install a system service."""
import hashlib
import grp
import json
import os
from pathlib import Path
import plistlib
import pwd
import shlex
import subprocess

if os.getuid() == 0:
    raise SystemExit('Prepare as the selected ordinary user, never root.')

ROOT = Path('/Users/Shared/myterm-probe168')
DEST = Path('/Library/Application Support/MyTermNativeProbe168')
LABEL = 'com.gordonbeeming.myterm.native-probe168'
SERVICE = LABEL + '.disposable-key'
LOGS = Path('/Library/Logs/MyTermNativeProbe168')
owner = pwd.getpwuid(os.getuid())
instance = ROOT / 'instance'
instance.mkdir(mode=0o700, exist_ok=True)
for name in ('stdout.log', 'stderr.log'):
    (ROOT / name).touch(mode=0o600, exist_ok=True)


def definition(binary, daemon):
    result = {
        'Label': LABEL + ('.unattended' if daemon else '.login'),
        'ProgramArguments': [str(binary), 'serve', str(instance), SERVICE],
        'RunAtLoad': True,
        'KeepAlive': True,
        'ThrottleInterval': 10,
        'ExitTimeOut': 5,
        'WorkingDirectory': str(instance),
        'EnvironmentVariables': {'HOME': owner.pw_dir, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'},
        'StandardOutPath': str((LOGS if daemon else ROOT) / 'stdout.log'),
        'StandardErrorPath': str((LOGS if daemon else ROOT) / 'stderr.log'),
        'Umask': 0o077,
    }
    if daemon:
        result['UserName'] = owner.pw_name
        result['GroupName'] = grp.getgrgid(owner.pw_gid).gr_name
    return result


for daemon in (False, True):
    plist = definition(DEST / 'probe' if daemon else ROOT / 'probe', daemon)
    with (ROOT / (plist['Label'] + '.plist')).open('wb') as file:
        plistlib.dump(plist, file)

digest = hashlib.sha256((ROOT / 'probe').read_bytes()).hexdigest()
quote = lambda value: shlex.quote(str(value))
daemon_plist = LABEL + '.unattended.plist'
plist_digest = hashlib.sha256((ROOT / daemon_plist).read_bytes()).hexdigest()
agent = 'gui/' + str(os.getuid()) + '/' + LABEL + '.login'
setup = f'''#!/bin/bash
set -euo pipefail
test "$(id -u)" -eq 0 || {{ echo 'Run this script with sudo yourself.'; exit 1; }}
test "${{SUDO_UID:-}}" = {owner.pw_uid} || {{ echo 'Run sudo from the selected probe owner account.'; exit 1; }}
test ! -e {quote(DEST)} || {{ echo 'Probe destination already exists; inspect it before retrying.'; exit 1; }}
test ! -e {quote('/Library/LaunchDaemons/' + daemon_plist)}
test "$(/usr/bin/shasum -a 256 {quote(ROOT / 'probe')} | /usr/bin/awk '{{print $1}}')" = {quote(digest)}
if /bin/launchctl print {quote(agent)} >/dev/null 2>&1; then
  echo 'Login probe still running. Ask Codex to stop it before installing unattended mode.'
  exit 1
fi
rollback() {{
  result=$?
  trap - ERR EXIT INT TERM HUP
  if /bin/launchctl print {quote('system/' + LABEL + '.unattended')} >/dev/null 2>&1; then
    /bin/launchctl bootout {quote('system/' + LABEL + '.unattended')} || true
  fi
  /bin/rm -f {quote('/Library/LaunchDaemons/' + daemon_plist)} {quote(DEST / 'probe')}
  /bin/rmdir {quote(DEST)} 2>/dev/null || true
  echo 'Setup failed; startup registration/payload rolled back. State, logs and any disposable key retained for diagnosis.'
  exit "$result"
}}
trap rollback ERR
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
/usr/bin/install -d -o root -g wheel -m 755 {quote(DEST)}
/usr/bin/install -o root -g wheel -m 755 {quote(ROOT / 'probe')} {quote(DEST / 'probe')}
test "$(/usr/bin/shasum -a 256 {quote(DEST / 'probe')} | /usr/bin/awk '{{print $1}}')" = {quote(digest)}
test ! -L {quote(LOGS)}
if test -e {quote(LOGS)}; then
  test -d {quote(LOGS)}
  test "$(/usr/bin/stat -f '%u:%g:%Lp' {quote(LOGS)})" = '0:0:755'
else
  /usr/bin/install -d -o root -g wheel -m 755 {quote(LOGS)}
fi
for log in stdout.log stderr.log; do
  test ! -L {quote(LOGS)}/"$log"
  /usr/bin/install -o {owner.pw_uid} -g {owner.pw_gid} -m 600 /dev/null {quote(LOGS)}/"$log"
done
# Creates one random disposable item; never opens an existing MyTerm item or login keychain.
{quote(DEST / 'probe')} provision {quote(SERVICE)}
/usr/bin/install -o root -g wheel -m 644 {quote(ROOT / daemon_plist)} {quote('/Library/LaunchDaemons/' + daemon_plist)}
test "$(/usr/bin/shasum -a 256 {quote('/Library/LaunchDaemons/' + daemon_plist)} | /usr/bin/awk '{{print $1}}')" = {quote(plist_digest)}
/bin/launchctl bootstrap system {quote('/Library/LaunchDaemons/' + daemon_plist)}
ready=0
for attempt in {{1..50}}; do
  if status=$(/usr/bin/sudo -n -u {quote(owner.pw_name)} {quote(DEST / 'probe')} request {quote(instance)} status 2>/dev/null); then
    if echo "$status" | /usr/bin/grep -Eq '(^| )uid={owner.pw_uid}( |$)'; then
      ready=1
      break
    fi
  fi
  /bin/sleep 0.2
done
test "$ready" = 1
echo "$status"
echo "$status" | /usr/bin/grep -Eq '(^| )uid={owner.pw_uid}( |$)'
key_result=$(/usr/bin/sudo -n -u {quote(owner.pw_name)} {quote(DEST / 'probe')} request {quote(instance)} key)
echo "$key_result"
echo "$key_result" | /usr/bin/grep -Eq '^Ok\\("[0-9a-f]{{64}}"\\)$'
/bin/launchctl print {quote('system/' + LABEL + '.unattended')}
trap - ERR EXIT INT TERM HUP
'''
(ROOT / 'install-unattended.sh').write_text(setup)
(ROOT / 'install-unattended.sh').chmod(0o700)
cleanup = f'''#!/bin/bash
set -euo pipefail
test "$(id -u)" -eq 0 || {{ echo 'Run this script with sudo yourself.'; exit 1; }}
if /bin/launchctl print {quote('system/' + LABEL + '.unattended')} >/dev/null 2>&1; then
  /bin/launchctl bootout {quote('system/' + LABEL + '.unattended')}
fi
/bin/rm -f {quote('/Library/LaunchDaemons/' + daemon_plist)}
/bin/rm -f {quote(DEST / 'probe')}
if test -d {quote(DEST)}; then /bin/rmdir {quote(DEST)}; fi
echo 'Probe system service removed. Disposable instance state and key retained.'
'''
(ROOT / 'uninstall-unattended.sh').write_text(cleanup)
(ROOT / 'uninstall-unattended.sh').chmod(0o700)
manifest = {'uid': os.getuid(), 'label': LABEL, 'key_service': SERVICE, 'sha256': digest,
            'source_sha256': hashlib.sha256(Path(__file__).with_name('main.rs').read_bytes()).hexdigest(),
            'rustc': subprocess.check_output(['rustc', '--version'], text=True).strip(),
            'instance': str(instance), 'source_binary': str(ROOT / 'probe'),
            'installed_binary': str(DEST / 'probe'), 'phase': 'prepared; not native product acceptance'}
(ROOT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
