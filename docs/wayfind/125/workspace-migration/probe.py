"""Run the bounded native-schema / real scratch-file experiment, never user files."""
import argparse
import fcntl
import copy
import json
import os
import platform
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

from migration import Refused, atomic, backup, decode, digest, encoded, identities, migrate, separate, sessions

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]


def ident(n):
    return str(uuid.UUID(int=n)).upper()


def legacy(offset=0):
    def u(n):
        return ident(n + offset)
    terminal = {'type': 'terminal', 'session': {'id': u(10), 'paneID': u(11),
                'workingDirectory': 'file:///prototype/work', 'recentText': 'preserve this output'}}
    browser = {'type': 'browser', 'session': {'id': u(12), 'paneID': u(13),
               'url': 'https://example.invalid/review', 'profile': {
                   'scope': 'project-directory', 'persistentStoreID': u(14),
                   'projectDirectory': 'file:///prototype/work'}}}
    return {'version': 1, 'globalSettings': {'fontSize': 17},
            'folders': [{'id': u(1), 'title': 'Work', 'color': 'blue', 'isExpanded': False}],
            'workspaces': [{'id': u(2), 'title': 'Same name', 'folderID': u(1),
                'isPinned': True, 'tabs': [{'id': u(3), 'customTitle': 'Keep title',
                  'focusedTerminalSessionID': u(10), 'focusedPaneID': u(11),
                  'content': {'type': 'terminal', 'splitTree': {
                      'type': 'horizontal', 'children': [terminal, browser]}}}], 'selectedTabID': u(3)}],
            'selectedWorkspaceID': u(2)}


