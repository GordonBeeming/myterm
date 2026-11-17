"""Compare real native SwiftTerm continuations with fresh Rust-checkpoint imports."""
import argparse
import copy
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys


def invoke(exe, value, env=None, reject=False):
    result = subprocess.run([str(exe)], input=json.dumps(value).encode(), capture_output=True,
                            timeout=60, env=env)
    if reject:
        assert result.returncode != 0, 'malformed checkpoint accepted'
        return result.stderr.decode()
    if result.returncode:
        raise RuntimeError(result.stderr.decode())
    return json.loads(result.stdout)


def command(control, payload=''):
    return f'\x1b_G{control};{payload}\x1b\\'.encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--old-client', type=Path, required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--exercise-empty-alternate-resize', action='store_true',
                        help='Reproduce the separate native alternate-buffer capacity failure')
    args = parser.parse_args()
    out = args.evidence
    out.mkdir(parents=True)
    build = args.build.resolve()
    sys.path.insert(0, str(build / 'foundation'))
    from checkpoint_checks import semantic
    server, client = build / 'server', build / 'client'
    env = dict(os.environ, CELL_WIDTH='9', CELL_HEIGHT='16')
    image = command('a=t,f=32,s=1,v=1,i=7', '/wAA/w==')
    place = command('a=p,i=7,p=3,c=1,r=1,C=1')
    scroll = b'\r\n' * 65
    alternate_creation = b'' if args.exercise_empty_alternate_resize else b'\x1b[H'
    fixtures = []
    def case(name, chunks):
        fixtures.append({'name':name, 'events':[{'data':list(chunk),'checkpoint':True} for chunk in chunks]})
    case('scrolled-record', [image+place+scroll, b'after'])
    case('delete-placement-retain-cache', [image+place+scroll,
        command('a=d,d=i,i=7,p=3'), place, command('a=d,d=I,i=7')])
    case('reuse-placement', [image+place+scroll,
        b'\x1b[3;5H'+command('a=p,i=7,p=3,c=2,r=2,C=1,z=-2'), scroll,
        command('a=d,d=i,i=7,p=3'), place])
    case('nonorigin-scroll', [b'\x1b[4;6H'+image+place, scroll, place])
    case('partial-stripes', [image+command('a=p,i=7,p=3,c=2,r=3,C=1'), b'\r\n'*47, scroll])
    for policy in (0,1):
        case(f'bottom-tall-C{policy}', [image+scroll, b'\x1b[6;3H'+command(f'a=p,i=7,p=3,c=2,r=3,C={policy}'),
            command('a=d,d=i,i=7,p=3')])
    case('multiple-records', [image+place+command('a=p,i=7,p=4,c=1,r=1,C=1')+scroll,
        command('a=d,d=i,i=7,p=3'), command('a=p,i=7,p=5,c=1,r=1,C=1')])
    case('alternate-return', [image+place+scroll, b'\x1b[?1049h',
        alternate_creation+image+command('a=p,i=7,p=4,c=1,r=1,C=1'), b'\x1b[?1049l', place])
    case('replace-across-buffers', [image+place+scroll,
        b'\x1b[?1049h'+alternate_creation+image+place, b'\x1b[?1049l', image+place])
    case('reset', [image+place+scroll, b'\x1bc', image+place])
    (out / 'fixtures.json').write_text(json.dumps(fixtures, indent=2)+'\n')
    candidates = invoke(server, fixtures, env)
    results = []
    red = None
    sample = None
    for fixture in fixtures:
        events = [{'sequence':i,'event':e} for i,e in enumerate(fixture['events'])]
        reference = invoke(client, {'events':events})
        for checkpoint in candidates[fixture['name']]['checkpoints']:
            if 'error' in checkpoint:
                raise RuntimeError(f"{fixture['name']}: {checkpoint['error']}")
            cut = checkpoint['event']
            request = {'checkpoint':checkpoint['bytes'], 'events':events[cut+1:]}
            restored = invoke(client, request)
            differences = []
            for offset,(expected,actual) in enumerate(zip(reference['snapshots'][cut:], restored['snapshots'], strict=True)):
                a,b = semantic(expected['nativeCheckpoint']),semantic(actual['nativeCheckpoint'])
                fields = [key for key in a if a[key] != b[key]]
                baseline_replies = reference['snapshots'][cut]['replies']
                if actual['replies'] != expected['replies'][len(baseline_replies):]:
                    fields.append('replies')
                if fields:
                    differences.append({'offset':offset,'fields':fields,
                        'expectedKitty':a['kitty'],'actualKitty':b['kitty']})
            results.append({'case':fixture['name'],'cut':cut,'passed':not differences,
                            'checkpointBytes':checkpoint['size'],'differences':differences})
            if sample is None:
                sample = json.loads(bytes(checkpoint['bytes']))
                expected = semantic(reference['snapshots'][0]['nativeCheckpoint'])
                old = invoke(args.old_client, request)
                old_state = semantic(old['snapshots'][0]['nativeCheckpoint'])
                red = {'referencePlacements':expected['kitty']['placements'],
                       'oldPlacements':old_state['kitty']['placements'],
                       'cacheMatches':expected['kitty']['cache']==old_state['kitty']['cache']}
                assert len(red['referencePlacements'])==1 and red['oldPlacements']==[] and red['cacheMatches']
    (out/'continuations.json').write_text(json.dumps({'red':red,'comparisons':results},indent=2)+'\n')
    controls = {}
    record = sample['state']['kitty']['placementBuffers'][0]
    changes = {
        'duplicate': lambda s:s['state']['kitty']['placementBuffers'].append(copy.deepcopy(record)),
        'dangling-image': lambda s:s['state']['kitty']['placementBuffers'][0].update(id=999),
        'missing-placement-id': lambda s:s['state']['kitty']['placementBuffers'][0].update(placement=None),
        'negative-row': lambda s:s['state']['kitty']['placementBuffers'][0].update(row=-1),
        'oversized-dimension': lambda s:s['state']['kitty']['placementBuffers'][0].update(rows=2049),
        'negative-image-row': lambda s:s['state']['kitty']['placementBuffers'][0].update(imageRow=-1),
        'oversized-image-column': lambda s:s['state']['kitty']['placementBuffers'][0].update(imageColumn=1001),
        'oversized-column': lambda s:s['state']['kitty']['placementBuffers'][0].update(column=1001),
        'oversized-row': lambda s:s['state']['kitty']['placementBuffers'][0].update(row=1041),
        'zero-columns': lambda s:s['state']['kitty']['placementBuffers'][0].update(columns=0),
        'oversized-offset-x': lambda s:s['state']['kitty']['placementBuffers'][0].update(pixelOffsetX=1025),
        'oversized-offset-y': lambda s:s['state']['kitty']['placementBuffers'][0].update(pixelOffsetY=1025),
        'too-many-records': lambda s:s['state']['kitty'].update(placementBuffers=[record]*1025),
    }
    for name, mutate in changes.items():
        value = copy.deepcopy(sample); mutate(value)
        controls[name] = invoke(client, {'checkpoint':list(json.dumps(value).encode()),'events':[]}, reject=True).strip()
        assert ('bridge Kitty placement count' if name=='too-many-records' else 'bridge Kitty placement record') in controls[name]
    # Admission is bounded before mutation; deletion frees a slot and replacement still works at capacity.
    many = image+b''.join(command(f'a=p,i=7,p={n},c=1,r=1,C=1')+scroll for n in range(1,1025))
    many += command('a=p,i=7,p=1025,c=1,r=1,C=1')
    limit_trace = invoke(server,[{'name':'limit','events':[{'data':list(many),'checkpoint':True},
        {'data':list(command('a=d,d=i,i=7,p=1')+b'\x1b[H'+command('a=p,i=7,p=1025,c=1,r=1,C=1')),'checkpoint':True},
        {'data':list(b'\x1b[H'+command('a=p,i=7,p=1025,c=2,r=1,C=1')),'checkpoint':True},
        {'data':list(command('a=d,d=i,i=7')),'checkpoint':True}]}], env)['limit']
    tables = [json.loads(bytes(c['bytes']))['state']['kitty']['placementBuffers'] for c in limit_trace['checkpoints']]
    assert len(tables[0])==1024 and all(r['placement']!=1025 for r in tables[0])
    assert len(tables[1])==1024 and any(r['placement']==1025 for r in tables[1])
    assert len(tables[2])==1024 and next(r for r in tables[2] if r['placement']==1025)['columns']==2
    assert tables[3]==[]
    assert [s['imageCells'] for s in limit_trace['snapshots']]==[0,1,2,0]
    producer_controls = {}
    for name, placement, diagnostic in [
        ('offset',command('a=p,i=7,p=3,c=1,r=1,C=1,X=1025'),'Kitty placement offset limit'),
        ('automatic-id',command('a=p,i=7,c=1,r=1,C=1'),'unsupported automatic Kitty placement identity')]:
        trace = invoke(server,[{'name':name,'events':[{'data':list(image+placement+scroll),'checkpoint':True},
            {'data':list(command('a=d,d=i,i=7')),'checkpoint':True}]}],env)[name]
        assert diagnostic in trace['checkpoints'][0].get('error','')
        assert 'bytes' in trace['checkpoints'][1]
        producer_controls[name]={'rejected':True,'recoveredAfterDeletion':True,'diagnostic':diagnostic}
    (out/'results.json').write_text(json.dumps({'red':red,'comparisons':results,'receiverControls':controls,'producerControls':producer_controls,
        'serverLimit':{'rejected1025BeforeMutation':True,'recoveredAfterSingleDeletion':True,'replacedAtCapacity':True,'allDeleted':True},
        'summary':{'passed':sum(r['passed'] for r in results),'failed':sum(not r['passed'] for r in results),
                   'receiverRejected':len(controls)}},indent=2)+'\n')
    (out/'run.json').write_text(json.dumps({'timestampUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'platform':platform.platform(),'foundation':'ab4f866153ff46c03e1e51de72eec8d85d233d51',
        'cellPixels':[9,16],'scope':'headless native macOS checkpoint experiment',
        'exerciseEmptyAlternateResize':args.exercise_empty_alternate_resize,
        'sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [server,client,args.old_client,Path(__file__),Path(__file__).with_name('placement.patch'),Path(__file__).with_name('prepare.py'),Path(__file__).with_name('regression.py')]}},indent=2)+'\n')
    print(json.dumps({'passed':sum(r['passed'] for r in results),'failed':sum(not r['passed'] for r in results)}))
    if any(not r['passed'] for r in results):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
