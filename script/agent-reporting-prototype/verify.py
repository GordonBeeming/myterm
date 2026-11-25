"""Deterministic candidate checks; native input and delivery-replay scopes retained."""
import json
from pathlib import Path
import subprocess

from candidate import replay

HERE = Path(__file__).resolve().parent
EVIDENCE = HERE / 'evidence'
MAP = {'awaiting_input': 'awaitingInput', 'working': 'working', 'ready': 'ready', 'finished': 'finished', 'exited': 'exited'}


def verify():
    cases = json.loads((EVIDENCE / 'cases.json').read_text())
    results, wire_cases = [], []
    for case in cases:
        candidate = replay(case['agent'], case['records'])
        passed = candidate.activity == case['expectedActivity'] and ('expectedPending' not in case or len(candidate.waits) == case['expectedPending'])
        results.append({'name': case['name'], 'kind': case['kind'], 'passed': passed, 'activity': candidate.activity,
                        'pending': len(candidate.waits), 'expected': case['expectedActivity']})
        wire_cases.append({'name': case['name'], 'payloads': [row['payload'] for row in candidate.outputs], 'expected': [MAP[case['expectedActivity']]]})
    (EVIDENCE / 'wire-cases.json').write_text(json.dumps(wire_cases, indent=2) + '\n')
    (EVIDENCE / 'verification.json').write_text(json.dumps(results, indent=2) + '\n')
    print(sum(row['passed'] for row in results), '/', len(results), 'candidate state checks passed')
    for row in results:
        if not row['passed']: print(row)
    if not all(row['passed'] for row in results): raise SystemExit(1)
    subprocess.run(['python3', str(HERE.parent / 'inventory-prototype/check_reporting_gaps.py'), '--candidate', str(EVIDENCE / 'wire-cases.json')], check=True)


if __name__ == '__main__':
    verify()