def run(output):
    output.mkdir(parents=True, exist_ok=True)
    binary = output / 'decoder'
    compiler = subprocess.run(['swiftc', '-parse-as-library', '-o', str(binary)] +
        [str(p) for p in sorted((REPO / 'Sources/MyTermCore').glob('*.swift'))] +
        [str(HERE / 'Decoder.swift')], capture_output=True, text=True)
    (output / 'build.log').write_text(compiler.stdout + compiler.stderr)
    if compiler.returncode:
        raise RuntimeError('Swift adapter build failed; inspect ' + str(output / 'build.log'))
    records = []
    def check(name, condition, **observed):
        records.append({'name': name, 'passed': bool(condition), **observed})
        if not condition:
            raise AssertionError(name + ': ' + repr(observed))
    native = decode(encoded(legacy()), binary)
    v1, v2 = legacy(), native[1]
    fixtures = {'v1': v1, 'v2': v2, 'remote-v2': decode(encoded(legacy(100)), binary)[1]}
    complex_v1 = legacy(2000)
    second = copy.deepcopy(legacy(3000)['workspaces'][0]['tabs'][0])
    second['customTitle'] = 'Inactive split tab'
    second['content']['splitTree']['type'] = 'vertical'
    complex_v1['workspaces'][0]['tabs'].append(second)
    _, complex_v2, _ = decode(encoded(complex_v1), binary)
    fixtures['v1-multiple-tabs'] = complex_v1
    fixtures['v2-multiple-tabs'] = complex_v2
    check('v1 inactive split tabs: full session identity/content retention',
          sessions(complex_v1).keys() == sessions(complex_v2).keys() and
          set(identities(complex_v1)).issubset(identities(complex_v2)),
          original=sessions(complex_v1), converted=sessions(complex_v2))
    focused_id = complex_v2['workspaces'][0]['focusedTabGroupID']
    focused = next(child['group'] for child in complex_v2['workspaces'][0]['layout']['children']
                   if child['group']['id'] == focused_id)
    expected_sessions = [ident(2010).lower(), ident(3010).lower(), ident(3012).lower()]
    actual_sessions = [t['content']['session']['id'] for t in focused['tabs']]
    check('v1 inactive split tabs: native structural rewrite recorded',
          actual_sessions == expected_sessions,
          expectedFocusedSessions=expected_sessions, actualFocusedSessions=actual_sessions,
          original=complex_v1['workspaces'][0], converted=complex_v2['workspaces'][0])
    with tempfile.TemporaryDirectory(prefix='myterm-complex-migration-') as scratch:
        folder = Path(scratch)
        source, target = folder/'source.json', folder/'account.json'
        source.write_bytes(encoded(complex_v1))
        migrate(source, target, binary)
        complex_state = json.loads(target.read_bytes())
        check('v1 inactive split tabs: full migration retains content identities',
              len(complex_state['runtime']) == 4 and set(identities(complex_v1)).issubset(
                  set(identities(complex_state['shared'])) | set(identities(complex_state['runtime']))))
    for name, value in fixtures.items():
        (output / (name + '.json')).write_bytes(encoded(value))
    inventories = {name: {'identities': identities(value), 'sessions': sessions(value)}
                   for name, value in fixtures.items()}
    for channel, app in [('production', 'myterm'), ('development', 'myterm-dev')]:
        with tempfile.TemporaryDirectory(prefix='myterm-migration-') as scratch:
            base = Path(scratch)
            source = base / 'Application Support' / app / 'workspace-state.json'
            source.parent.mkdir(parents=True)
            for version in ('v1', 'v2'):
                scenario = base / version
                scenario.mkdir()
                file = scenario / source.name
                file.write_bytes(encoded(fixtures[version]))
                target = scenario / 'account.json'
                first = migrate(file, target, binary, channel=channel)
                data = target.read_bytes()
                state = json.loads(data)
                check(f'{channel}/{version}: stable source and IDs', file.read_bytes() == encoded(fixtures[version])
                      and set(identities(fixtures[version])).issubset(set(identities(state['shared'])) | set(identities(state['runtime']))),
                      expected=identities(fixtures[version]), actual=first['identities'])
                check(f'{channel}/{version}: terminal/browser content',
                      {k: {'kind': v['kind'], 'value': v['value']} for k, v in state['runtime'].items()}
                      == sessions(v2), expected=sessions(v2), actual=state['runtime'])
                check(f'{channel}/{version}: server binding',
                      all(r['server'] == 'local-a' for r in state['runtime'].values()))
                check(f'{channel}/{version}: shared preference separation',
                      separate(state['shared'])[1] == [] and bool(state['local']))
                check(f'{channel}/{version}: server payload outside shared structure',
                      all(set(r['value']) == {'id', 'paneID', 'server'} for r in sessions(state['shared']).values()))
                preferences = state['local'][first['receipt']]['preferences']
                check(f'{channel}/{version}: concrete preference values retained',
                      any(p['field'] == 'globalSettings' and p['value']['fontSize'] == 17 for p in preferences)
                      and any(p['field'] == 'selectedWorkspaceID' and p['value'] == v2['selectedWorkspaceID'] for p in preferences)
                      and any(p['field'] == 'focusedTabGroupID' and p['value'] == v2['workspaces'][0]['focusedTabGroupID'] for p in preferences)
                      and any(p['field'] == 'isExpanded' and p['value'] is False for p in preferences), actual=preferences)
                check(f'{channel}/{version}: exact retry',
                      migrate(file, target, binary, channel=channel)['status'] == 'already committed'
                      and target.read_bytes() == data and len(state['runtime']) == 2)
                check(f'{channel}/{version}: source backup bytes and limit',
                      Path(first['backup']).read_bytes() == file.read_bytes()
                      and len(list(scenario.glob('*.automatic-backups/*.backup'))) == 1)
                if version == 'v1':
                    source.write_bytes(file.read_bytes())
                    check(f'{channel}: actual channel path fixture',
                          source.parts[-2:] == (app, 'workspace-state.json'))
            # Existing account work: explicit choice, additive merge, identity collision refusal.
            source.write_bytes(encoded(fixtures['remote-v2']))
            target = base / 'account.json'
            migrate(source, target, binary, server='remote-b', channel=channel)
            source.write_bytes(encoded(v2))
            before = target.read_bytes()
            try:
                migrate(source, target, binary, channel=channel)
            except Refused as error:
                check(f'{channel}: explicit additional import', target.read_bytes() == before, reason=str(error))
            else:
                check('must refuse implicit import', False)
            migrate(source, target, binary, explicit=True, channel=channel)
            state = json.loads(target.read_bytes())
            check(f'{channel}: same-name workspaces stay separate',
                  [w['title'] for w in state['shared']['workspaces']] == ['Same name', 'Same name']
                  and len({w['id'] for w in state['shared']['workspaces']}) == 2)
            check(f'{channel}: mixed-server assignment preserved',
                  {r['server'] for r in state['runtime'].values()} == {'local-a', 'remote-b'}
                  and len(state['runtime']) == 4)
            before = target.read_bytes()
            collision = copy.deepcopy(v2)
            collision['workspaces'][0]['title'] = 'Conflicting identity'
            source.write_bytes(encoded(collision))
            try:
                migrate(source, target, binary, explicit=True, channel=channel)
            except Refused as error:
                check(f'{channel}: conflicting source vs account', target.read_bytes() == before, reason=str(error))
            else:
                check('must reject identity collision', False)
            # Real permissions plus named injected I/O failures, isolated for each run.
            for fault in ('backup', 'validation', 'full', 'atomic', 'sync', 'before', 'after', 'backup-kill', 'readonly'):
                folder = base / ('fault-' + fault)
                folder.mkdir()
                src = folder / 'workspace-state.json'
                src.write_bytes(encoded(v2))
                destdir = folder / 'target'
                destdir.mkdir()
                dest = destdir / 'account.json'
                if fault == 'readonly':
                    destdir.chmod(0o500)
                process = subprocess.run([sys.executable, str(HERE / 'worker.py'),
                    str(src), str(dest), str(binary), fault, channel], capture_output=True, text=True)
                destdir.chmod(0o700)
                check(f'{channel}: {fault} preserves source', src.read_bytes() == encoded(v2),
                      exitCode=process.returncode, stderr=process.stderr[-1800:])
                if fault in ('before', 'after', 'backup-kill'):
                    check(f'{channel}: {fault} named exit reached', process.returncode == {'before':71,'after':72,'backup-kill':73}[fault])
                    if fault == 'backup-kill':
                        check(f'{channel}: partial backup never ready', len(list(folder.glob('*.automatic-backups/*.partial'))) == 1 and not list(folder.glob('*.automatic-backups/*.backup')))
                elif fault != 'readonly':
                    check(f'{channel}: {fault} named failure reached', process.returncode != 0 and ('injected' in process.stderr or 'validation failed' in process.stderr))
                committed = fault in ('sync', 'after')
                check(f'{channel}: {fault} commit boundary', dest.exists() == committed,
                      targetExists=dest.exists())
                if fault == 'readonly':
                    check(f'{channel}: real EACCES observed', 'PermissionError' in process.stderr)
                if fault == 'backup':
                    check(f'{channel}: failed backup stops commit',
                          not list(folder.glob('*.automatic-backups/*.backup')))
                retry = migrate(src, dest, binary, channel=channel)
                state = json.loads(dest.read_bytes())
                check(f'{channel}: {fault} restart and retry', not list(folder.glob('*.automatic-backups/*.partial')) and len(state['runtime']) == 2
                      and len(state['shared']['workspaces']) == 1 and len(state['receipts']) == 1,
                      retry=retry['status'])
            # Failure while importing into an existing mixed-server account preserves it.
            for fault in ('full', 'atomic', 'validation', 'backup', 'sync'):
                folder = base / ('existing-' + fault)
                folder.mkdir()
                src, dest = folder / 'source.json', folder / 'account.json'
                src.write_bytes(encoded(fixtures['remote-v2']))
                migrate(src, dest, binary, channel=channel, server='remote-b')
                previous = dest.read_bytes()
                src.write_bytes(encoded(v2))
                try:
                    migrate(src, dest, binary, channel=channel, explicit=True, fault=fault)
                except (OSError, Refused):
                    check(f'{channel}: existing account survives {fault}',
                          (dest.read_bytes() == previous if fault != 'sync' else
                           len(json.loads(dest.read_bytes())['shared']['workspaces']) == 2)
                          and src.read_bytes() == encoded(v2))
                else:
                    check('must exercise existing account failure', False)
                migrate(src, dest, binary, channel=channel, explicit=True)
                recovered = json.loads(dest.read_bytes())
                check(f'{channel}: existing account {fault} retry', len(recovered['runtime']) == 4
                      and len(recovered['shared']['workspaces']) == 2)
            check(f'{channel}: private target permissions', dest.stat().st_mode & 0o777 == 0o600)
            # Persisted recovery pins survive an abrupt process exit and rotation.
            interrupted = base / 'durable-pins'
            interrupted.mkdir()
            src, dest = interrupted / 'source.json', interrupted / 'account.json'
            src.write_bytes(encoded(v2))
            exit_run = subprocess.run([sys.executable, str(HERE / 'worker.py'), str(src), str(dest), str(binary), 'before', channel])
            pinsfile = interrupted / 'source.json.automatic-backups' / 'pins.json'
            pins = json.loads(pinsfile.read_bytes())
            protected_path = Path(next(iter(pins)))
            for i in range(9):
                backup(src, ('other-' + str(i)).encode())
                check(f'{channel}: durable pin survives rotation {i}', protected_path.read_bytes() == encoded(v2)
                      and len(list(protected_path.parent.glob('*.backup'))) <= 5)
            migrate(src, dest, binary, channel=channel)
            check(f'{channel}: successful retry releases durable pin', not json.loads(pinsfile.read_bytes()))
            # Legacy backup names count toward the same maximum.
            legacyfile = interrupted / 'legacy.json'
            old_copies = []
            for i in range(7):
                old = interrupted / ('legacy.json.v1-backup' if i == 0 else 'legacy.json.recovery-backup-20260821-092105-' + str(i))
                old.write_bytes(('legacy-' + str(i)).encode())
                old_copies.append(old)
            recovered = backup(legacyfile, b'new original', pinned=[str(old_copies[0])])
            total = len(list(interrupted.glob('legacy.json.v1-backup*'))) + len(list(interrupted.glob('legacy.json.recovery-backup*'))) + len(list(interrupted.glob('legacy.json.automatic-backups/*.backup')))
            check(f'{channel}: old backup names share five-copy limit', total == 5 and old_copies[0].exists()
                  and recovered.read_bytes() == b'new original')
            # The candidate single-writer lock rejects a competing migrator.
            with open(src.with_suffix('.json.migration.lock'), 'a+b') as locked:
                fcntl.flock(locked, fcntl.LOCK_EX | fcntl.LOCK_NB)
                before = dest.read_bytes()
                process = subprocess.run([sys.executable, str(HERE / 'worker.py'), str(src), str(dest), str(binary), '', channel], capture_output=True, text=True)
                check(f'{channel}: competing migrator refused', process.returncode != 0 and dest.read_bytes() == before
                      and 'BlockingIOError' in process.stderr)
            # Cross-channel and source/target mistakes cannot silently reuse receipts.
            for label, other_target, other_channel in [('wrong target channel', dest, 'development' if channel == 'production' else 'production'),
                                                      ('source is target', src, channel)]:
                before = src.read_bytes()
                try:
                    migrate(src, other_target, binary, channel=other_channel)
                except Refused as error:
                    check(f'{channel}: {label}', src.read_bytes() == before, reason=str(error))
                else:
                    check('must reject ' + label, False)
            # Malformed inputs rejected before any account write.
            bads = {}
            unknown = copy.deepcopy(v2); unknown['version'] = 999; bads['unknown version'] = unknown
            lossy = copy.deepcopy(v2); lossy['workspaces'].append({'id': False}); bads['lossy array'] = lossy
            duplicate = copy.deepcopy(v2); duplicate['workspaces'].append(copy.deepcopy(v2['workspaces'][0])); bads['duplicate IDs'] = duplicate
            repair = copy.deepcopy(v2); repair['workspaces'][0]['isPinned'] = 'broken'; bads['structural repair'] = repair
            future = copy.deepcopy(v2); future['futureField'] = 'keep'; bads['unknown field'] = future
            bads['damaged JSON'] = b'{'
            bads['duplicate JSON keys'] = b'{"version":2,"version":1}'
            settings = legacy(); settings['globalSettings']['fontSize'] = 'bad'; bads['legacy settings repair'] = settings
            folder = legacy(); folder['folders'][0]['isExpanded'] = 'bad'; bads['legacy folder repair'] = folder
            newer = legacy(); newer['workspaces'][0]['futureField'] = 'keep'; bads['legacy unknown field'] = newer
            for name, value in bads.items():
                folder = base / name
                folder.mkdir()
                src, dest = folder / 'source.json', folder / 'target.json'
                original = value if isinstance(value, bytes) else encoded(value)
                src.write_bytes(original)
                try:
                    migrate(src, dest, binary, channel=channel)
                except (Refused, ValueError) as error:
                    expected_reason = {'legacy settings repair':'legacy settings changed', 'legacy folder repair':'native conversion lost an identity', 'legacy unknown field':'unknown legacy fields'}.get(name)
                    if expected_reason:
                        check(f'{channel}: {name} exact refusal', expected_reason in str(error), reason=str(error))
                    check(f'{channel}: refuses {name}', src.read_bytes() == original and not dest.exists(), reason=str(error))
                else:
                    check('must reject ' + name, False)
            # Exercise channel routing and account/assigned-server receipt bindings.
            for label, changes in [('source channel', {'channel':'development' if channel == 'production' else 'production'}),
                                   ('account', {'account':'account-b'}), ('assigned server', {'server':'other-server'})]:
                before = target.read_bytes()
                try:
                    migrate(source, target, binary, explicit=True, **({'channel':channel} | changes))
                except Refused as error:
                    expected_reason = {'source channel':'source channel mismatch', 'account':'account/channel mismatch', 'assigned server':'account identity collision'}[label]
                    check(f'{channel}: rejects changed {label}', target.read_bytes() == before and expected_reason in str(error), reason=str(error))
                else:
                    check('must refuse changed ' + label, False)
            # Five abandoned attempts retain their recovery copies and stop a sixth.
            abandoned = base / 'abandoned'
            abandoned.mkdir()
            src, dest = abandoned / 'source.json', abandoned / 'account.json'
            for i in range(5):
                src.write_bytes(encoded(legacy(1000 + i * 100)))
                process = subprocess.run([sys.executable, str(HERE/'worker.py'), str(src), str(dest), str(binary), 'before', channel])
                check(f'{channel}: abandoned attempt {i} exits at boundary', process.returncode == 71)
            src.write_bytes(encoded(v2))
            try:
                migrate(src, dest, binary, channel=channel)
            except Refused as error:
                check(f'{channel}: abandoned pins stop sixth attempt', not dest.exists() and src.read_bytes() == encoded(v2)
                      and len(list(abandoned.glob('*.automatic-backups/*.backup'))) == 5, reason=str(error))
            else:
                check('must stop on abandoned pins', False)
            # Max-five rotation: actual files, protected slot, failed copy, all pinned.
            ring = base / 'ring' / 'workspace-state.json'
            ring.parent.mkdir()
            for i in range(5):
                backup(ring, ('old-' + str(i)).encode())
            slots = sorted(ring.parent.glob('*.automatic-backups/*.backup'))
            protected = slots[0]
            protected_data = protected.read_bytes()
            oldest_eligible = min(slots[1:], key=lambda p: (p.stat().st_mtime_ns, p.name))
            recovery = backup(ring, b'current recovery', pinned=[str(protected)])
            check(f'{channel}: five slots rotate oldest eligible', len(list(ring.parent.glob('*.automatic-backups/*.backup'))) == 5
                  and protected.read_bytes() == protected_data and recovery == oldest_eligible)
            try:
                backup(ring, b'blocked', pinned=[str(p) for p in slots])
            except Refused as error:
                check(f'{channel}: all slots pinned stops safely', recovery.read_bytes() == b'current recovery', reason=str(error))
            else:
                check('must refuse all pinned', False)
            try:
                backup(ring, b'failure', fault='backup', pinned=[str(protected), str(recovery)])
            except OSError:
                check(f'{channel}: failed rotation keeps pinned recovery',
                      protected.read_bytes() == protected_data and recovery.read_bytes() == b'current recovery'
                      and len(list(ring.parent.glob('*.automatic-backups/*.backup'))) <= 5)
    result = {'scope': 'native Swift schema adapter plus Python scratch-file transaction candidate',
              'environment': {'system': platform.system(), 'release': platform.release(), 'machine': platform.machine(),
                              'swift': subprocess.check_output(['swift', '--version'], text=True).strip()},
              'passed': sum(r['passed'] for r in records), 'failed': sum(not r['passed'] for r in records),
              'records': records, 'inventories': inventories,
              'hashes': {str(p.relative_to(REPO)): digest(p.read_bytes()) for p in
                  [HERE / 'Decoder.swift', HERE / 'migration.py', HERE / 'probe.py', HERE / 'worker.py'] +
                  sorted((REPO / 'Sources/MyTermCore').glob('*.swift'))}}
    (output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'passed': result['passed'], 'failed': result['failed'], 'output': str(output)}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    run(args.output.resolve())
