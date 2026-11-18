"""THROWAWAY migration candidate. Scratch paths only; not the account protocol."""
import copy
from contextlib import ExitStack
import errno
import fcntl
import hashlib
import json
import os
import subprocess
import tempfile
import uuid
from pathlib import Path


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


class Refused(Exception):
    pass


def syncdir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic(path, data, fault=''):
    """A same-directory replace; caller fail-stops on uncertain post-rename errors."""
    stage = path.with_suffix(path.suffix + '.stage')
    fd = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            if fault == 'full':
                raise OSError(errno.ENOSPC, 'injected full disk')
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if fault == 'atomic':
            raise OSError(errno.EIO, 'injected failed replace')
        os.replace(stage, path)
        if fault == 'sync':
            raise OSError(errno.EIO, 'injected uncertain directory sync')
        syncdir(path.parent)
    finally:
        if stage.exists():
            stage.unlink()


def canonical(value):
    if isinstance(value, str):
        try:
            return str(uuid.UUID(value))
        except ValueError:
            return value
    if isinstance(value, list):
        return [canonical(v) for v in value]
    if isinstance(value, dict):
        return {k: canonical(v) for k, v in value.items()}
    return value


def identities(value):
    found = []
    def visit(v):
        if isinstance(v, dict):
            for k, child in v.items():
                if k in ('id', 'paneID') and isinstance(child, str):
                    found.append(canonical(child))
                visit(child)
        elif isinstance(v, list):
            for child in v:
                visit(child)
    visit(value)
    return found


def sessions(value):
    result = {}
    def visit(v):
        if isinstance(v, dict):
            if v.get('type') in ('terminal', 'browser') and 'session' in v:
                session = v['session']
                if canonical(session['id']) in result:
                    raise Refused('duplicate runtime identity')
                result[canonical(session['id'])] = {'kind': v['type'], 'value': session}
            for child in v.values():
                visit(child)
        elif isinstance(v, list):
            for child in v:
                visit(child)
    visit(value)
    return result


# Selection, focus, expansion and display overrides belong to this client.
# Terminal/browser content remains intact; server/runtime assignment is separate.
LOCAL_KEYS = {'selectedWorkspaceID', 'selectedTabID', 'focusedTabGroupID',
              'isExpanded', 'globalSettings', 'settingsOverrides'}


def separate(value, server=None):
    local = []
    def visit(v, path):
        if isinstance(v, dict):
            if server is not None and v.get('type') in ('terminal', 'browser') and 'session' in v:
                item = v['session']
                return {'type': v['type'], 'session': {'id': item['id'], 'paneID': item['paneID'], 'server': server}}
            out = {}
            for key, child in v.items():
                if key in LOCAL_KEYS:
                    local.append({'owner': v.get('id', 'client'), 'field': key, 'value': child})
                else:
                    out[key] = visit(child, path + [key])
            return out
        if isinstance(v, list):
            return [visit(child, path + [str(i)]) for i, child in enumerate(v)]
        return v
    return visit(value, []), local


def strict_json(data):
    def unique(pairs):
        value = {}
        for key, child in pairs:
            if key in value:
                raise Refused('duplicate JSON key: ' + key)
            value[key] = child
        return value
    return json.loads(data, object_pairs_hook=unique)


