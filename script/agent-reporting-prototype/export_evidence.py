"""Retain sanitized native inputs and build native/reordered-delivery cases."""
import hashlib
import json
from pathlib import Path
import shutil

HERE = Path(__file__).resolve().parent
EVIDENCE = HERE / 'evidence'
RUNS = {'codex': Path('/tmp/myterm-reporting-events-codex-jk01is6a'),
        'claude': Path('/tmp/myterm-reporting-events-claude-m3odji_q')}
FIELDS = ['hook_event_name', 'tool_name', 'source', 'session_id', 'turn_id', 'prompt_id', 'tool_use_id',
          'agent_id', 'agentId', 'is_aborted', 'reason', 'decision', 'approver', 'denied', 'is_error', 'observer_error_count']
IDS = ['session_id', 'turn_id', 'prompt_id', 'tool_use_id', 'agent_id', 'agentId']


def export():
    EVIDENCE.mkdir(exist_ok=True)
    private = Path('/Users/gordonbeeming/Developer/artifacts/myterm/private-agent-reporting-prototype')
    private.mkdir(mode=0o700, parents=True, exist_ok=True); private.chmod(0o700)
    captures, cases = {}, []
    for agent, work in RUNS.items():
        raw = (work / 'native-hooks.jsonl').read_bytes()
        copy = private / (agent + '-native-hooks.jsonl'); copy.write_bytes(raw); copy.chmod(0o600)
        terminal = private / (agent + '-terminal.bin'); shutil.copyfile(work / 'terminal.bin', terminal); terminal.chmod(0o600)
        records = []
        for line in raw.splitlines():
            item = json.loads(line); event = {key: item['event'][key] for key in FIELDS if key in item['event']}
            assert event.get('observer_error_count', 0) == 0, 'An incomplete observer run is not compatibility evidence'
            for key in IDS:
                if event.get(key): event[key] = hashlib.sha256(event[key].encode()).hexdigest()[:32]
            records.append({'agent': agent, 'observedUTC': item['observedUTC'], 'observedMonotonicNS': item['observedMonotonicNS'], 'event': event})
        captures[agent] = {'version': '0.160.0' if agent == 'codex' else '2.1.325',
                           'records': records, 'rawSHA256': hashlib.sha256(raw).hexdigest(),
                           'privateRawFile': str(copy), 'terminalSHA256': hashlib.sha256(terminal.read_bytes()).hexdigest(),
                           'privateTerminalFile': str(terminal)}
        for index, item in enumerate(records):
            event = item['event']; kind = event.get('hook_event_name'); expected = None
            if agent == 'codex':
                if kind == 'PreToolUse' and event.get('tool_name') == 'request_user_input': expected = 'awaiting_input'
                if kind == 'PostToolUse' and event.get('tool_name') == 'request_user_input': expected = 'working'
                if kind == 'Interrupt': expected = 'ready'
                if kind == 'Stop': expected = 'finished'
            else:
                if kind == 'mod.tool.start' and event.get('tool_name') == 'AskUserQuestion' and event.get('tool_use_id'): expected = 'awaiting_input'
                if kind == 'mod.tool.decision' and event.get('decision') == 'ask' and event.get('approver') == 'person': expected = 'awaiting_input'
                if kind == 'mod.turn.complete' and event.get('reason') in ['answer', 'aborted']: expected = 'finished' if event['reason'] == 'answer' else 'ready'
            if expected:
                cases.append({'name': agent + ' native ' + kind + ' ' + str(index), 'kind': 'native-input-replay',
                              'agent': agent, 'records': records[:index + 1], 'expectedActivity': expected})

    code = captures['codex']['records']
    waits = [i for i, item in enumerate(code) if item['event'].get('hook_event_name') == 'PreToolUse' and item['event'].get('tool_name') == 'request_user_input']
    old_completions = [row for row in code[:waits[-1]] if row['event'].get('hook_event_name') in ['PostToolUse', 'Stop']]
    for row in old_completions[:2]:
        cases.append({'name': 'old Codex callback after a newer question: ' + row['event']['hook_event_name'],
                      'kind': 'controlled-delivery-replay', 'agent': 'codex',
                      'records': code[:waits[-1] + 1] + [row], 'expectedActivity': 'awaiting_input', 'expectedPending': 1})

    claude = captures['claude']['records']
    completed = [i for i, row in enumerate(claude) if row['event'].get('hook_event_name') == 'mod.tool.complete' and row['event'].get('tool_name') == 'Bash']
    if completed:
        first = completed[0]; completion = claude[first]
        next_wait = next((i for i in range(first + 1, len(claude)) if claude[i]['event'].get('hook_event_name') == 'mod.tool.decision' and claude[i]['event'].get('decision') == 'ask' and claude[i]['event'].get('turn_id') == completion['event'].get('turn_id')), None)
        if next_wait is not None:
            delayed = claude[:first] + claude[first + 1:next_wait + 1]
            cases.append({'name': 'two waits while first completion is held back', 'kind': 'controlled-delivery-replay', 'agent': 'claude', 'records': delayed, 'expectedActivity': 'awaiting_input', 'expectedPending': 2})
            cases.append({'name': 'late first completion preserves second wait', 'kind': 'controlled-delivery-replay', 'agent': 'claude', 'records': delayed + [completion], 'expectedActivity': 'awaiting_input', 'expectedPending': 1})
            cases.append({'name': 'duplicate first completion preserves second wait', 'kind': 'controlled-delivery-replay', 'agent': 'claude', 'records': delayed + [completion, completion], 'expectedActivity': 'awaiting_input', 'expectedPending': 1})
    proof = {name: {'exists': (RUNS['claude'] / name).exists(), 'content': (RUNS['claude'] / name).read_text() if (RUNS['claude'] / name).exists() else None}
             for name in ['myterm-proto-a.txt', 'myterm-proto-b.txt']}
    (EVIDENCE / 'native-inputs.json').write_text(json.dumps(captures, indent=2) + '\n')
    (EVIDENCE / 'cases.json').write_text(json.dumps(cases, indent=2) + '\n')
    (EVIDENCE / 'native-file-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
    print('Exported', len(cases), 'replay checkpoints from', sum(len(x['records']) for x in captures.values()), 'native events')


if __name__ == '__main__':
    export()
