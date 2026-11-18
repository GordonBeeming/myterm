"""Assert the recorded geometry mechanisms independently of checkpoint equality."""
import argparse
import gzip
import json
import math
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('captures', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    data = json.load(gzip.open(args.captures, 'rt'))
    assertions = []

    def check(name, condition):
        assertions.append({'name': name, 'passed': bool(condition)})

    negative = data['negative']
    check('historical widths are exactly 18 and 17', negative['oneWidth'] == [18] and negative['twoWidth'] == [17])
    check('exact pixel comparison detects the mixed-grid difference', negative['differentPixels'])
    windows = [r for r in data['records'] if r['config']['RASTER_MODE'].startswith('window')]
    scales = set()
    for record in windows:
        reset = record['config'].get('RASTER_RESET_FONT') == '1'
        snapshot = record['reference']['snapshots'][0]
        diagnostic = snapshot['diagnostic']
        width, height, scale = snapshot['imageGeometry']
        scales.add(scale)
        check(record['name']+' uses a visible real window', diagnostic['windowVisible'])
        check(record['name']+' reaches its requested screen', diagnostic['actualScreenIndex'] == int(record['config']['RASTER_SCREEN']))
        check(record['name']+' uses the window image scale', scale == diagnostic['windowScale'])
        expected = (math.ceil(diagnostic['rawGlyphWidth']*scale)/scale if reset
                    else diagnostic['beforeWindow'][0])
        check(record['name']+' has the predicted font cell width', width == expected)
        check(record['name']+' has a two-column stripe of the predicted width', record['widths'][0] == [int(width*2)])
        check(record['name']+' preserves exact state and pixels through import and resize',
              len(record['comparisons']) == 6 and all(all(c.values()) for c in record['comparisons']))
    check('real 1x and 2x windows were both exercised', scales == {1, 2})
    for i, movement in enumerate(data['movement']):
        config, snapshots = movement['config'], movement['result']['snapshots']
        start, target = int(config['RASTER_SCREEN']), int(config['RASTER_MOVE_SCREEN'])
        check(f'move {i} reaches actual start and target screens',
              snapshots[0]['diagnostic']['actualScreenIndex'] == start
              and all(s['diagnostic']['actualScreenIndex'] == target for s in snapshots[1:]))
        check(f'move {i} keeps a real visible window', all(s['diagnostic']['windowVisible'] for s in snapshots))
        if config['RASTER_RESET_FONT'] == '1':
            check(f'move {i} explicitly refreshed cells match each window scale', all(
                s['imageGeometry'][0] == math.ceil(s['diagnostic']['rawGlyphWidth']*s['imageGeometry'][2])/s['imageGeometry'][2]
                for s in snapshots))
        else:
            check(f'move {i} does not implicitly refresh the cached font cell',
                  all(s['imageGeometry'][0] == snapshots[0]['imageGeometry'][0] for s in snapshots))
    result = {'assertions': assertions, 'passed': sum(a['passed'] for a in assertions),
              'failed': [a['name'] for a in assertions if not a['passed']],
              'windowTrials': len(windows), 'movementRuns': len(data['movement'])}
    args.output.write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'assertions'}))
    if result['failed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