def decode(source, decoder):
    raw = strict_json(source)
    if type(raw.get('version')) is not int or raw['version'] not in (1, 2):
        raise Refused('unsupported or absent version')
    with tempfile.TemporaryDirectory(prefix='myterm-migration-decode-') as scratch:
        path = Path(scratch)
        (path / 'copy.json').write_bytes(source)
        run = subprocess.run([str(decoder), str(path / 'copy.json'), str(path / 'out.json')],
                             capture_output=True, text=True)
        if run.returncode:
            raise Refused('native decoder rejected source: ' + run.stderr[-1200:])
        decoded = json.loads((path / 'out.json').read_bytes())
    snapshot, report = decoded['snapshot'], decoded['report']
    original_ids, output_ids = identities(raw), identities(snapshot)
    if len(original_ids) != len(set(original_ids)):
        raise Refused('conflicting source identities')
    if not set(original_ids).issubset(output_ids):
        raise Refused('native conversion lost an identity')
    if report['dropped'] or report['identifiersRepaired'] or report['structureRepaired']:
        raise Refused('native decoder reported repair: ' + json.dumps(report, sort_keys=True))
    # Session content is checked independently of the decoder's recovery counters.
    before, after = sessions(raw), sessions(snapshot)
    if set(before) != set(after):
        raise Refused('runtime inventory changed')
    for key, record in before.items():
        if canonical(record) != canonical(after[key]):
            raise Refused('runtime content changed: ' + key)
    if raw['version'] == 2 and encoded(raw) != encoded(snapshot):
        raise Refused('v2 normalized or unknown content would be lost')
    if raw['version'] == 1:
        def retains(original, converted):
            if isinstance(original, dict):
                return isinstance(converted, dict) and all(k in converted and retains(v, converted[k]) for k, v in original.items())
            return canonical(original) == canonical(converted)
        if not retains(raw.get('globalSettings', {}), snapshot['globalSettings']):
            raise Refused('legacy settings changed')
        for folder in raw.get('folders', []):
            match = [f for f in snapshot['folders'] if canonical(f['id']) == canonical(folder['id'])]
            if len(match) != 1 or not retains(folder, match[0]):
                raise Refused('legacy folder content changed')
        # Conservative allowlist: never discard a future field during legacy conversion.
        allowed = {
            'root': {'version', 'folders', 'workspaces', 'globalSettings', 'selectedWorkspaceID'},
            'workspace': {'id', 'title', 'emoji', 'color', 'tabs', 'selectedTabID', 'folderID', 'isPinned', 'settingsOverrides'},
            'tab': {'id', 'customTitle', 'content', 'focusedTerminalSessionID', 'focusedPaneID'},
            'content': {'type', 'splitTree', 'session'},
            'node': {'type', 'session', 'children'},
            'folder': {'id', 'title', 'color', 'isExpanded', 'settingsOverrides'},
        }
        def check(v, kind):
            if set(v) - allowed[kind]:
                raise Refused('unknown legacy fields at ' + kind)
        check(raw, 'root')
        for folder in raw.get('folders', []):
            check(folder, 'folder')
        for workspace in raw['workspaces']:
            check(workspace, 'workspace')
            matching = [w for w in snapshot['workspaces'] if canonical(w['id']) == canonical(workspace['id'])]
            if len(matching) != 1:
                raise Refused('workspace identity changed')
            for key, val in workspace.items():
                if key not in ('tabs', 'selectedTabID') and canonical(matching[0].get(key)) != canonical(val):
                    raise Refused('workspace content changed: ' + key)
            def tabs_in(v):
                if isinstance(v, dict):
                    return v.get('tabs', []) + [t for child in v.values() for t in tabs_in(child)]
                if isinstance(v, list):
                    return [t for child in v for t in tabs_in(child)]
                return []
            for tab in workspace['tabs']:
                check(tab, 'tab')
                converted = [t for t in tabs_in(matching[0]['layout']) if canonical(t['id']) == canonical(tab['id'])]
                if len(converted) != 1 or converted[0].get('customTitle') != tab.get('customTitle'):
                    raise Refused('legacy tab identity or title changed')
                content = tab['content']
                check(content, 'content')
                def node(v):
                    check(v, 'node')
                    for child in v.get('children', []):
                        node(child)
                if 'splitTree' in content:
                    node(content['splitTree'])
        # Preserve every legacy field, including focus hints and geometry, for recovery.
        # Live target semantics beyond native v1 conversion remain an integration requirement.
    return raw, snapshot, report


def backup(file, source, fault='', pinned=()):
    folder = file.parent / (file.name + '.automatic-backups')
    folder.mkdir(mode=0o700, exist_ok=True)
    pins_path = folder / 'pins.json'
    durable_pins = json.loads(pins_path.read_bytes()) if pins_path.exists() else {}
    pinned = set(pinned) | set(durable_pins)
    slots = [folder / f'{i}.backup' for i in range(5)]
    # A process exit can leave an incomplete copy. It is never a ready backup.
    for partial in folder.glob('*.partial'):
        if partial.is_symlink() or not partial.is_file():
            raise Refused('non-regular partial backup requires review')
        partial.unlink()
    syncdir(folder)
    legacy = [p for pattern in (file.name + '.v1-backup*', file.name + '.recovery-backup*')
              for p in file.parent.glob(pattern)]
    existing = [p for p in slots + legacy if p.exists()]
    if any(not p.is_file() or p.is_symlink() for p in existing):
        raise Refused('non-regular automatic backup requires review')
    reusable = next((p for p in existing if p.read_bytes() == source), None)
    # Existing versions could leave more than five backups. Reconcile recognized old
    # names and the five new slots together, preserving every pinned recovery copy.
    ceiling = 5 if reusable else 4
    while len(existing) > ceiling:
        eligible = [p for p in existing if str(p) not in pinned and p != reusable]
        if not eligible:
            raise Refused('all five backups protected; source left unchanged')
        oldest = min(eligible, key=lambda p: (p.stat().st_mtime_ns, p.name))
        oldest.unlink()
        syncdir(oldest.parent)
        existing.remove(oldest)
    if reusable:
        return reusable
    chosen = next(slot for slot in slots if not slot.exists())
    partial = chosen.with_suffix('.partial')
    fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            if fault == 'backup-kill':
                stream.write(source[:8])
                stream.flush()
                os.fsync(stream.fileno())
                os._exit(73)
            if fault == 'backup':
                stream.write(source[:8])
                raise OSError(errno.ENOSPC, 'injected backup write failure')
            stream.write(source)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(partial, chosen)
        syncdir(folder)
    except BaseException:
        partial.unlink(missing_ok=True)
        raise
    return chosen


