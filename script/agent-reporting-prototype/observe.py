"""Disposable, passive native hook observer. Emits no approval decisions."""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import sys
import time

from candidate import replay


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('agent', choices=['claude', 'codex'])
    parser.add_argument('directory', type=Path)
    parser.add_argument('--record')
    args = parser.parse_args()
    raw = args.record.encode() if args.record is not None else sys.stdin.buffer.read(512 * 1024 + 1)
    if len(raw) > 512 * 1024:
        raise ValueError('Prototype hook input exceeds diagnostic bound')
    event = json.loads(raw)
    record = {'debugTag': '[DEBUG-myterm-agent-reporting]', 'agent': args.agent,
              'observedUTC': datetime.now(timezone.utc).isoformat(), 'observedMonotonicNS': time.monotonic_ns(),
              'event': event}
    args.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = args.directory / 'native-hooks.jsonl'
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(descriptor, 'a+') as output:
        fcntl.flock(output, fcntl.LOCK_EX)
        # Do not leave a healthy-looking snapshot behind if this process dies
        # after recording a new event but before publishing its derived state.
        (args.directory / 'candidate-state.json').unlink(missing_ok=True)
        output.write(json.dumps(record) + '\n')
        output.flush()
        output.seek(0)
        try:
            records = [json.loads(line) for line in output]
            if any(row['event'].get('observer_error_count', 0) for row in records):
                raise ValueError('Native observer previously failed; event history is incomplete')
            state = replay(args.agent, records).state()
        except Exception as error:
            # A damaged event history cannot be replayed as trustworthy current
            # state. Preserve the evidence and withdraw the old snapshot.
            (args.directory / 'candidate-state.json').unlink(missing_ok=True)
            invalid = {'captureValid': False, 'errorType': type(error).__name__,
                       'debugTag': '[DEBUG-myterm-agent-reporting]'}
            (args.directory / 'capture-invalid.json').write_text(json.dumps(invalid) + '\n')
            raise
        state['captureValid'] = True
        temporary = args.directory / 'candidate-state.tmp'
        temporary.write_text(json.dumps(state, indent=2) + '\n')
        temporary.replace(args.directory / 'candidate-state.json')
        fcntl.flock(output, fcntl.LOCK_UN)


if __name__ == '__main__':
    main()
