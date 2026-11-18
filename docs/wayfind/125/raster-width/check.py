"""Compare real native geometry, stripe state and exact checkpoint pixels.

--gui opens, moves and resizes disposable windows; obtain GUI permission first.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys


HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent/'kitty-contract'))
from probe import invoke, decoded_pixels


from raster_fixture import TRACE, EVENTS, widths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--gui', action='store_true')
    parser.add_argument('--repeats', type=int, default=10)
    args = parser.parse_args()
    if args.repeats < 2:
        parser.error('--repeats must be at least two')
    build, output = args.build.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(build/'foundation'))
    from checkpoint_checks import semantic
    from geometry_controls import cross_geometry_controls
    cross_geometry = cross_geometry_controls(build, output/"cross-geometry.json")
    records = []
    commands = []

    def client(request, config, name):
        # Whitelist diagnostic environment to avoid inheriting prior probe options.
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('RASTER_', 'PROTOTYPE_', 'MYTERM_PROBE_'))}
        env.update(config, MYTERM_PROBE_RASTER='1')
        if config.get('RASTER_MODE', '').startswith('window'):
            request_path = output/(name+'-request.json')
            result_path = output/(name+'-result.json')
            log = output/(name+'-stderr.log')
            request_path.write_text(json.dumps(request))
            command = ['/usr/bin/open', '-n', '-g', '-W', '--stdin', str(request_path),
                       '--stdout', str(result_path), '--stderr', str(log)]
            for key, value in config.items():
                command += ['--env', key+'='+value]
            command += ['--env', 'MYTERM_PROBE_RASTER=1', str(build/'RasterDiagnostic.app')]
            commands.append(command)
            subprocess.run(command, check=True, timeout=30, env=env)
            if not result_path.read_text().strip():
                return {'importError': log.read_text()}
            return json.loads(result_path.read_text())
        result = subprocess.run([str(build/'raster-client')], input=json.dumps(request).encode(),
                                capture_output=True, timeout=30, env=env)
        if result.returncode:
            return {'importError': result.stderr.decode(), 'exitCode': result.returncode}
        return json.loads(result.stdout)

    def trial(config, name):
        reference = client({'events': EVENTS}, config, name+'-reference')
        geometry = reference['snapshots'][0]['imageGeometry']
        cell_width, cell_height, scale = geometry
        # Rust retains physical cell pixels; the importer validates these against
        # the actual native cell size and backing scale before materialization.
        env = dict(os.environ, CELL_WIDTH=str(math.floor(cell_width*scale+0.5)),
                   CELL_HEIGHT=str(math.floor(cell_height*scale+0.5)))
        candidate = invoke(build/'server', [TRACE], env)[TRACE['name']]
        comparisons = []
        imports = []
        for checkpoint in candidate['checkpoints']:
            cut = checkpoint['event']
            size = decoded_pixels(reference['snapshots'][cut]['renderedPNG'])[0]
            import_config = dict(config, RASTER_WIDTH=str(size[0]), RASTER_HEIGHT=str(size[1]))
            restored = client({'checkpoint': checkpoint['bytes'], 'events': EVENTS[cut+1:]},
                              import_config, name+f'-cut-{cut}')
            imports.append(restored)
            if 'importError' in restored:
                comparisons.append({'importSucceeded': False})
                continue
            for expected, actual in zip(reference['snapshots'][cut:], restored['snapshots'], strict=True):
                comparisons.append({
                    'geometry': expected['imageGeometry'] == actual['imageGeometry'],
                    'state': semantic(expected['nativeCheckpoint']) == semantic(actual['nativeCheckpoint']),
                    'pixels': decoded_pixels(expected['renderedPNG']) == decoded_pixels(actual['renderedPNG']),
                    'backingPixels': decoded_pixels(expected['backingPNG']) == decoded_pixels(actual['backingPNG']),
                    'replies': actual['replies'] == expected['replies'][len(reference['snapshots'][cut]['replies']):],
                })
        return {'name': name, 'config': config, 'reference': reference,
                'imports': imports, 'comparisons': comparisons,
                'widths': [widths(s) for s in reference['snapshots']]}

    # The historical mismatch must remain detectable; no tolerance or masking.
    one = client({'events': EVENTS}, {'RASTER_MODE': 'controlled', 'PROTOTYPE_FONT_GRID_SCALE': '1'}, 'negative-one')
    two = client({'events': EVENTS}, {'RASTER_MODE': 'controlled', 'PROTOTYPE_FONT_GRID_SCALE': '2'}, 'negative-two')
    negative = {'oneWidth': widths(one['snapshots'][0]), 'twoWidth': widths(two['snapshots'][0]),
                'differentPixels': decoded_pixels(one['snapshots'][0]['renderedPNG']) != decoded_pixels(two['snapshots'][0]['renderedPNG']),
                'one': one, 'two': two}
    assert negative['oneWidth'] == [18] and negative['twoWidth'] == [17] and negative['differentPixels'], 'Historical negative control no longer reproduces'
    records.append(trial({'RASTER_MODE': 'controlled', 'PROTOTYPE_FONT_GRID_SCALE': '1'}, 'coherent-headless'))

    # Independently initialized processes, including concurrent runs, exercise
    # the real NSScreen fallback rather than the forced-grid diagnostic.
    configs = [{'RASTER_MODE': 'native-headless'} for _ in range(args.repeats)]
    sequential = [trial(config, f'headless-serial-{i}') for i, config in enumerate(configs)]
    with ThreadPoolExecutor(max_workers=4) as pool:
        concurrent = list(pool.map(lambda i: trial(configs[i], f'headless-parallel-{i}'), range(args.repeats)))
    records += sequential + concurrent
    movement = []
    if args.gui:
        first = trial({'RASTER_MODE': 'window-early', 'RASTER_SCREEN': '0'}, 'window-first')
        records.append(first)
        screens = first['reference']['snapshots'][0]['diagnostic']['screenScales']
        for index in range(len(screens)):
            for mode in ('window-early', 'window-late'):
                for reset in ('0', '1'):
                    records.append(trial({'RASTER_MODE': mode, 'RASTER_SCREEN': str(index),
                                          'RASTER_RESET_FONT': reset}, f'{mode}-{index}-reset-{reset}'))
        for start in range(len(screens)):
            for target in range(len(screens)):
                if start == target:
                    continue
                for reset in ('0', '1'):
                    config = {'RASTER_MODE': 'window-early', 'RASTER_SCREEN': str(start),
                              'RASTER_MOVE_SCREEN': str(target), 'RASTER_RESET_FONT': reset}
                    result = client({'events': EVENTS}, config, f'move-{start}-{target}-reset-{reset}')
                    movement.append({'config': config, 'result': result})

    failures = [record['name'] for record in records
                if not all(all(c.values()) for c in record['comparisons'])]
    summary = {
        'time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'crossGeometryControls': cross_geometry,
        'trials': len(records), 'comparisons': sum(len(r['comparisons']) for r in records),
        'observedFailures': failures,
        'requiredGateFailures': [r['name'] for r in records
            if (r['name'] == 'coherent-headless' or r['config'].get('RASTER_RESET_FONT') == '1')
            and not all(all(c.values()) for c in r['comparisons'])],
        'negativeControl': {k: v for k, v in negative.items() if k not in ('one', 'two')},
        'geometryCounts': {}, 'movementRuns': len(movement),
        'binarySha256': {name: hashlib.sha256((build/name).read_bytes()).hexdigest()
                         for name in ('raster-client', 'server')},
    }
    for record in records:
        key = str(record['reference']['snapshots'][0]['imageGeometry'])
        summary['geometryCounts'][key] = summary['geometryCounts'].get(key, 0)+1
    with gzip.open(output/'captures.json.gz', 'wt') as stream:
        json.dump({'records': records, 'negative': negative, 'movement': movement, 'commands': commands}, stream)
    (output/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(json.dumps(summary))
    if summary['requiredGateFailures']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
