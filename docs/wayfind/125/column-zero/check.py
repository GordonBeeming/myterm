"""Compare native SwiftTerm state with the retained Rust checkpoint candidate."""
import argparse
import gzip
import collections
import json
import os
from pathlib import Path
import subprocess
import sys


def invoke(executable, value):
    result = subprocess.run([str(executable)], input=json.dumps(value).encode(), capture_output=True, timeout=60, env=dict(os.environ, CELL_WIDTH="9", CELL_HEIGHT="16"))
    if result.returncode:
        raise RuntimeError(result.stderr.decode())
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', action='append', help='Run only these named cases')
    args = parser.parse_args()
    build = args.build.resolve()
    sys.path.insert(0, str(build / 'foundation'))
    from checkpoint_checks import semantic
    fixtures = []
    def case(name, chunks):
        fixtures.append({'name':name, 'events':[dict(chunk, checkpoint=True) for chunk in chunks]})
    for alternate in (False, True):
        prefix = b'\x1b[?1049h' if alternate else b''
        buffer = 'alternate' if alternate else 'normal'
        for position, move in [('zero', b'\r'), ('one', b'\r\x1b[C'), ('middle', b'\r\x1b[10G'),
                               ('last', b'\r\x1b[20G'), ('pending', b'')]:
            for context, content in [('single', b'ABCDEFGHIJKLMNOPQRST'),
                                     ('wrapped', b'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'),
                                     ('blank-column', b'short\x1b[20G'),
                                     ('history', b'row\r\n'*48+b'ABCDEFGHIJKLMNOPQRST')]:
                if alternate and context == 'history':
                    continue
                case(f'{buffer}-{context}-{position}', [
                    {'data':list(prefix+content+move)}, {'resize':[10,6]},
                    {'data':list(b'!\x1b[6n')}, {'resize':[20,6]},
                    {'data':list(b'Z\r\nend')}, {'resize':[8,6]}, {'resize':[24,6]}])
        case(f'{buffer}-away-from-content', [
            {'data':list(prefix+b'ABCDEFGHIJKLMNOPQRST\r\nnext\r\n')},
            {'resize':[10,6]}, {'resize':[20,6]}, {'data':list(b'after')}])
    for lines in (5,6,40,46,47,48):
        case(f'history-boundary-{lines}', [
            {'data':list(b'ABCDEFGHIJKLMNOPQRST\r\n'*lines+b'ABCDEFGHIJKLMNOPQRST\r')},
            {'resize':[10,6]}, {'data':list(b'!')}, {'resize':[20,6]},
            {'resize':[10,8]}, {'resize':[20,6]}, {'data':list(b'\r\ntail')}])
    case('normal-wide-boundary', [
        {'data':list('ABCDEFGH界KLMNOPQRST\r'.encode())}, {'resize':[9,6]},
        {'resize':[24,6]}, {'data':list(b'!\r\nend')}, {'resize':[8,6]}])
    case('normal-three-row-middle', [
        {'data':list(b'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghij\x1b[2;1H')},
        {'resize':[10,6]}, {'resize':[24,6]}, {'data':list(b'\x1b[6;1Hafter')}, {'resize':[8,6]}])
    for action, data in [('reset', b'\x1bc'), ('erase-history', b'\x1b[3J'),
                         ('erase-display', b'\x1b[2J\x1b[H'), ('scroll', b'\r\n'*4)]:
        case(f'history-continuation-{action}', [
            {'data':list(b'ABCDEFGHIJKLMNOPQRST\r\n'*48+b'tail\r')},
            {'resize':[10,6]}, {'data':list(data)}, {'resize':[20,6]}, {'data':list(b'after')}])
    for mode in (1047,1049):
        case(f'inactive-normal-{mode}', [
            {'data':list(b'ABCDEFGHIJKLMNOPQRST\r\n'*12+b'cursor\r')},
            {'data':list(f'\x1b[?{mode}h'.encode()+b'ALTERNATE\r')},
            {'resize':[10,6]}, {'data':list(b'!')}, {'resize':[24,6]},
            {'data':list(f'\x1b[?{mode}l'.encode()+b'after')}])
    case('alternate-saved-state-through-clear', [
        {'data':list(b'normal\x1b[?1049h\x1b[3;4Halt\x1b7\x1b[>1u')},
        {'resize':[10,6]}, {'data':list(b'\x1b[?1049l')},
        {'data':list(b'\x1b[?1049h\x1b8!')}, {'resize':[24,6]}])
    case('reactivated-normal-height-shrink', [
        {'data':list(b'\x1b[4;4Htext\x1b[?1049h\x1b[?1049l')},
        {'resize':[8,3]}, {'data':list(b'!')}, {'resize':[24,6]}])
    case('inactive-pending-wrap', [
        {'data':list(b'ABCDEFGHIJKLMNOPQRST\x1b[?1049h')},
        {'resize':[24,6]}, {'data':list(b'\x1b[?1049l!')}, {'resize':[10,6]}])
    for saved in (False, True):
        case('unchanged-size-saved-wrap' if saved else 'unchanged-size-wrap', [
            {'data':list(b'ABCDEFGHIJKLMNOPQRST'+(b'\x1b7' if saved else b''))},
            {'resize':[20,6]}, {'data':list((b'\x1b8' if saved else b'')+b'XY')},
            {'resize':[10,6]}, {'data':list(b'after')}])
    case('saved-cursor-reflow', [
        {'data':list(b'ABCDEFGHIJKLMNOPQRST\r\nnext\x1b7\r\n')},
        {'resize':[10,6]}, {'data':list(b'\x1b8!')}, {'resize':[24,6]}, {'data':list(b'\x1b8?')}])
    if args.case:
        fixtures = [f for f in fixtures if f['name'] in args.case]
        if len(fixtures) != len(set(args.case)):
            raise ValueError('unknown case')
    candidates = invoke(build / 'server', fixtures)
    results = []
    for fixture in fixtures:
        events = [{'sequence':i, 'event':event} for i,event in enumerate(fixture['events'])]
        reference = invoke(build / 'client', {'events':events})
        for checkpoint in candidates[fixture['name']]['checkpoints']:
            if 'error' in checkpoint:
                results.append({'case':fixture['name'], 'cut':checkpoint['event'], 'passed':False,
                                'checkpointError':checkpoint['error']})
                continue
            cut = checkpoint['event']
            try:
                restored = invoke(build / 'client', {'checkpoint':checkpoint['bytes'], 'events':events[cut+1:]})
            except RuntimeError as error:
                results.append({'case':fixture['name'], 'cut':cut, 'passed':False, 'importError':str(error)})
                continue
            for offset, (expected, actual) in enumerate(zip(reference['snapshots'][cut:], restored['snapshots'], strict=True)):
                a, b = semantic(expected['nativeCheckpoint']), semantic(actual['nativeCheckpoint'])
                differences = {key:{'expected':a[key], 'actual':b[key]} for key in a if a[key] != b[key]}
                replies = expected['replies'][len(reference['snapshots'][cut]['replies']):]
                if actual['replies'] != replies:
                    differences['replies'] = {'expected':replies, 'actual':actual['replies']}
                results.append({'case':fixture['name'], 'cut':cut, 'event':cut+offset, 'passed':not differences, 'differences':differences})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    failed = sum(not r['passed'] for r in results)
    summary = {'cases':len(fixtures), 'comparisons':len(results), 'failed':failed,
               'failedCases':dict(collections.Counter(r['case'] for r in results if not r['passed']))}
    payload = json.dumps({'summary':summary, 'fixtures':fixtures, 'comparisons':results}, indent=2).encode()+b'\n'
    if args.output.suffix == '.gz':
        with gzip.open(args.output, 'wb') as stream:
            stream.write(payload)
    else:
        args.output.write_bytes(payload)
    print(json.dumps(summary))
    raise SystemExit(bool(failed))


if __name__ == '__main__':
    main()