def pin(slot, receipt, protect, file=None):
    folder = file.parent / (file.name + '.automatic-backups') if file is not None else slot.parent
    path = folder / 'pins.json'
    pins = json.loads(path.read_bytes()) if path.exists() else {}
    if protect:
        pins.setdefault(str(slot), [])
        if receipt not in pins[str(slot)]:
            pins[str(slot)].append(receipt)
    else:
        pins = {key: [r for r in values if r != receipt] for key, values in pins.items()}
        pins = {key: values for key, values in pins.items() if values}
    atomic(path, encoded(pins))


def unpin(file, receipt):
    folder = file.parent / (file.name + '.automatic-backups')
    path = folder / 'pins.json'
    if path.exists():
        pin(folder / '0.backup', receipt, False)


def migrate(source_path, target, decoder, server='local-a', account='account-a',
            channel='production', explicit=False, fault='', pinned=()):
    if source_path.resolve() == target.resolve():
        raise Refused('source and target must be separate')
    expected_app = {'production': 'myterm', 'development': 'myterm-dev'}.get(channel)
    if expected_app is None:
        raise Refused('unknown channel')
    if source_path.name == 'workspace-state.json' and source_path.parent.name in ('myterm', 'myterm-dev') and source_path.parent.name != expected_app:
        raise Refused('source channel mismatch')
    target.parent.mkdir(parents=True, exist_ok=True)
    with ExitStack() as locks:
        for path in sorted({source_path.resolve(), target.resolve()}):
            lock = locks.enter_context(open(path.with_suffix(path.suffix + '.migration.lock'), 'a+b'))
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        source = source_path.read_bytes()
        stamp = digest(encoded({'source': str(source_path.resolve()), 'digest': digest(source),
                                'server': server, 'account': account, 'channel': channel}))
        previous = target.read_bytes() if target.exists() else None
        state = json.loads(previous) if previous else {
            'prototypeVersion': 1, 'account': account, 'channel': channel,
            'shared': {'folders': [], 'workspaces': []}, 'local': {}, 'runtime': {}, 'receipts': {}}
        if state['account'] != account or state['channel'] != channel:
            raise Refused('account/channel mismatch')
        if stamp in state['receipts']:
            unpin(source_path, stamp)
            unpin(target, stamp)
            return {'status': 'already committed', 'receipt': stamp}
        if state['shared']['workspaces'] and not explicit:
            raise Refused('existing account layout requires explicit additional import')
        raw, normalized, report = decode(source, decoder)
        shared, local = separate(normalized, server)
        current_ids = set(identities(state['shared'])) | set(state['runtime'])
        incoming_ids = identities(shared)
        if current_ids.intersection(incoming_ids):
            raise Refused('account identity collision; neither side changed')
        candidate = copy.deepcopy(state)
        for key in ('folders', 'workspaces'):
            candidate['shared'][key].extend(shared[key])
        candidate['local'][stamp] = {'preferences': local, 'legacySource': raw}
        for identity, item in sessions(normalized).items():
            candidate['runtime'][identity] = {**item, 'server': server}
        # Receipt and complete candidate share a single atomic snapshot.
        candidate['receipts'][stamp] = {'sourceDigest': digest(source), 'server': server,
                                        'nativeReport': report}
        result = encoded(candidate)
        if json.loads(result) != candidate or fault == 'validation':
            raise Refused('candidate validation failed')
        recovery = backup(source_path, source, fault, pinned)
        pin(recovery, stamp, True, source_path)
        if previous is not None:
            target_recovery = backup(target, previous, fault)
            pin(target_recovery, stamp, True, target)
        if fault == 'before':
            os._exit(71)
        if source_path.read_bytes() != source:
            raise Refused('source changed during preparation')
        atomic(target, result, fault)
        if fault == 'after':
            os._exit(72)
        unpin(source_path, stamp)
        unpin(target, stamp)
        return {'status': 'committed', 'receipt': stamp, 'backup': str(recovery),
                'identities': incoming_ids, 'runtimeCount': len(candidate['runtime']),
                'report': report}
