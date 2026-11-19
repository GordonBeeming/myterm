"""Observe installed agents through real macOS PTYs, without installing hooks.

Only normalized OSC metadata is retained. Existing provider authentication and
trusted hook configuration are used unchanged. Absence of signals is a gap.
"""
import errno
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
DESTINATION = Path(__file__).resolve().parent / 'evidence'
PROMPT = 'Reply with exactly INVENTORY_NATIVE_OK. Do not call tools or read any files.'
COMMANDS = {
    'claude': ['claude', '-p', PROMPT, '--model', 'sonnet', '--permission-mode', 'plan', '--tools', '', '--output-format', 'json', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}'],
    'codex': ['codex', 'exec', '--skip-git-repo-check', '--sandbox', 'read-only', '--json', PROMPT],
    'antigravity': ['agy', '-p', PROMPT, '--mode', 'plan', '--output-format', 'json'],
    'grok': ['grok', '-p', PROMPT, '--permission-mode', 'plan', '--no-subagents', '--disable-web-search', '--output-format', 'json'],
}


def probe(pair):
    agent, command = pair
    executable = command[0]
    version = subprocess.run([executable, '--version'], capture_output=True, text=True, check=True).stdout.strip()
    with tempfile.TemporaryDirectory(prefix=f'myterm-inventory-{agent}-') as work:
        pid, master = pty.fork()
        if pid == 0:
            os.chdir(work)
            env = dict(os.environ, MYTERM_PANE_ID='inventory-disposable-probe', MYTERM_RESOURCE_DIR=str(ROOT / 'Resources'), TERM='xterm-256color')
            os.execvpe(executable, command, env)
        output = bytearray()
        deadline = time.monotonic() + 150
        timed_out = False
        status = None
        while True:
            if time.monotonic() > deadline:
                timed_out = True
                os.killpg(pid, signal.SIGTERM)
                break
            readable, _, _ = select.select([master], [], [], 1)
            if not readable:
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError as error:
                if error.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > 4 * 1024 * 1024:
                timed_out = True
                os.killpg(pid, signal.SIGTERM)
                break
        os.close(master)
        if timed_out:
            stop_deadline = time.monotonic() + 2
            while time.monotonic() < stop_deadline:
                waited, candidate = os.waitpid(pid, os.WNOHANG)
                if waited:
                    status = candidate
                    break
                select.select([], [], [], 0.05)
            if status is None:
                os.killpg(pid, signal.SIGKILL)
        if status is None:
            _, status = os.waitpid(pid, 0)
        text = output.decode('utf-8', errors='replace')
        markers = []
        for payload in re.findall(r'\x1b\]7337;([^\x1b\x07]*)(?:\x1b\\|\x07)', text):
            fields = dict(field.split('=', 1) for field in payload.split(';') if '=' in field)
            marker = {key: fields.get(key, '') for key in ['agent', 'event', 'turn_start', 'snapshot', 'work_start']}
            marker.update({output: bool(fields.get(source)) for output, source in [('hasTurnID', 'turn'), ('hasToolRequestID', 'tool'), ('hasToolCallID', 'call'), ('hasCapturedTime', 'captured')]})
            markers.append(marker)
        cursor = 0
        for marker in markers:
            if cursor < 3 and marker['agent'] == agent and marker['event'] == ['ready', 'working', 'finished'][cursor]:
                cursor += 1
        success = os.waitstatus_to_exitcode(status) == 0 and not timed_out and cursor == 3
        return {
            'agent': agent, 'version': version, 'exitCode': os.waitstatus_to_exitcode(status),
            'timedOut': timed_out, 'lifecycleSmokePassed': success,
            'oscReports': markers, 'outputSHA256': hashlib.sha256(output).hexdigest(),
            'scope': 'Real installed CLI in a native PTY using existing hooks in print/exec mode; one no-tool turn only. Missing reports here would not establish absence of interactive signals. No permissions, questions, forced exit or detached restoration exercised.',
        }


if __name__ == '__main__':
    DESTINATION.mkdir(parents=True, exist_ok=True)
    output = DESTINATION / 'native-signals.json'
    output.unlink(missing_ok=True)
    results = []
    for pair in COMMANDS.items():
        try:
            results.append(probe(pair))
        except Exception as error:
            results.append({'agent': pair[0], 'lifecycleSmokePassed': False, 'error': str(error)})
    (DESTINATION / 'native-signals.json').write_text(json.dumps(results, indent=2) + '\n')
    for row in results:
        print(row['agent'], row.get('version', 'unavailable'), 'passed', row['lifecycleSmokePassed'], 'events', [event['event'] for event in row.get('oscReports', [])])
    if not all(row['lifecycleSmokePassed'] for row in results):
        raise SystemExit(1)
