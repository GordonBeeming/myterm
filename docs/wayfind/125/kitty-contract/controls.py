"""Check protocol truths, receiver rejection, admission limits and layer growth."""
import argparse
import base64
import copy
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess

from PIL import Image
from probe import command, fixtures, invoke


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--matrix', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--baseline-server', type=Path)
    args = parser.parse_args()
    build = args.build.resolve()
    env = dict(os.environ, CELL_WIDTH='9', CELL_HEIGHT='16')
    opener = gzip.open if args.matrix.suffix == '.gz' else open
    with opener(args.matrix, 'rt') as stream:
        matrix = json.load(stream)
    if matrix['summary']['cases'] != len(fixtures()):
        raise ValueError('Matrix does not cover the current fixture set')
    if (matrix['summary']['cases'] != len(matrix['summary']['fullyMatchingCases'])
            or matrix['summary']['cursorDifferences'] or matrix['summary']['replyDifferences']):
        raise ValueError('Protocol assertions require a passing matrix')
    by_name = {case['name']: case for case in matrix['results']}
    for name in ('server', 'client'):
        if matrix['run']['sha256'][str(build/name)] != hashlib.sha256((build/name).read_bytes()).hexdigest():
            raise ValueError('Matrix and control executables differ')
    truths = {}

    def require(name, condition):
        if not condition:
            raise AssertionError(name)
        truths[name] = True

    def native(name, event):
        return by_name[name]['native'][event]

    for name, event, error in [('relative-self-cycle', 1, b'ECYCLE'),
                               ('relative-two-node-cycle', 2, b'ECYCLE'),
                               ('relative-depth-limit', 2, b'ETOODEEP'),
                               ('relative-missing-parent', 0, b'ENOPARENT'),
                               ('virtual-relative-invalid', 1, b'EINVAL')]:
        require(name+'-reply', error in bytes(native(name, event)['replies']))
    require('cycle-keeps-old-placement', native('relative-self-cycle', 0)['kitty']
            == native('relative-self-cycle', 1)['kitty'])
    require('depth-thirty-two-admitted', len(native('relative-depth-limit', 1)['kitty']['placements']) == 33)
    require('depth-thirty-three-refused', native('relative-depth-limit', 1)['kitty']
            == native('relative-depth-limit', 2)['kitty'])
    deleted = native('relative-delete-other-image', 2)['kitty']
    require('cascade-removes-child-and-its-unreferenced-data', deleted['placements'] == []
            and {entry[0] for entry in deleted['cache']} == {1} and deleted['relativeImages'] == [])
    for suffix in ('a', 'c', 'p', 'q', 'x', 'y', 'z'):
        case = 'virtual-retains-'+suffix
        require(case, native(case, 2)['kitty']['placements'] == native(case, 1)['kitty']['placements']
                and native(case, 2)['renderedPixels'] == native(case, 1)['renderedPixels'])
    for event, expected in [(2, (2, 3)), (3, (4, 3)), (4, (1, 1))]:
        record = next(p for p in native('virtual-parent-multiple-placeholders', event)['kitty']['placements']
                      if p['imageId'] == 2)
        require(f'minimum-placeholder-origin-{event}', (record['row'], record['column']) == expected)
    clipped = native('relative-clipped-hidden-reveal', 1)['kitty']
    child = next(p for p in clipped['placements'] if p['imageId'] == 2)
    require('hidden-relative-retains-full-stripes', (child['row'], child['column']) == (-3, -4)
            and len(clipped['relativeImages'][0]['images']) == 3)
    visible = native('relative-clipped-hidden-reveal', 2)['kitty']
    child = next(p for p in visible['placements'] if p['imageId'] == 2)
    require('parent-move-reveals-retained-relative', (child['row'], child['column']) == (1, 3))
    require('automatic-placement-identities-do-not-replace-explicit',
            {p['placementId'] for p in native('automatic-after-explicit', 2)['kitty']['placements']} == {1, 2, 3})
    def colored_bounds(case, event=0):
        with Image.open(io.BytesIO(base64.b64decode(native(case, event)['renderedPNG']))) as source:
            image = source.convert('RGBA')
            points = [(index % image.width, index // image.width) for index, pixel in enumerate(image.get_flattened_data())
                      if max(pixel[:3])-min(pixel[:3]) > 40 and max(pixel[:3]) > 60]
        if not points:
            return None
        return [min(x for x, _ in points), min(y for _, y in points),
                max(x for x, _ in points)+1, max(y for _, y in points)+1]

    geometry = native('alpha-overlap', 0)['imageGeometry']
    with Image.open(io.BytesIO(base64.b64decode(native('alpha-overlap', 0)['renderedPNG']))) as image:
        alpha_pixel = list(image.convert('RGBA').getpixel((round(geometry[0]), round(geometry[1]))))
    require('straight-alpha-midtone-blends-on-green', 40 <= alpha_pixel[0] <= 100
            and 100 <= alpha_pixel[1] <= 160 and alpha_pixel[2] < 30 and alpha_pixel[3] == 255)
    aspect = colored_bounds('single-width-preserves-aspect')
    natural = colored_bounds('natural-width-one-hundred')
    letterbox = colored_bounds('alpha-overlap')
    require('single-dimension-keeps-square', aspect is not None and aspect[2]-aspect[0] == aspect[3]-aspect[1])
    require('natural-pixels-not-stretched-to-grid', natural is not None
            and natural[2]-natural[0] == 100 and natural[3]-natural[1] == 1)
    require('both-dimensions-letterbox', letterbox is not None and letterbox[1] > 0
            and letterbox[2]-letterbox[0] == letterbox[3]-letterbox[1])
    require('scrolled-out-parent-does-not-resurrect-child', colored_bounds('relative-scroll', 3) is None)
    require('truecolor-blue-byte-selects-image-one', colored_bounds('virtual-placeholder', 1) is not None)
    for case in ('failed-raster-keeps-old-relative', 'failed-raster-keeps-old-ordinary'):
        require(case, native(case, 0)['kitty'] == native(case, 1)['kitty']
                and b'ENOSPC' in bytes(native(case, 1)['replies']))
    require('inactive-parent-is-not-usable', b'ENOPARENT' in bytes(native('inactive-parent-rejected', 2)['replies']))
    require('local-deletion-keeps-normal-parent',
            any(p['imageId'] == 1 for p in native('local-deletion-preserves-inactive', 3)['kitty']['placements']))

    case = next(f for f in fixtures() if f['name'] == 'relative')
    candidate = invoke(build/'server', [case], env)['relative']
    sample = json.loads(bytes(candidate['checkpoints'][1]['bytes']))
    valid = invoke(build/'client', {'checkpoint': list(json.dumps(sample).encode()), 'events': []}, env)
    native_sample = plistlib.loads(base64.b64decode(valid['snapshots'][0]['nativeCheckpoint']))
    rejected = {}

    def reject(name, state, diagnostic, native_format=False):
        encoded = plistlib.dumps(state, fmt=plistlib.FMT_BINARY) if native_format else json.dumps(state).encode()
        request = {'nativeCheckpoint' if native_format else 'checkpoint': list(encoded), 'events': []}
        result = subprocess.run([str(build/'client')], input=json.dumps(request).encode(),
                                capture_output=True, env=env, timeout=15)
        text = result.stderr.decode()
        if result.returncode != 1 or diagnostic not in text:
            raise AssertionError(f'{name}: exit {result.returncode}, {text}')
        rejected[name] = {'exit': result.returncode, 'diagnostic': diagnostic,
                          'inputSHA256': hashlib.sha256(encoded).hexdigest()}

    changes = {
        'self-cycle': ('bridge Kitty parent graph', lambda s: s['state']['kitty']['placementBuffers'][1].update(parentPlacementId=2)),
        'missing-parent': ('bridge Kitty parent graph', lambda s: s['state']['kitty']['placementBuffers'][1].update(parentPlacementId=99)),
        'cross-buffer': ('bridge Kitty parent graph', lambda s: s['state']['kitty']['placementBuffers'][0].update(alternate=True)),
        'virtual-child': ('bridge Kitty parent metadata', lambda s: s['state']['kitty']['placementBuffers'][1].update(isVirtual=True)),
        'offset-overflow': ('bridge Kitty parent metadata', lambda s: s['state']['kitty']['placementBuffers'][1].update(parentOffsetH=2**63-1)),
        'incomplete-parent': ('bridge Kitty parent metadata', lambda s: s['state']['kitty']['placementBuffers'][1].pop('parentPlacementId')),
        'zero-next-identity': ('bridge Kitty next identity', lambda s: s['state']['kitty'].update(nextPlacementId=0)),
        'missing-relative-resource': ('bridge Kitty missing relative resource', lambda s: s['state']['kitty'].update(relativeResources=[])),
        'unknown-relative-resource': ('bridge Kitty relative resource', lambda s: s['state']['kitty']['relativeResources'][0].update(resource='missing')),
        'duplicate-relative-resource': ('bridge Kitty relative resource', lambda s: s['state']['kitty']['relativeResources'].append(copy.deepcopy(s['state']['kitty']['relativeResources'][0]))),
        'relative-count-overflow': ('bridge Kitty relative count limit', lambda s: s['state']['kitty'].update(relativeResources=[s['state']['kitty']['relativeResources'][0]]*129)),
    }
    for name, (diagnostic, change) in changes.items():
        state = copy.deepcopy(sample)
        change(state)
        reject(name, state, diagnostic)
    native_changes = {
        'native-self-cycle': ('Kitty parent graph', lambda s: s['state']['kitty']['placements'][1].update(parentPlacementId=2)),
        'native-cache-owner': ('Kitty relative cache owner', lambda s: s['state']['kitty']['relativeImages'][0].update(placementId=99)),
        'native-cache-metadata': ('Kitty relative cache image', lambda s: s['state']['kitty']['relativeImages'][0]['images'][0].update(kittyRow=99)),
        'native-cache-duplicate': ('Kitty relative cache owner', lambda s: s['state']['kitty']['relativeImages'].append(copy.deepcopy(s['state']['kitty']['relativeImages'][0]))),
        'native-cache-invalid-png': ('Kitty relative PNG dimensions', lambda s: s['state']['kitty']['relativeImages'][0]['images'][0].update(data=b'not PNG')),
        'native-relative-count-overflow': ('Kitty relative cache limit', lambda s: s['state']['kitty'].update(relativeImages=[s['state']['kitty']['relativeImages'][0]]*129)),
        'native-unsafe-coordinate': ('Kitty parent metadata', lambda s: s['state']['kitty']['placements'][1].update(column=2**63-1)),
    }
    invoke(build/'client', {'nativeCheckpoint': list(plistlib.dumps(native_sample, fmt=plistlib.FMT_BINARY)), 'events': []}, env)
    for name, (diagnostic, change) in native_changes.items():
        state = copy.deepcopy(native_sample)
        change(state)
        reject(name, state, diagnostic, native_format=True)

    distinct_case = next(f for f in fixtures() if f['name'] == 'same-grid-different-size-requests')
    distinct = invoke(build/'server', [distinct_case], env)[distinct_case['name']]['checkpoints'][1]
    distinct_state = json.loads(bytes(distinct['bytes']))['state']
    owners = {image['placementId']: image['resource'] for line in distinct_state['normal']['lines']
              for image in line['images'] if image['imageId'] == 1}
    requests = {r['key']: r['request'] for r in distinct_state['graphics']}
    require('same-grid-retains-each-size-request', owners[1] != owners[2]
            and requests[owners[1]]['height'] == 'auto' and requests[owners[2]]['height'] == '2')

    image = command('a=t,f=32,s=2,v=2,i=1', base64.b64encode(bytes([255, 0, 0, 255])*4).decode())
    chunks = [image+command('a=p,i=1,p=1,c=2,r=2,C=1')]
    chunks += [command(f'a=p,i=1,p={p},c=1,r=1,C=1') for p in range(2, 10)]
    workload = [{'name': 'linear-layers', 'events': [{'data': list(chunk)} for chunk in chunks]}]
    layers = [s['imageCells'] for s in invoke(build/'server', workload, env)['linear-layers']['snapshots']]
    require('overlap-layer-retention-is-linear', layers == list(range(4, 13)))
    idle = [{'name': 'unchanged-output', 'events': [{'data': list(image+command('a=p,i=1,p=1,c=1,r=1,C=1')
             +command('a=p,i=1,p=2,P=1,Q=1,c=1,r=1'))}]
             +[{'data': list(b'\x1b[5n')} for _ in range(100)]}]
    idle_server = invoke(build/'server', idle, env)['unchanged-output']['snapshots']
    idle_client = invoke(build/'client', {'events': [{'sequence': i, 'event': event}
                            for i, event in enumerate(idle[0]['events'])]}, env)['snapshots']
    require('rust-unchanged-output-does-not-reproject', idle_server[0]['relativeProjections'] > 0
            and {s['relativeProjections'] for s in idle_server} == {idle_server[0]['relativeProjections']})
    require('native-unchanged-output-does-not-reproject', idle_client[0]['relativeProjections'] > 0
            and {s['relativeProjections'] for s in idle_client} == {idle_client[0]['relativeProjections']})
    baseline_layers = None
    if args.baseline_server:
        baseline_layers = [s['imageCells'] for s in invoke(args.baseline_server.resolve(), workload, env)['linear-layers']['snapshots']]
        require('negative-control-exposes-prior-layer-duplication', baseline_layers[-1] == 514)
    placements = b''.join(command(f'a=p,i=1,p={p},c=1,r=1,U=1') for p in range(1, 1025))
    admission = invoke(build/'server', [{'name': 'admission', 'events': [
        {'data': list(image+placements), 'checkpoint': True},
        {'data': list(command('a=p,i=1,p=1025,c=1,r=1,U=1')), 'checkpoint': True},
        {'data': list(command('a=d,d=i,i=1,p=1')+command('a=p,i=1,p=1025,c=1,r=1,U=1')), 'checkpoint': True}]}], env)
    tables = [json.loads(bytes(c['bytes']))['state']['kitty']['placementBuffers'] for c in admission['admission']['checkpoints']]
    require('placement-admission-refuses-without-mutation', tables[0] == tables[1] and len(tables[1]) == 1024)
    require('deletion-frees-admission-slot', len(tables[2]) == 1024 and any(p['placement'] == 1025 for p in tables[2]))
    image2 = command('a=t,f=32,s=1,v=1,i=2', 'AP8A/w==')
    root = image+command('a=p,i=1,p=1,c=1,r=1,C=1')+image2
    children = b''.join(command(f'a=p,i=2,p={p},P=1,Q=1,c=1,r=1') for p in range(2, 130))
    cap_events = [{'data': list(root+children), 'checkpoint': True},
                  {'data': list(command('a=p,i=2,p=130,P=1,Q=1,c=1,r=1')), 'checkpoint': True}]
    capped = invoke(build/'server', [{'name': 'relative-cap', 'events': cap_events}], env)['relative-cap']
    capped_native = invoke(build/'client', {'events': [{'sequence': i, 'event': event}
                                for i, event in enumerate(cap_events)]}, env)
    caps = [json.loads(bytes(c['bytes'])) for c in capped['checkpoints']]
    require('relative-admission-cap-before-mutation', caps[0]['state'] == caps[1]['state']
            and len(caps[0]['state']['kitty']['relativeResources']) == 128)
    require('relative-admission-cap-is-reported', b'ENOSPC' in bytes(capped['snapshots'][1]['replies'])
            and capped['snapshots'][1]['replies'] == capped_native['snapshots'][1]['replies'])
    report = {'truths': truths, 'rejected': rejected, 'alphaPixel': alpha_pixel,
              'coloredBounds': {'singleWidth': aspect, 'naturalWidth': natural, 'letterbox': letterbox},
              'idleProjectionCounts': {'rust': idle_server[0]['relativeProjections'], 'native': idle_client[0]['relativeProjections']},
              'layerCounts': layers, 'baselineLayerCounts': baseline_layers,
              'binarySHA256': {name: hashlib.sha256((build/name).read_bytes()).hexdigest() for name in ('server', 'client')}}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as stream:
        json.dump(report, stream, indent=2)
        stream.write('\n')
    print(json.dumps({'truths': len(truths), 'rejections': len(rejected), 'alphaPixel': alpha_pixel,
                      'layers': layers[-1], 'baselineLayers': baseline_layers[-1] if baseline_layers else None}))


if __name__ == '__main__':
    main()
