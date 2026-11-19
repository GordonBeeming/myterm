"""Exercise only the disposable login probe. Leaves it unloaded for mode switching."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import re
import subprocess
import time

root = Path('/Users/Shared/myterm-probe168')
binary = root / 'probe'
instance = root / 'instance'
label = f'gui/{os.getuid()}/com.gordonbeeming.myterm.native-probe168.login'


def request(command):
    return subprocess.check_output([str(binary), 'request', str(instance), command], text=True, stderr=subprocess.DEVNULL, timeout=5).strip()


def status():
    return dict(field.split('=', 1) for field in request('status').split())


def restarted(previous):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        try:
            current = status()
            if current['pid'] != previous['pid']:
                return current
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass
        time.sleep(.2)
    raise RuntimeError('launchd did not restart the probe within 25 seconds')


initial = status()
job = subprocess.check_output(['launchctl', 'print', label], text=True)
assert re.search(r'\bpid = ' + re.escape(initial['pid']) + r'\b', job)
assert int(initial['uid']) == os.getuid()
assert 'OSStatus=-25300' in request('key')
for _ in range(3):
    assert status()['pid'] == initial['pid']
duplicate = subprocess.run([str(binary), 'serve', str(instance), 'unused'], capture_output=True, text=True, timeout=5)
assert duplicate.returncode != 0 and 'already owned' in duplicate.stderr
os.kill(int(initial['pid']), signal.SIGKILL)
second = restarted(initial)
start = time.monotonic()
os.kill(int(second['pid']), signal.SIGKILL)
third = restarted(second)
interval = time.monotonic() - start
assert interval >= 8, f'expected throttled restart, got {interval:.2f}s'
assert initial['instance'] == second['instance'] == third['instance']
subprocess.run(['launchctl', 'bootout', label], check=True, timeout=10)
time.sleep(12)
unloaded = subprocess.run(['launchctl', 'print', label], capture_output=True, text=True)
assert unloaded.returncode != 0
assert (instance / 'instance-id').exists()
evidence = {
    'at_utc': datetime.now(timezone.utc).isoformat(),
    'os': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
    'initial': initial, 'after_crash': second, 'after_second_crash': third,
    'second_restart_seconds': round(interval, 3), 'duplicate_owner_refused': True,
    'missing_item_osstatus': -25300, 'deliberate_bootout_stayed_stopped_seconds': 12,
    'state_retained_after_unload': True,
    'limits': 'Disposable Rust service probe. No PTY, phone, transport, updater, real installer or product acceptance.'
}
(root / 'login-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
print(json.dumps(evidence, indent=2))
