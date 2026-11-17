"""Exercise the bounded wide-cell exception and malformed checkpoint rejection."""
import argparse
import copy
import json
from pathlib import Path
import subprocess
from check import invoke


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build = args.build.resolve()
    trace = [{'name':'wide', 'events':[{'data':list('ABCDEFGH界KLMNOPQRST\r'.encode())},
                                    {'resize':[9,6], 'checkpoint':True}]}]
    checkpoint = invoke(build / 'server', trace)['wide']['checkpoints'][0]
    sample = json.loads(bytes(checkpoint['bytes']))
    assert invoke(build / 'client', {'checkpoint':checkpoint['bytes'], 'events':[]})['snapshots']
    def cell(value):
        return value['state']['normal']['lines'][0]['cells'][-1]
    assert cell(sample)['x'] == 8 and cell(sample)['width'] == 2
    def overlap(value):
        row = value['state']['normal']['lines'][0]
        row['cells'].append(copy.deepcopy(row['cells'][-1]))
    mutations = {
        'past-final-column':lambda s:cell(s).update(x=9),
        'negative-column':lambda s:cell(s).update(x=-1),
        'oversized-width':lambda s:cell(s).update(width=3),
        'wide-repetitions':lambda s:cell(s).update(repetitions=2),
        'overlapping-cell':overlap,
        'invalid-first-wrap-type':lambda s:s['state']['normal'].update(firstWrapped='true'),
        'inactive-cursor-shape':lambda s:s['state']['normal'].update(cursor=[0]),
        'inactive-cursor-column':lambda s:s['state']['normal'].update(cursor=[10,0]),
        'inactive-cursor-row':lambda s:s['state']['normal'].update(cursor=[0,-1]),
        'oversized-default-saved-row':lambda s:s['state']['normal'].update(defaultSavedY=6),
    }
    results = {}
    for name, mutate in mutations.items():
        value = copy.deepcopy(sample)
        mutate(value)
        result = subprocess.run([str(build / 'client')], input=json.dumps({
            'checkpoint':list(json.dumps(value).encode()), 'events':[]}).encode(),
            capture_output=True, timeout=60)
        assert result.returncode != 0, f'{name} accepted'
        message = result.stderr.decode().strip()
        if name in ('past-final-column','negative-column','oversized-width','wide-repetitions','overlapping-cell'):
            assert 'bridge cell geometry or grapheme' in message, message
        elif name.startswith('inactive-cursor-'):
            assert 'bridge inactive cursor bounds' in message, message
        elif name == 'oversized-default-saved-row':
            assert 'bridge line limit' in message, message
        else:
            assert 'typeMismatch' in message, message
        results[name] = message
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({'wideBoundaryAccepted':True, 'rejected':results}, indent=2)+'\n')
    print(json.dumps({'wideBoundaryAccepted':True, 'rejected':len(results)}))


if __name__ == '__main__':
    main()
