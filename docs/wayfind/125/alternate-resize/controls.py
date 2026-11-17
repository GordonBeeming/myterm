"""Check retained alternate saved rows and reject malformed bridge coordinates."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from check import fixtures, invoke


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build = args.build.resolve()
    sys.path.insert(0, str(build/'foundation'))
    from checkpoint_checks import semantic
    case = next(c for c in fixtures() if c['name'] == 'saved-5-live-0')
    candidate = invoke(build/'server', [case])[case['name']]['checkpoints'][1]
    sample = json.loads(bytes(candidate['bytes']))
    assert sample['state']['alternate']['saved']['y'] == 5
    assert sample['state']['rows'] == 3
    restored = invoke(build/'client', {'checkpoint': candidate['bytes'], 'events': []})
    assert semantic(restored['snapshots'][0]['nativeCheckpoint'])['alternate']['savedCursor'][1] == 5
    failures = []
    for buffer, field, value, diagnostic in [
        ('alternate', 'saved', -1, 'bridge saved cursor bounds'),
        ('alternate', 'saved', 1000, 'bridge saved cursor bounds'),
        ('normal', 'saved', 3, 'bridge saved cursor bounds'),
        ('alternate', 'defaultSavedY', -1, 'bridge line limit'),
        ('alternate', 'defaultSavedY', 1000, 'bridge line limit'),
        ('normal', 'defaultSavedY', 3, 'bridge line limit'),
        ('alternate', 'cursor', 3, 'bridge inactive cursor bounds')]:
        bad = copy.deepcopy(sample)
        target = bad['state'][buffer]
        if field == 'saved':
            target[field]['y'] = value
        elif field == 'cursor':
            target[field][1] = value
        else:
            target[field] = value
        request = {'checkpoint': list(json.dumps(bad).encode()), 'events': []}
        result = subprocess.run([str(build/'client')], input=json.dumps(request).encode(),
                                capture_output=True, timeout=60)
        assert result.returncode != 0 and diagnostic in result.stderr.decode(), result.stderr.decode()
        failures.append({'buffer': buffer, 'field': field, 'value': value, 'rejected': True})
    accepted = []
    for field in ('saved', 'defaultSavedY'):
        value = copy.deepcopy(sample)
        alt = value['state']['alternate']
        if field == 'saved':
            alt['saved']['y'] = 999
        else:
            alt['saved'] = None
            alt['defaultSavedY'] = 999
        trace = invoke(build/'client', {'checkpoint': list(json.dumps(value).encode()),
            'events': [{'sequence': candidate['event']+1, 'event': {'data': list(b'\x1b8\x1b[6n')}}]})
        before, after = [semantic(s['nativeCheckpoint']) for s in trace['snapshots']]
        assert before['alternate']['savedCursor'][1] == 999
        assert after['alternate']['y'] == 2
        accepted.append({'field': field, 'retainedRow': 999, 'restoredRow': 2})
    positive_trim = []
    for saved_row in (4, 5):
        fixture = copy.deepcopy(case)
        fixture['name'] = f'saved-{saved_row}-live-5'
        fixture['events'][0]['data'] = list(
            f'\x1b[?1049h\x1b[{saved_row+1};3H\x1b7\x1b[6;4H'.encode())
        fixture['events'] = fixture['events'][:2]
        produced = invoke(build/'server', [fixture])[fixture['name']]['checkpoints'][1]
        request = {'checkpoint': produced['bytes'], 'events': [
            {'sequence': 2, 'event': {'data': list(b'\x1b8\x1b[6n')}}]}
        restored = invoke(build/'client', request)
        native = invoke(build/'client', {'events': [
            {'sequence': i, 'event': event} for i, event in enumerate(fixture['events'])] + request['events']})
        before, after = [semantic(s['nativeCheckpoint']) for s in restored['snapshots']]
        assert before['alternate']['savedCursor'][1] == saved_row-3
        assert after['alternate']['y'] == saved_row-3
        assert after == semantic(native['snapshots'][-1]['nativeCheckpoint'])
        positive_trim.append({'savedRow': saved_row, 'trimmed': 3, 'retainedAndRestoredRow': saved_row-3})
    result = {'validHistoricalRowAccepted': 5, 'rejections': failures, 'upperBoundControls': accepted,
              'positiveTrimControls': positive_trim,
              'runnerSha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              'matrixRunnerSha256': hashlib.sha256(Path(__file__).with_name('check.py').read_bytes()).hexdigest(),
              'binarySha256': {name: hashlib.sha256((build/name).read_bytes()).hexdigest()
                               for name in ('server', 'client')}}
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({'rejected': len(failures), 'upperBoundControls': len(accepted),
                      'positiveTrimControls': len(positive_trim)}))


if __name__ == '__main__':
    main()
