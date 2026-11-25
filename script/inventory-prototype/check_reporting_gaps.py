"""Fast red/green replay of a candidate through the production parser/filter."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent


def baseline():
    folder = HERE / 'evidence' / 'lifecycle'
    captures = {row['name']: row for row in json.loads((folder / 'native-captures.json').read_text())}
    result = []
    for screen in json.loads((folder / 'screen-evidence.json').read_text()):
        expected = ['awaitingInput'] if screen['name'].startswith('codex') else ['ready', 'finished']
        result.append({'name': screen['name'], 'payloads': captures[screen['captureName']]['payloads'][:len(screen['nativeActivities'])], 'expected': expected})
    return result


def run(cases):
    with tempfile.TemporaryDirectory(prefix='myterm-reporting-replay-') as work:
        source = Path(work) / 'cases.json'
        source.write_text(json.dumps(cases))
        replay = subprocess.check_output(['/tmp/myterm-replay-native', str(source)], text=True)
        rows = json.loads(replay)
    failed = 0
    for case, row in zip(cases, rows, strict=True):
        actual = row['filteredStates'][-1] if row['filteredStates'] else None
        passed = actual in case['expected']
        failed += not passed
        print(('PASS' if passed else 'FAIL') + ': ' + case['name'] + ': observed ' + str(actual) + ', expected ' + ' or '.join(case['expected']))
    return int(bool(failed))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--candidate', type=Path)
    args = parser.parse_args()
    raise SystemExit(run(json.loads(args.candidate.read_text()) if args.candidate else baseline()))
