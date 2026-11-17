"""Measure Kitty placement differences without changing either native engine."""
import argparse
import base64
import datetime
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
from PIL import Image


def decoded_pixels(encoded):
    with Image.open(io.BytesIO(base64.b64decode(encoded))) as source:
        image = source.convert('RGBA')
        return list(image.size), hashlib.sha256(image.tobytes()).hexdigest()


def graphics_semantic(encoded, foundation_semantic):
    state = foundation_semantic(encoded)
    # The native view partitions these groups and sorts Kitty layers by identity.
    # Dictionary iteration during relative reprojection is not a paint order.
    for buffer in ('normal', 'alternate'):
        for line in state[buffer]['lines']:
            other = [image for image in line['images'] if not image['isKitty']]
            kitty = sorted((image for image in line['images'] if image['isKitty']),
                           key=lambda image: (image['zIndex'], image.get('imageId', 0),
                                              image.get('placementId', 0), image['column']))
            line['images'] = ([image for image in kitty if image['zIndex'] < 0] + other
                              + [image for image in kitty if image['zIndex'] >= 0])
    raw = plistlib.loads(base64.b64decode(encoded))['state']['kitty']
    relative = []
    for entry in raw.get('relativeImages', []):
        images = []
        for image in entry['images']:
            with Image.open(io.BytesIO(image['data'])) as source:
                digest = hashlib.sha256(source.convert('RGBA').tobytes()).hexdigest()
            images.append({k: v for k, v in image.items() if k != 'data'} | {'rgbaSha256': digest})
        relative.append({'imageId': entry['imageId'], 'placementId': entry['placementId'],
                         'images': images})
    state['kitty']['relativeImages'] = relative
    return state


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
    add('automatic-after-explicit', [image + place, command('a=p,i=1,c=1,r=1,C=1'),
                                     command('a=p,i=1,c=1,r=1,C=1'), command('a=d,d=i,i=1,p=1')])
    add('virtual-automatic', [image + command('a=p,i=1,c=2,r=2,U=1'),
                              command('a=p,i=1,c=2,r=2,U=1'), b'after'])
    add('pending-crop-offset', [command('a=T,f=32,s=2,v=1,i=1,p=1,x=1,w=1,c=1,r=1,X=2,Y=3,m=1', '/wAA'),
                                command('m=0', '/wD/AP8='), b'after'])
    add('offset-clamp', [image + command('a=p,i=1,p=1,X=9999,Y=9999,c=1,r=1,C=1'), b'after'])
    add('crop-invalid-retains-placement', [image + place,
         command('a=p,i=1,p=1,x=99,c=1,r=1,C=1'), b'after'])
    for name, extra in [('crop-auto-width', 'r=2'), ('crop-auto-height', 'c=2'), ('crop-auto-both', '')]:
        add(name, [image + command('a=p,i=1,p=1,x=1,w=1,h=2,C=1' + (','+extra if extra else '')), b'after'])
    add('relative-chain-eight', [image + place,
         b''.join(command(f'a=p,i=1,p={i},P=1,Q={i-1},c=1,r=1') for i in range(2, 10)),
         command('a=d,d=i,i=1,p=1')])
    add('relative-depth-limit', [image + place,
         b''.join(command(f'a=p,i=1,p={i},P=1,Q={i-1},c=1,r=1') for i in range(2, 34)),
         command('a=p,i=1,p=34,P=1,Q=33,c=1,r=1'), b'after'])
    add('relative-parent-replacement', [image + place,
         command('a=p,i=1,p=2,P=1,Q=1,H=1,V=1,c=1,r=1'),
         b'\x1b[3;4H' + place, b'\r\n'*6, command('a=d,d=i,i=1,p=1')])
    add('relative-scroll', [image + place,
         command('a=p,i=1,p=2,P=1,Q=1,H=1,V=1,c=1,r=1'), b'\r\n'*8,
         b'\r\n'*45, command('a=d,d=i,i=1,p=1')])
    image2 = command('a=t,f=32,s=1,v=1,i=2', 'AP8A/w==')
    add('relative-delete-other-image', [image + place + image2,
         command('a=p,i=2,p=2,P=1,Q=1,H=1,V=1,c=1,r=1'),
         command('a=d,d=i,i=1,p=1'), b'after'])
    for mode, keys in [('cell', 'd=p,x=1,y=1'), ('cursor', 'd=c'),
                       ('column', 'd=x,x=1'), ('row', 'd=y,y=1'), ('z', 'd=z,z=0'), ('all', 'd=a')]:
        add('relative-delete-'+mode, [image + place + image2,
             command('a=p,i=2,p=2,P=1,Q=1,H=3,V=3,c=1,r=1'),
             command('a=d,'+keys), b'after'])
    placeholder = '\x1b[38;2;0;0;1m\U0010eeee\x1b[0m'.encode()
    add('virtual-placeholder', [image + command('a=p,i=1,p=1,c=2,r=2,U=1'),
                                b'\x1b[3;4H' + placeholder, b'after', command('a=d,d=i,i=1,p=1')])
    add('relative-virtual-parent', [image + command('a=p,i=1,p=1,c=2,r=2,U=1') + image2,
         b'\x1b[3;4H' + placeholder,
         command('a=p,i=2,p=2,P=1,Q=1,H=1,V=1,c=1,r=1'),
         b'\r\n'*8, command('a=d,d=i,i=1,p=1')])
    add('virtual-parent-hidden-reveal', [image + command('a=p,i=1,p=1,c=2,r=2,U=1') + image2,
         command('a=p,i=2,p=2,P=1,Q=1,H=1,V=1,c=1,r=1'),
         b'\x1b[3;4H' + placeholder, b'\x1b[3;4H ', b'\x1b[4;5H' + placeholder])
    add('uppercase-delete-unrelated-cache', [image + image2, command('a=d,d=I,i=1'),
         command('a=p,i=2,p=2,c=1,r=1,C=1')])
    add('uppercase-delete-partial-placement', [image + place + command('a=p,i=1,p=2,c=1,r=1,C=1'),
         command('a=d,d=I,i=1,p=1'), command('a=p,i=1,p=3,c=1,r=1,C=1')])
    add('pending-padded-fragments-invalid', [command('a=T,f=32,s=2,v=1,i=1,p=1,m=1', '/wAA/w=='),
         command('m=0', 'AP8A/w=='), b'after'])
    add('pending-quiet-success', [command('a=T,f=32,s=1,v=1,i=1,p=1,q=1,m=1', '/wAA'),
         command('m=0', '/w=='), b'after'])
    for quiet in (1, 2):
        add(f'relative-quiet-error-{quiet}', [image,
             command(f'a=p,i=1,p=2,P=1,Q=99,c=1,r=1,q={quiet}'), b'after'])
    add('incomplete-parent-reference', [image + place,
         command('a=p,i=1,p=2,P=1,c=1,r=1'), b'after'])
    add('automatic-zero-id', [image + place, command('a=p,i=1,p=0,c=1,r=1,C=1'), b'after'])
    add('virtual-zero-size', [image + command('a=p,i=1,p=1,U=1,c=0,r=0'), b'after'])
    for name, start, offsets, move in [
        ('top-left', b'\x1b[2;2H', 'H=-2,V=-2', b'\x1b[4;4H'),
        ('hidden-reveal', b'\x1b[H', 'H=-4,V=-3', b'\x1b[5;8H'),
        ('bottom-right', b'\x1b[4;10H', 'H=10,V=2', b'\x1b[H'),
        ('far-outside', b'\x1b[H', 'H=1000,V=1000', b'\x1b[2;2H'),
        ('minimum-offset', b'\x1b[H', 'H=-2147483648,V=-2147483648', b'\x1b[2;2H'),
    ]:
        add('relative-clipped-'+name, [start+image+place+image2,
             command(f'a=p,i=2,p=2,P=1,Q=1,{offsets},c=3,r=3'),
             move+place, command('a=d,d=i,i=1,p=1')])
    add('virtual-parent-multiple-placeholders', [image + command('a=p,i=1,p=1,c=2,r=2,U=1') + image2,
         b'\x1b[2;8H'+placeholder+b'\x1b[4;3H'+placeholder,
         command('a=p,i=2,p=2,P=1,Q=1,H=1,V=1,c=1,r=1'),
         b'\x1b[2;8H ', b'\x1b[4;3H '])
    high_image = image.replace(b'i=1;', b'i=16777217;')
    high_placeholder = ('\x1b[38;2;0;0;1m\x1b[58;2;0;0;7m'
                        '\U0010eeee\u0305\u0305\u030d'
                        '\U0010eeee\u0305\u030d\x1b[0m').encode()
    add('virtual-parent-msb-inheritance', [high_image + command('a=p,i=16777217,p=7,c=2,r=2,U=1') + image2,
         b'\x1b[3;4H'+high_placeholder,
         command('a=p,i=2,p=2,P=16777217,Q=7,H=1,V=1,c=1,r=1'), b'\r\n'*5])
    green = command('a=t,f=32,s=2,v=2,i=1', base64.b64encode(bytes([0, 255, 0, 255])*4).decode())
    half_red = command('a=t,f=32,s=2,v=2,i=2', base64.b64encode(bytes([128, 0, 0, 128])*4).decode())
    add('alpha-overlap', [green+place+half_red+command('a=p,i=2,p=2,c=2,r=2,C=1'), b'after'])
    for mode in ['d=a', 'd=c', 'd=p,x=1,y=1', 'd=q,x=1,y=1,z=0',
                 'd=x,x=1', 'd=y,y=1', 'd=z,z=0']:
        add('virtual-retains-'+mode.split(',')[0][2:],
            [image+command('a=p,i=1,p=1,c=2,r=2,U=1'),
             b'\x1b[3;4H'+placeholder, command('a=d,'+mode), b'after'])
    add('virtual-id-range-deletion', [image+command('a=p,i=1,p=1,c=2,r=2,U=1')+image2,
         command('a=d,d=R,x=1,y=1'), command('a=p,i=2,p=2,c=1,r=1,C=1')])
    add('delete-aborts-pending', [command('a=T,f=32,s=1,v=1,i=1,p=1,m=1', '/wAA'),
         command('a=d'), image+place])
    add('inactive-parent-rejected', [image+place, b'\x1b[?1049h'+image2,
         command('a=p,i=2,p=2,P=1,Q=1,c=1,r=1'), b'\x1b[?1049l'])
    add('local-deletion-preserves-inactive', [image+place, b'\x1b[?1049h\x1b[H'+image2,
         command('a=p,i=2,p=2,c=1,r=1,C=1'), command('a=d,d=p,x=1,y=1'), b'\x1b[?1049l'])
    numbered = image.replace(b'i=1;', b'I=44;')
    add('virtual-numbered-image', [numbered+command('a=p,I=44,p=1,c=2,r=2,U=1'),
         command('a=p,I=44,p=1,P=1,Q=1,c=1,r=1'), command('a=d,d=n,I=44')])
    add('numbered-after-explicit', [image+numbered, command('a=p,I=44,p=1,c=1,r=1,C=1'), b'after'])
    add('missing-image-errors', [command('a=p,i=99,p=1,c=1,r=1'),
         command('a=p,I=99,p=1,c=1,r=1'), image+place])
    add('mutually-exclusive-identities', [command('a=T,f=32,s=1,v=1,i=1,I=44,p=1', '/wAA/w=='),
         command('a=p,i=1,I=44,p=1'), image+place])
    add('zero-dimension-rejection', [command('a=T,f=32,s=0,v=1,i=1,p=1,c=1,r=1'), image+place])
    add('automatic-identities-reset', [numbered+command('a=p,I=44,c=1,r=1,C=1'), b'\x1bc',
         numbered+command('a=p,I=44,c=1,r=1,C=1')])
    png = io.BytesIO()
    Image.new('RGBA', (2, 2), (128, 0, 0, 128)).save(png, format='PNG')
    add('png-alpha-crop-overlap', [green+place,
         command('a=t,f=100,i=2', base64.b64encode(png.getvalue()).decode())
         +command('a=p,i=2,p=2,x=1,w=1,c=2,r=2,C=1'), b'after'])
    add('single-width-preserves-aspect', [command('a=T,f=32,s=1,v=1,i=1,p=1,c=2,C=1', '/wAA/w=='), b'after'])
    add('natural-width-one-hundred', [command('a=T,f=32,s=100,v=1,i=1,p=1,C=1',
         base64.b64encode(bytes([255, 0, 0, 255])*100).decode()), b'after'])
    add('retransmit-deletes-old-group', [image+place+image2+command('a=p,i=2,p=2,P=1,Q=1,c=1,r=1'),
         command('a=t,f=32,s=1,v=1,i=1', 'AAD//w=='), command('a=p,i=1,p=1,c=1,r=1,C=1')])
    add('failed-raster-keeps-old-relative', [image+place+image2+command('a=p,i=2,p=2,P=1,Q=1,c=1,r=1'),
         command('a=p,i=2,p=2,P=1,Q=1,c=200,r=100'), b'after'])
    add('failed-raster-keeps-old-ordinary', [image+place,
         command('a=p,i=1,p=1,c=200,r=100,C=1'), b'after'])
    add('parent-move-between-buffers', [image+place+image2+command('a=p,i=2,p=2,P=1,Q=1,c=1,r=1'),
         b'\x1b[?1049h'+command('a=p,i=1,p=1,c=1,r=1,C=1'), b'\x1b[?1049l'])
    image3 = command('a=t,f=32,s=1,v=1,i=3', '/wAA/w==')
    image4 = command('a=t,f=32,s=1,v=1,i=4', 'AP8A/w==')
    add('relative-groups-in-both-buffers', [image+place+image2+command('a=p,i=2,p=2,P=1,Q=1,c=1,r=1'),
         b'\x1b[?1049h'+image3+command('a=p,i=3,p=3,c=1,r=1,C=1')+image4,
         command('a=p,i=4,p=4,P=3,Q=3,H=1,V=1,c=1,r=1'), b'\x1b[?1049l'])
    add('same-grid-different-size-requests', [command('a=t,f=32,s=1,v=1,i=1', '/wAA/w==')
         +command('a=p,i=1,p=1,c=2,C=1'),
         b'\x1b[1;5H'+command('a=p,i=1,p=2,c=2,r=2,C=1'), b'after'])
    add('relative-same-grid-different-requests', [command('a=t,f=32,s=1,v=1,i=1', '/wAA/w==')
         +command('a=p,i=1,p=1,c=1,r=1,C=1'),
         command('a=p,i=1,p=2,P=1,Q=1,H=1,V=0,c=2'),
         command('a=p,i=1,p=3,P=1,Q=1,H=5,V=0,c=2,r=2'), b'after'])
    add('same-image-child-parent-buffer-move', [image+place+command('a=p,i=1,p=2,P=1,Q=1,c=1,r=1'),
         b'\x1b[?1049h'+command('a=p,i=1,p=1,c=1,r=1,C=1'), b'\x1b[?1049l'])
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
    parser.add_argument('--raster', action='store_true', help='Compare headless native view rendering too')
    parser.add_argument('--case', action='append', help='Run named traces only')
    parser.add_argument('--require-match', action='store_true', help='Fail on any fidelity difference or rejection')
    parser.add_argument('--exercise-fractional-geometry', action='store_true',
                        help='Include the existing native fractional-cell geometry gate')
    args = parser.parse_args()
    build = args.build.resolve()
    sys.path.insert(0, str(build / 'foundation'))
    from checkpoint_checks import semantic as foundation_semantic
    def semantic(encoded):
        return graphics_semantic(encoded, foundation_semantic)
    env = dict(os.environ, CELL_WIDTH='9', CELL_HEIGHT='16')
    if args.raster:
        env['MYTERM_PROBE_RASTER'] = '1'
    cases = fixtures()
    if args.exercise_fractional_geometry:
        cases.append({'name': 'natural-width-nine-geometry-gate', 'events': [
            {'data': list(command('a=T,f=32,s=9,v=1,i=1,p=1,C=1',
                                base64.b64encode(bytes([255, 0, 0, 255])*9).decode())), 'checkpoint': True},
            {'data': list(b'after'), 'checkpoint': True}]})
    if args.case:
        cases = [c for c in cases if c['name'] in args.case]
        if len(cases) != len(set(args.case)):
            raise ValueError('Unknown case')
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
            native = {'cursor': [active['x'], active['y']],
                      'replies': snapshot['replies'], 'kitty': state['kitty'],
                      'relativeProjections': snapshot.get('relativeProjections')}
            if 'imageGeometry' in snapshot:
                native['imageGeometry'] = snapshot['imageGeometry']
            if args.raster:
                native['renderedPixels'] = decoded_pixels(snapshot['renderedPNG'])
                native['renderedPNG'] = snapshot['renderedPNG']
            entry['native'].append(native)
        for expected, snapshot in zip(entry['native'], candidate['snapshots'], strict=True):
            entry['candidate'].append({'cursor': snapshot['cursor'], 'replies': snapshot['replies'],
                                       'imageCells': snapshot['imageCells'],
                                       'relativeProjections': snapshot.get('relativeProjections'),
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
                        if args.raster and decoded_pixels(actual['renderedPNG']) != decoded_pixels(expected['renderedPNG']):
                            fields.append('renderedPixels')
                        trial['comparisons'].append({'offset': offset, 'fields': fields,
                                                     'passed': not fields})
                        if args.raster and 'renderedPixels' in fields:
                            trial['comparisons'][-1]['actualPNG'] = actual['renderedPNG']
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
        'cursorDifferences': sum(not c['cursorMatches'] for r in results for c in r['candidate']),
        'replyDifferences': sum(not c['repliesMatch'] for r in results for c in r['candidate']),
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
    opener = gzip.open if args.output.suffix == '.gz' else open
    with opener(args.output, 'xt') as stream:
        json.dump(report, stream, indent=2)
        stream.write('\n')
    print(json.dumps(summary))
    if args.require_match and (len(summary['fullyMatchingCases']) != len(cases)
                              or summary['cursorDifferences'] or summary['replyDifferences']):
        raise SystemExit(1)


if __name__ == '__main__':
    main()
