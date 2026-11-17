"""Measure Kitty placement differences without changing either native engine."""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys


def command(keys, payload=''):
    return f'\x1b_G{keys};{payload}\x1b\\'.encode()


def fixtures():
    image = command('a=t,f=32,s=2,v=2,i=1',
                    base64.b64encode(bytes([255, 0, 0, 255, 0, 255, 0, 255,
                                           0, 0, 255, 255, 255, 255, 0, 255])).decode())
    place = command('a=p,i=1,p=1,c=2,r=2,C=1')
    cases = []

    def add(name, chunks):
        cases.append({'name': name, 'events': [
            {'data': list(chunk), 'checkpoint': True} for chunk in chunks]})

    add('ordinary-control', [image + place, b'after', command('a=d,d=i,i=1,p=1')])
    add('virtual-explicit', [image + command('a=p,i=1,p=1,c=2,r=2,U=1'),
                            b'after', command('a=d,d=i,i=1,p=1')])
    add('virtual-default-size', [image + command('a=p,i=1,p=1,U=1'), b'after'])
    add('virtual-pending-combined', [command('a=T,f=32,s=1,v=1,i=1,p=1,U=1,c=2,r=2,m=1', '/wAA'),
                                     command('m=0', '/w=='), b'after'])
    add('virtual-completed-combined', [command('a=T,f=32,s=1,v=1,i=1,p=1,U=1,c=2,r=2', '/wAA/w=='),
                                       b'after'])
    add('relative', [image + place, b'\x1b[4;6H' + command('a=p,i=1,p=2,P=1,Q=1,H=1,V=1,c=1,r=1'),
                     b'after', command('a=d,d=i,i=1,p=1')])
    add('relative-negative-offset', [b'\x1b[3;3H' + image + place,
                                    command('a=p,i=1,p=2,P=1,Q=1,H=-1,V=-1,c=1,r=1'), b'after'])
    add('relative-missing-parent', [image + command('a=p,i=1,p=2,P=1,Q=99,c=1,r=1'), b'after'])
    add('relative-self-cycle', [image + place,
                              command('a=p,i=1,p=1,P=1,Q=1,c=1,r=1'), b'after'])
    add('relative-two-node-cycle', [image + place,
                                   command('a=p,i=1,p=2,P=1,Q=1,c=1,r=1'),
                                   command('a=p,i=1,p=1,P=1,Q=2,c=1,r=1'), b'after'])
    add('virtual-relative-invalid', [image + place,
                                    command('a=p,i=1,p=2,P=1,Q=1,U=1,c=1,r=1'), b'after'])
    add('automatic-placement', [image + command('a=p,i=1,c=1,r=1,C=1'), b'after',
                                command('a=d,d=i,i=1')])
    add('crop', [image + command('a=p,i=1,p=1,x=1,y=0,w=1,h=2,c=1,r=2,C=1'), b'after'])
    add('offset', [image + command('a=p,i=1,p=1,X=2,Y=3,c=1,r=1,C=1'), b'after'])
    add('overlap', [image + place, command('a=p,i=1,p=2,c=1,r=1,z=2,C=1'),
                    command('a=d,d=i,i=1,p=2'), b'after'])
    return cases


def invoke(exe, request, env):
    result = subprocess.run([str(exe)], input=json.dumps(request).encode(),
                            capture_output=True, env=env, timeout=60)
    if result.returncode:
        raise RuntimeError(f'{exe.name} exited {result.returncode}: {result.stderr.decode()}')
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build = args.build.resolve()
    sys.path.insert(0, str(build / 'foundation'))
    from checkpoint_checks import semantic
    env = dict(os.environ, CELL_WIDTH='9', CELL_HEIGHT='16')
    cases = fixtures()
    candidates = invoke(build / 'server', cases, env)
    results = []
    for case in cases:
        events = [{'sequence': i, 'event': event} for i, event in enumerate(case['events'])]
        reference = invoke(build / 'client', {'events': events}, env)
        candidate = candidates[case['name']]
        if len(reference['snapshots']) != len(events) or len(candidate['snapshots']) != len(events):
            raise ValueError(f"{case['name']}: incomplete engine capture")
        if [c['event'] for c in candidate['checkpoints']] != list(range(len(events))):
            raise ValueError(f"{case['name']}: incomplete checkpoint capture")
        entry = {'name': case['name'], 'native': [], 'candidate': [], 'restorations': []}
        for snapshot in reference['snapshots']:
            state = semantic(snapshot['nativeCheckpoint'])
            active = state['alternate'] if state['alternateActive'] else state['normal']
            entry['native'].append({'cursor': [active['x'], active['y']],
                                    'replies': snapshot['replies'], 'kitty': state['kitty']})
        for expected, snapshot in zip(entry['native'], candidate['snapshots'], strict=True):
            entry['candidate'].append({'cursor': snapshot['cursor'], 'replies': snapshot['replies'],
                                       'cursorMatches': snapshot['cursor'] == expected['cursor'],
                                       'repliesMatch': snapshot['replies'] == expected['replies']})
        for checkpoint in candidate['checkpoints']:
            cut = checkpoint['event']
            trial = {'cut': cut, 'comparisons': []}
            if 'error' in checkpoint:
                trial['exportError'] = checkpoint['error']
            else:
                try:
                    restored = invoke(build / 'client', {'checkpoint': checkpoint['bytes'],
                                                         'events': events[cut + 1:]}, env)
                except RuntimeError as error:
                    trial['importError'] = str(error)
                else:
                    for offset, (expected, actual) in enumerate(zip(reference['snapshots'][cut:],
                                                                    restored['snapshots'], strict=True)):
                        a, b = semantic(expected['nativeCheckpoint']), semantic(actual['nativeCheckpoint'])
                        fields = [key for key in a if a[key] != b[key]]
                        baseline = reference['snapshots'][cut]['replies']
                        if actual['replies'] != expected['replies'][len(baseline):]:
                            fields.append('replies')
                        trial['comparisons'].append({'offset': offset, 'fields': fields,
                                                     'passed': not fields})
            entry['restorations'].append(trial)
        results.append(entry)
    summary = {
        'cases': len(results),
        'fullyMatchingCases': [r['name'] for r in results if all(
            not any(key in t for key in ('exportError', 'importError')) and
            all(c['passed'] for c in t['comparisons']) for t in r['restorations'])],
        'comparisons': sum(len(t['comparisons']) for r in results for t in r['restorations']),
        'matchingComparisons': sum(c['passed'] for r in results for t in r['restorations']
                                   for c in t['comparisons']),
        'exportErrors': sum('exportError' in t for r in results for t in r['restorations']),
        'importErrors': sum('importError' in t for r in results for t in r['restorations']),
    }
    report = {'run': {'time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      'platform': platform.platform(), 'build': str(build),
                      'sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in (build / 'server', build / 'client', Path(__file__),
                                           build / 'foundation/checkpoint_checks.py')},
                      'sourceSha256': {name: hashlib.sha256((build / 'native' / name).read_bytes()).hexdigest()
                                      for name in ('source/wezterm-escape-parser/src/apc.rs',
                                                   'source/term/src/terminalstate/kitty.rs',
                                                   'source/term/src/terminalstate/prototype-kitty.rs',
                                                   'SwiftTerm/Sources/SwiftTerm/KittyGraphics.swift',
                                                   'SwiftTerm/Sources/SwiftTerm/CheckpointBridge.swift')}},
              'summary': summary, 'fixtures': cases, 'results': results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as stream:
        json.dump(report, stream, indent=2)
        stream.write('\n')
    print(json.dumps(summary))


if __name__ == '__main__':
    main()
