"""Exercise cross-geometry checkpoint import without opening a window."""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent/'kitty-contract'))
from probe import invoke, decoded_pixels


def cross_geometry_controls(build, output):
    from raster_fixture import TRACE, EVENTS, widths
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('RASTER_', 'PROTOTYPE_', 'MYTERM_PROBE_'))}
    env.update(RASTER_MODE='controlled', MYTERM_PROBE_RASTER='1', PROTOTYPE_FONT_GRID_SCALE='1')
    reference = invoke(build/'raster-client', {'events': EVENTS}, env)
    server = invoke(build/'server', [TRACE], dict(env, CELL_WIDTH='9', CELL_HEIGHT='16'))[TRACE['name']]
    checkpoint = server['checkpoints'][0]['bytes']
    # Both 9x1 and 8.5x1 round to wire cell width nine. The wire-geometry
    # guard alone cannot distinguish them; exact pixels/state must detect it.
    restored = invoke(build/'raster-client', {'checkpoint': checkpoint, 'events': EVENTS[1:]},
                      dict(env, PROTOTYPE_FONT_GRID_SCALE='2'))
    baseline, actual = reference['snapshots'][0], restored['snapshots'][0]
    same_wire_width = math.floor(baseline['imageGeometry'][0]*baseline['imageGeometry'][2]+0.5) == math.floor(actual['imageGeometry'][0]*actual['imageGeometry'][2]+0.5)
    mismatch = {'sameRoundedWireWidth': same_wire_width,
                'referenceWidth': widths(baseline), 'restoredWidth': widths(actual),
                'differentPixels': decoded_pixels(baseline['renderedPNG']) != decoded_pixels(actual['renderedPNG']),
                'reference': reference, 'restored': restored}
    assert same_wire_width and mismatch['referenceWidth'] == [18] and mismatch['restoredWidth'] == [17] and mismatch['differentPixels']

    # A real 8.5-point, 2x window from the live assessment requires 17x32
    # physical wire cells. A 9-point, 1x importer must reject that checkpoint.
    live = invoke(build/'server', [TRACE], dict(env, CELL_WIDTH='17', CELL_HEIGHT='32'))[TRACE['name']]
    result = subprocess.run([str(build/'raster-client')], env=env, capture_output=True,
                            input=json.dumps({'checkpoint': live['checkpoints'][0]['bytes'], 'events': []}).encode(), timeout=30)
    rejection = {'exitCode': result.returncode, 'stderr': result.stderr.decode()}
    assert result.returncode == 1 and 'bridge authoritative geometry mismatch' in rejection['stderr']
    data = {'sameWireDifferentRaster': mismatch, 'differentWireRejected': rejection, 'passed': 2}
    output.write_text(json.dumps(data, indent=2)+'\n')
    return {'passed': 2, 'sameWireReferenceWidth': mismatch['referenceWidth'],
            'sameWireRestoredWidth': mismatch['restoredWidth'], 'differentWireRejected': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(cross_geometry_controls(args.build.resolve(), args.output.resolve())))


if __name__ == '__main__':
    main()
