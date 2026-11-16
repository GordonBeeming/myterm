"""Observe installed CLI event coverage using invocation-only hook definitions.

Codex hooks still require normal review/trust. No trust-bypass flags are used.
Claude settings are invocation-only. Existing hook/settings files are untouched.
"""
import argparse
import hashlib
import json
from pathlib import Path
import select
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'inventory-prototype'))
from lifecycle_probe import Session

QUESTION = 'Use only your built-in AskUserQuestion tool to ask Alpha or Beta and wait. After I answer, reply COMPLETE. If I cancel, end the turn without retrying. Do not read or write files, use other tools, or delegate.'
CODEX_QUESTION = 'Use only the blocking request_user_input tool, not request_user_input_async, to ask Alpha or Beta. Wait for my answer. After my answer, reply COMPLETE. Do not use other tools.'


def configuration(agent, directory):
    command = shlex.join([sys.executable, str(HERE / 'observe.py'), agent, str(directory)])
    events = (['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse', 'PostToolUseFailure', 'PostToolBatch', 'PermissionDenied', 'Stop', 'StopFailure', 'SessionEnd'] if agent == 'claude' else
              ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PermissionRequest', 'PostToolUse', 'Stop', 'Interrupt', 'SessionEnd'])
    config = {'hooks': {event: [{'hooks': [{'type': 'command', 'command': command, 'timeout': 3 if event in ['Interrupt', 'SessionEnd'] else 5}]}] for event in events}}
    if agent == 'claude':
        config['permissions'] = {'ask': ['Bash']}
    return config


def run(agent, mod=False):
    work = Path(tempfile.mkdtemp(prefix=f'myterm-reporting-events-{agent}-'))
    config = configuration(agent, work)
    path = work / 'invocation-hooks.json'
    path.write_text(json.dumps(config, indent=2))
    if agent == 'claude':
        command = ['claude', '--permission-mode', 'manual', '--settings', str(path), '--tools', 'AskUserQuestion,Bash', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', '--', QUESTION]
        if mod:
            directory = work / 'mod'
            shutil.copytree(HERE / 'claude-mod', directory)
            module = directory / 'hooks' / 'register.js'
            source = module.read_text().replace('__MYTERM_PYTHON__', json.dumps(sys.executable)).replace('__MYTERM_OBSERVER__', json.dumps(str(HERE / 'observe.py'))).replace('__MYTERM_CAPTURE__', json.dumps(str(work)))
            module.write_text(source)
            command[1:1] = ['--plugin-dir', str(directory)]
    else:
        command = ['codex', '--no-alt-screen', '--sandbox', 'read-only', '--ask-for-approval', 'on-request']
        for event, groups in config['hooks'].items():
            handler = groups[0]['hooks'][0]
            value = '[{hooks=[{type="command",command=' + json.dumps(handler['command']) + ',timeout=' + str(handler['timeout']) + '}]}]'
            command.extend(['-c', 'hooks.' + event + '=' + value])
    version = subprocess.check_output([command[0], '--version'], text=True).strip()
    session = Session(agent, command, str(work))
    actions = []

    def describe(label, include_tail=False):
        source = work / 'native-hooks.jsonl'
        records = [json.loads(line) for line in source.read_text().splitlines()] if source.exists() else []
        summary = [{'event': row['event'].get('hook_event_name'), 'tool': row['event'].get('tool_name'),
                    'hasCallID': bool(row['event'].get('tool_use_id')), 'keys': sorted(row['event'])} for row in records]
        output = {'agent': agent, 'version': version, 'directory': str(work), 'pid': session.pid, 'status': session.status,
                  'observedHooks': summary, 'actions': actions}
        if include_tail:
            output['tail'] = session.text()[-2200:]
        (work / 'driver.json').write_text(json.dumps(output, indent=2) + '\n')
        print(json.dumps(output, indent=2), flush=True)

    try:
        session.wait(lambda s: bool(s.data), 15)
        describe('Startup', True)
        while True:
            ready, _, _ = select.select([sys.stdin] + ([session.fd] if session.status is None else []), [], [], 1)
            if session.fd in ready:
                session.read(0)
            if session.status is not None:
                describe('Native CLI exited'); break
            if sys.stdin not in ready:
                continue
            line = sys.stdin.readline()
            if not line:
                break
            action = json.loads(line)
            if action.get('stop'):
                break
            while select.select([session.fd], [], [], 0)[0] and session.status is None:
                session.read(0)
            if session.status is not None:
                break
            keys = action.get('send', '')
            if action.get('question'):
                keys = QUESTION if agent == 'claude' else CODEX_QUESTION
            before = len(session.data)
            if keys:
                session.send(keys)
            deadline = time.monotonic() + min(action.get('seconds', 2), 30)
            while time.monotonic() < deadline and session.status is None:
                session.read(min(1, max(0, deadline - time.monotonic())))
            actions.append({'label': action.get('label', 'Observed action'), 'keysSHA256': hashlib.sha256(keys.encode()).hexdigest(), 'startByteOffset': before, 'endByteOffset': len(session.data), 'observedMonotonicNS': time.monotonic_ns()})
            describe(action.get('label', 'Observed action'), action.get('includeTail', False))
    finally:
        session.stop()
        (work / 'cleanup.json').write_text(json.dumps(session.cleanup, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('agent', choices=['claude', 'codex'])
    parser.add_argument('--mod', action='store_true')
    args = parser.parse_args()
    if args.mod and args.agent != 'claude':
        parser.error('--mod applies only to Claude')
    run(args.agent, args.mod)
