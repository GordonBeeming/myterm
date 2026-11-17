"""Run the foundation's broader native checkpoint and stream regression suite."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
REVISION = 'ab4f866153ff46c03e1e51de72eec8d85d233d51'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    args = parser.parse_args()
    build = args.build.resolve()
    reference = build / 'reference-root'
    for name in ['script/native-comparison/fixtures.json',
                 'docs/research/myterm-wezterm-feasibility/macos-compatibility/wezterm-traces.json']:
        path = reference / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(subprocess.check_output(['git','show',f'{REVISION}:{name}'],cwd=ROOT))
    sys.path.insert(0, str(build / 'foundation'))
    import checkpoint_checks
    checkpoint_checks.ROOT = reference
    result = checkpoint_checks.check(build / 'native', build / 'server')
    (build / 'regression-results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result['summary']))
    if result['summary']['failed'] or result['summary']['unsupported'] or not result['summary']['nativeStreamPassed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
