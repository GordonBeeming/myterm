"""Compare every alternate-buffer checkpoint and continuation with native SwiftTerm."""
import argparse
import base64
import datetime
import gzip
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def invoke(exe, value):
    result = subprocess.run([str(exe)], input=json.dumps(value).encode(),
                            capture_output=True, timeout=60,
                            env=dict(os.environ, CELL_WIDTH='9', CELL_HEIGHT='16'))
    if result.returncode:
        raise RuntimeError(result.stderr.decode())
    return json.loads(result.stdout)


def fixtures():
    image = b'\x1b_Ga=t,f=32,s=1,v=1,i=7;/wAA/w==\x1b\\'
    cases = []
    for mode in (1047, 1049):
        enter, leave = f'\x1b[?{mode}h'.encode(), f'\x1b[?{mode}l'.encode()
        for context in ('unused', 'empty-shrink', 'populated', 'inactive-populated'):
            for policy in (0, 1):
                for height in (1, 3):
                    events = []
                    def data(value):
                        events.append({'data': list(value), 'checkpoint': True})
                    def resize(cols, rows):
                        events.append({'resize': [cols, rows], 'checkpoint': True})
                    data(b'normal\r\n'*10 + b'\x1b[6;3H')
                    if context == 'empty-shrink':
                        resize(12, 3)
                        resize(20, 6)
                        data(b'\x1b[6;3H')
                    elif context in ('populated', 'inactive-populated'):
                        data(enter + b'populated\r\n'*9)
                        if context == 'inactive-populated':
                            data(leave)
                        resize(12, 3)
                        resize(20, 6)
                    data(enter + (b'' if context in ('unused', 'empty-shrink') else b'\x1b[6;3H'))
                    data(image + f'\x1b_Ga=p,i=7,p=3,c=2,r={height},C={policy};\x1b\\'.encode())
                    data(b'\x1b[6n')
                    resize(12, 4)
                    resize(20, 6)
                    data(b'\r\n'*12 + b'after')
                    data(b'\x1b_Ga=d,d=i,i=7,p=3;\x1b\\')
                    data(leave + b'\x1b[6n')
                    data(enter + b'\x1b[6n')
                    data(leave)
                    cases.append({'name': f'{mode}-{context}-r{height}-C{policy}', 'events': events})
    for mode in (1047, 1049):
        cases.append({'name': f'{mode}-text-only', 'events': [
            {'data': list(f'\x1b[6;3H\x1b[?{mode}h'.encode()), 'checkpoint': True},
            {'data': list(b'line\r\n'*14), 'checkpoint': True},
            {'resize': [10, 3], 'checkpoint': True},
            {'data': list(b'\x1b[6n'), 'checkpoint': True},
            {'resize': [20, 6], 'checkpoint': True},
            {'data': list(f'\x1b[?{mode}l'.encode()), 'checkpoint': True}]})
    for saved_row, live_row in ((2, 5), (5, 0), (0, 5)):
        cases.append({'name': f'saved-{saved_row}-live-{live_row}', 'events': [
            {'data': list(f'\x1b[?1049h\x1b[{saved_row+1};3H\x1b7\x1b[{live_row+1};4H'.encode()), 'checkpoint': True},
            {'resize': [12, 3], 'checkpoint': True},
            {'data': list(b'\x1b8!\x1b[6n'), 'checkpoint': True},
            {'resize': [20, 6], 'checkpoint': True},
            {'data': list(b'\x1b8?\x1b[6n\x1b[?1049l'), 'checkpoint': True}]})
    for reset in (False, True):
        cases.append({'name': 'unused-grow-reset' if reset else 'unused-grow', 'events': [
            {'resize': [32, 40], 'checkpoint': True},
            {'data': list(b'\x1bc' if reset else b''), 'checkpoint': True},
            {'resize': [20, 6], 'checkpoint': True},
            {'resize': [12, 6], 'checkpoint': True},
            {'resize': [28, 6], 'checkpoint': True},
            {'data': list(b'\x1b[6;3H\x1b[?1049htext\r\n'*2), 'checkpoint': True},
            {'data': list(b'\x1b[6n\x1b[?1049l'), 'checkpoint': True}]})
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', action='append')
    parser.add_argument('--fixture-file', type=Path, help='Replay a retained original fixture list')
    args = parser.parse_args()
    runner_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    build = args.build.resolve()
    sys.path.insert(0, str(build/'foundation'))
    from checkpoint_checks import semantic
    cases = json.loads(args.fixture_file.read_text()) if args.fixture_file else fixtures()
    if args.case:
        cases = [case for case in cases if case['name'] in args.case]
        if len(cases) != len(set(args.case)):
            raise ValueError('Unknown case')
    candidates = invoke(build/'server', cases)
    results, native_controls, behavior_controls = [], [], []
    for case in cases:
        events = [{'sequence': i, 'event': event} for i, event in enumerate(case['events'])]
        reference = invoke(build/'client', {'events': events})
        expected = [semantic(s['nativeCheckpoint']) for s in reference['snapshots']]
        for index, event in enumerate(case['events']):
            data = bytes(event.get('data', []))
            if not args.fixture_file and b'\x1b_Ga=p,i=7,p=3,' in data:
                policy = int(case['name'][-1])
                height = int(case['name'].split('-r')[1].split('-')[0])
                state = expected[index]
                alt = state['alternate']
                placements = state['kitty']['placements']
                image_rows = [i for i, line in enumerate(alt['lines']) if line['images']]
                behavior_controls.append({'case': case['name'], 'kind': 'bottom-image',
                    'cursor': [alt['x'], alt['y']], 'imageRows': image_rows,
                    'passed': [alt['x'], alt['y']] == [2 if policy else 4, 5]
                        and image_rows == list(range(5-height, 5))
                        and len(placements) == 1 and placements[0]['row'] == 5-height
                        and placements[0]['column'] == 2 and placements[0]['rows'] == height
                        and placements[0]['isAlternateBuffer']})
            if not args.fixture_file and b'\x1b_Ga=d,d=i,i=7,p=3;' in data:
                state = expected[index]
                behavior_controls.append({'case': case['name'], 'kind': 'delete-retain-cache',
                    'passed': not state['kitty']['placements'] and len(state['kitty']['cache']) == 1
                        and not any(line['images'] for line in state['alternate']['lines'])})
        for index, snapshot in enumerate(reference['snapshots']):
            raw = plistlib.loads(base64.b64decode(snapshot['nativeCheckpoint']))['state']
            alt = raw['alternateBuffer']
            native_controls.append({'case': case['name'], 'event': index,
                'rows': raw['rows'], 'maximumLines': alt['maximumLines'],
                'history': alt['yBase'], 'lineCount': len(alt['lines']),
                'passed': alt['maximumLines'] == raw['rows'] and alt['yBase'] == 0
                          and len(alt['lines']) <= raw['rows']})
        for checkpoint in candidates[case['name']]['checkpoints']:
            if 'error' in checkpoint:
                results.append({'case': case['name'], 'cut': checkpoint['event'],
                                'error': checkpoint['error'], 'passed': False})
                continue
            cut = checkpoint['event']
            try:
                restored = invoke(build/'client', {'checkpoint': checkpoint['bytes'], 'events': events[cut+1:]})
            except RuntimeError as error:
                results.append({'case': case['name'], 'cut': cut, 'error': str(error), 'passed': False})
                continue
            differences = []
            baseline_replies = reference['snapshots'][cut]['replies']
            for offset, actual in enumerate(restored['snapshots']):
                target = expected[cut+offset]
                value = semantic(actual['nativeCheckpoint'])
                fields = [key for key in target.keys() | value.keys() if target.get(key) != value.get(key)]
                raw = plistlib.loads(base64.b64decode(actual['nativeCheckpoint']))['state']
                alt = raw['alternateBuffer']
                if alt['maximumLines'] != raw['rows'] or alt['yBase'] != 0 or len(alt['lines']) > raw['rows']:
                    fields.append('alternateCapacity')
                if actual['replies'] != reference['snapshots'][cut+offset]['replies'][len(baseline_replies):]:
                    fields.append('replies')
                if fields:
                    differences.append({'offset': offset, 'fields': fields,
                                        'expected': target, 'actual': value})
            if len(restored['snapshots']) != len(events)-cut:
                raise AssertionError('Missing continuation snapshots')
            results.append({'case': case['name'], 'cut': cut, 'passed': not differences,
                            'comparisons': len(restored['snapshots']), 'differences': differences})
    summary = {'cases': len(cases), 'cuts': len(results),
               'comparisons': sum(r.get('comparisons', 0) for r in results),
               'failedCuts': sum(not r['passed'] for r in results),
               'nativeControls': len(native_controls),
               'failedNativeControls': sum(not c['passed'] for c in native_controls),
               'behaviorControls': len(behavior_controls),
               'failedBehaviorControls': sum(not c['passed'] for c in behavior_controls)}
    payload = {'summary': summary, 'fixtures': cases, 'results': results,
               'nativeControls': native_controls, 'behaviorControls': behavior_controls,
               'timestampUtc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
               'binarySha256': {name: hashlib.sha256((build/name).read_bytes()).hexdigest()
                                for name in ('server', 'client')},
               'runnerSha256': runner_hash}
    if runner_hash != hashlib.sha256(Path(__file__).read_bytes()).hexdigest():
        raise RuntimeError('Runner changed during verification')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(gzip.compress(json.dumps(payload).encode(), mtime=0))
    print(json.dumps(summary))
    raise SystemExit(bool(summary['failedCuts'] or summary['failedNativeControls'] or summary['failedBehaviorControls']))


if __name__ == '__main__':
    main()
