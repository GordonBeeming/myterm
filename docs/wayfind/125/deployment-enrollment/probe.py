"""Drive native processes; Python supplies fixtures and assertions, never enrollment policy."""
import argparse
import concurrent.futures
import copy
import hashlib
import json
from pathlib import Path
import platform
import secrets
import selectors
import socket
import subprocess
import tempfile
import time
from datetime import datetime, timezone

HERE = Path(__file__).resolve().parent
CASES = []
PROCESSES = []
TRACE = {}


def check(name, condition, **facts):
    CASES.append(dict(name=name, passed=bool(condition), **facts))
    if not condition:
        raise AssertionError(name)


class Node:
    def __init__(self, binary, mode, init, journal=None, fixture=True):
        args = [str(binary), mode]
        if journal is not None:
            args.append(str(journal))
        if fixture:
            args.append('--fixture-clock')
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, bufsize=1)
        PROCESSES.append(self)
        self.send(init)
        self.ready = self.read()

    def send(self, value):
        self.p.stdin.write(json.dumps(value, separators=(',', ':')) + '\n')
        self.p.stdin.flush()

    def read(self):
        with selectors.DefaultSelector() as selector:
            selector.register(self.p.stdout, selectors.EVENT_READ)
            if not selector.select(15):
                raise TimeoutError('native process response')
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError('native process exited: ' + self.p.stderr.read())
        return json.loads(line)

    def call(self, op, **fields):
        self.send(dict(op=op, **fields))
        return self.read()

    def ok(self, op, **fields):
        result = self.call(op, **fields)
        if not result.get('ok'):
            raise AssertionError(f'{op}: {result}')
        return result['value']

    def stop(self):
        if self.p.poll() is None:
            self.p.stdin.close()
            try:
                self.p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait(timeout=5)
        for stream in (self.p.stdout, self.p.stderr):
            stream.close()


def network(authority, op, **fields):
    host, port = authority.ready['address'].split(':')
    with socket.create_connection((host, int(port)), timeout=5) as sock:
        sock.sendall((json.dumps(dict(op=op, **fields)) + '\n').encode())
        with sock.makefile('rb') as stream:
            line = stream.readline(262145)
            if not line:
                raise EOFError('authority exited before acknowledgement')
            return json.loads(line)


def rejected(name, response, error):
    check(name, response == {'ok': False, 'error': error})


def exercise(binary, scratch):
    seed = secrets.token_hex(32)
    journal = scratch / 'journal.jsonl'
    authority = Node(binary, 'authority', dict(seed=seed), journal)
    root = authority.ready['public']
    TRACE['root_pin'] = root
    authority.ok('clock', now=1000)
    holder = Node(binary, 'endpoint', dict(root=root))
    observer = Node(binary, 'endpoint', dict(root=root))

    def endpoint(fixture=True):
        return Node(binary, 'endpoint', dict(root=root), fixture=fixture)

    def issue(id, mode='reusable', **kw):
        return authority.ok('issue', id=id, mode=mode, holder=holder.ready['public'], **kw)

    def proof(node, cert, name='build-server', relay=False):
        request = node.ok('request', credential=cert['payload']['id'], name=name, relay=relay)
        delegation = holder.ok('delegate', credential=cert, request=request)
        return dict(credential=cert, request=request, delegation=delegation)

    def publish(node):
        snapshot = authority.ok('snapshot')
        return node.ok('snapshot', snapshot=snapshot)

    creator = endpoint()
    creator_cert=issue('creator-bootstrap')
    creator_proof=proof(creator, creator_cert, name='creator')
    check('creator is canonically admitted before credential issuance', network(authority,'enroll',**creator_proof)['ok'])
    reusable = issue('deployment-a', creator=creator.ready['public'])
    check('reusable default is exactly 30 days', reusable['payload']['expires'] == 1000 + 30*86400)
    single = issue('once', 'single-use')
    check('single-use default is exactly 30 minutes', single['payload']['expires'] == 2800)
    for ttl in (0, 1801, 2**64-1):
        rejected(f'single-use rejects TTL {ttl}', authority.call('issue', id=f'bad-{ttl}', mode='single-use', holder=holder.ready['public'], ttl=ttl), 'ttl')
    rejected('reusable rejects unbounded overflow', authority.call('issue', id='overflow', mode='reusable', holder=holder.ready['public'], ttl=2**64-1), 'expiry')
    rejected('credential ID cannot be extended or overwritten', authority.call('issue', id='deployment-a', mode='reusable', holder=holder.ready['public'], ttl=60), 'credential-id')
    replacement = issue('deployment-b', ttl=60)
    check('replacement overlap uses independent IDs', reusable['payload']['id'] != replacement['payload']['id'])

    for remaining, expected in ((604801, 'none'), (604800, 'seven-days'), (86401, 'seven-days'), (86400, 'one-day'), (1, 'one-day'), (0, 'expired')):
        warning = observer.ok('warnings', credential=reusable, now=reusable['payload']['expires']-remaining)
        check(f'warning at {remaining}s remaining', warning == expected)
    check('short-lived replacement immediately warns within one day', observer.ok('warnings', credential=replacement, now=1000) == 'one-day')

    candidates = [endpoint() for _ in range(12)]
    proofs = [proof(node, single) for node in candidates]
    start = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        results = list(pool.map(lambda p: network(authority, 'enroll', **p), proofs))
    duration = (time.perf_counter()-start)*1000
    winners = [i for i, r in enumerate(results) if r.get('ok')]
    check('12 concurrent native TCP redemptions allocate exactly one identity', len(winners)==1 and all(r.get('ok') or r.get('error')=='already-redeemed' for r in results), contenders=12, elapsed_ms=round(duration,3))
    winner = proofs[winners[0]]
    TRACE['single_use'] = dict(winning_proof=winner, rejected_errors=[r.get('error') for r in results if not r.get('ok')])
    old = authority.ok('snapshot')
    TRACE['single_use']['committed_directory'] = old
    check('identical retry does not append another event', network(authority, 'enroll', **winner)['value'] == old)
    authority.stop()
    authority = Node(binary, 'authority', dict(seed=seed), journal)
    authority.ok('clock', now=3000)
    check('native restart replays exact signed state', authority.ok('snapshot') == old)
    check('retry after restart and expiry preserves allocated server', network(authority, 'enroll', **winner)['ok'])
    rejected('losing identity remains refused after restart', network(authority, 'enroll', **proofs[(winners[0]+1)%12]), 'already-redeemed')
    authority.ok('revoke', id='once')
    check('retry after credential revocation preserves allocated server', network(authority, 'enroll', **winner)['ok'])

    # A real process exits after durable commit but before returning its acknowledgement.
    crash_cert = issue('crash-once', 'single-use')
    crash_proof = proof(endpoint(), crash_cert)
    authority.ok('crash-after-sync')
    try:
        network(authority, 'enroll', **crash_proof)
        raise AssertionError('expected connection EOF')
    except EOFError:
        authority.p.wait(timeout=5)
    check('crash injection exits after sync before acknowledgement', authority.p.returncode==74)
    authority.stop()
    authority = Node(binary, 'authority', dict(seed=seed), journal)
    authority.ok('clock', now=3001)
    before = authority.ok('snapshot')
    check('lost acknowledgement retry recovers exact committed allocation', network(authority, 'enroll', **crash_proof)['value']==before)
    publish(observer)
    check('approved client discovers enrolled server from signed directory without per-server pairing', crash_proof['request']['payload']['public'] in publish(observer)['members'])

    check('revoked single-use credential keeps canonical directory membership',winner['request']['payload']['public'] in publish(observer)['members'])
    check('observer distinguishes canonical admission after revocation',observer.ok('recognize',**winner,now=9999)['basis']=='canonical')

    before_crash_cert=issue('crash-before', 'single-use')
    before_crash_proof=proof(endpoint(),before_crash_cert)
    sequence=authority.ok('snapshot')['payload']['sequence']
    authority.ok('crash-before-write')
    try:
        network(authority,'enroll',**before_crash_proof)
        raise AssertionError('expected pre-write EOF')
    except EOFError:
        authority.p.wait(timeout=5)
    check('pre-write crash leaves no acknowledged allocation',authority.p.returncode==75)
    authority.stop()
    authority=Node(binary,'authority',dict(seed=seed),journal)
    authority.ok('clock',now=3001)
    check('pre-write crash replay has unchanged sequence',authority.ok('snapshot')['payload']['sequence']==sequence)
    check('pre-write crash retry allocates exactly once',network(authority,'enroll',**before_crash_proof)['value']['payload']['sequence']==sequence+1)

    # Cached signed authority state is supplied before the old processes go offline.
    offline_cert = issue('offline', ttl=100)
    cached = authority.ok('snapshot')
    isolated = endpoint()
    isolated.ok('snapshot', snapshot=cached)
    offline_server = endpoint()
    offline_proof = proof(offline_server, offline_cert, name='same-name')
    observed_identity = offline_proof['request']['payload']['public']
    authority.stop()
    observer.stop()
    admitted = isolated.ok('recognize', **offline_proof, now=3002)
    TRACE['offline'] = dict(proof=offline_proof, cached_directory=cached, recognition=admitted)
    check('native cached delegation recognition succeeds with authority and prior observer stopped', admitted['accepted']==observed_identity and authority.p.poll() is not None and observer.p.poll() is not None)
    check('native request generator defaults relay intent flag off', offline_proof['request']['payload']['relay'] is False)
    check('locally verified offline server survives credential expiry in same cached view', isolated.ok('recognize', **offline_proof, now=4000)['basis']=='locally-witnessed-provisional')
    newcomer = endpoint()
    newcomer.ok('snapshot', snapshot=cached)
    rejected('unfamiliar offline enrollment first seen at expiry needs approval', newcomer.call('recognize', **offline_proof, now=3101), 'fresh-approval-required')
    rejected('single-use cannot enroll through cached offline route', newcomer.call('recognize', **proofs[(winners[0]+1)%12], now=1001), 'single-use-needs-authority')
    authority = Node(binary, 'authority', dict(seed=seed), journal)
    authority.ok('clock', now=3101)
    rejected('canonical first presentation after expiry needs fresh approval', network(authority, 'enroll', **offline_proof), 'fresh-approval-required')
    TRACE['late_unseen'] = dict(error='fresh-approval-required', first_seen=3101, expires=offline_cert['payload']['expires'])
    authority.ok('fresh-approve', request=offline_proof['request'])
    check('fresh operator approval admits late server with its existing key', observed_identity in publish(newcomer)['members'])

    # Revocation withheld from one verifier is a deliberate negative control.
    revoked_cert = issue('revoke-offline', ttl=1000)
    stale = endpoint()
    stale.ok('snapshot', snapshot=authority.ok('snapshot'))
    unknown = proof(endpoint(), revoked_cert)
    local = proof(endpoint(), revoked_cert)
    stale.ok('recognize', **local, now=3102)
    orphan=proof(endpoint(),revoked_cert)
    stale.ok('recognize',**orphan,now=3102)
    check('authority can tombstone a provisionally enrolled identity it has not admitted',authority.call('remove',public=orphan['request']['payload']['public'])['ok'])
    stale.ok('snapshot',snapshot=authority.ok('snapshot'))
    rejected('delivered tombstone removes provisional identity without revoking its credential',stale.call('recognize',**orphan,now=3102),'removed-identity')
    authority.ok('revoke', id='revoke-offline')
    check('withheld revocation still permits stale cached admission', stale.ok('recognize', **unknown, now=3102)['basis']=='offline-delegation')
    stale.ok('snapshot', snapshot=authority.ok('snapshot'))
    rejected('delivered revocation requires fresh approval for provisional admission without canonical ordering', stale.call('recognize', **local, now=3102), 'fresh-approval-required')
    rejected('canonical revocation rejects unknown server', network(authority, 'enroll', **unknown), 'fresh-approval-required')
    other_holder=endpoint()
    rotation_old=issue('rotation-old')
    rotation_new=authority.ok('issue',id='rotation-new',mode='reusable',holder=other_holder.ready['public'])
    rotate_server=endpoint()
    rotate_request=rotate_server.ok('request',credential='rotation-new',name='new-rollout')
    rotate_delegation=other_holder.ok('delegate',credential=rotation_new,request=rotate_request)
    rotation_proof=dict(credential=rotation_new,request=rotate_request,delegation=rotate_delegation)
    authority.ok('revoke',id='rotation-old')
    check('replacement credential with independent holder enrolls after old credential revocation',network(authority,'enroll',**rotation_proof)['ok'] and rotation_old['payload']['holder']!=rotation_new['payload']['holder'])
    rejected('stale directory predating credential issuance rejects replacement',stale.call('recognize',**rotation_proof,now=3102),'credential-binding')
    current = proof(endpoint(), reusable)
    check('revoking one credential leaves overlapping replacement independent', network(authority, 'enroll', **current)['ok'])
    authority.ok('remove', public=creator.ready['public'])
    fresh = proof(endpoint(), reusable, name='same-name', relay=True)
    check('account-owned delegation survives ordinary creator-key removal', network(authority, 'enroll', **fresh)['ok'])
    rejected('removed creator cannot issue a new credential', authority.call('issue', id='removed-creator', mode='reusable', holder=holder.ready['public'], creator=creator.ready['public']), 'creator-not-current')
    check('native request records explicit relay intent flag', fresh['request']['payload']['relay'] is True)
    directory = publish(newcomer)['members']
    same_names = [p for p,r in directory.items() if r['name']=='same-name']
    check('same-name replacement keeps distinct server identities and prior directory entry', len(same_names)==2 and len(set(same_names))==2)
    check('12 native server processes generate unique identity keys', len({n.ready['public'] for n in candidates})==12)
    authority.ok('remove', public=observed_identity)
    check('explicit server removal deletes only its directory entry', observed_identity not in publish(newcomer)['members'] and fresh['request']['payload']['public'] in publish(newcomer)['members'])
    rejected('removed server cannot re-enroll old identity', network(authority, 'enroll', **offline_proof), 'removed-identity')

    before_cert=issue('boundary-before', 'single-use')
    at_cert=issue('boundary-at', 'single-use')
    before_proof=proof(endpoint(),before_cert)
    at_proof=proof(endpoint(),at_cert)
    authority.ok('clock',now=before_cert['payload']['expires']-1)
    check('single-use unredeemed request succeeds one second before expiry',network(authority,'enroll',**before_proof)['ok'])
    authority.ok('clock',now=at_cert['payload']['expires'])
    rejected('single-use unredeemed request fails exactly at expiry',network(authority,'enroll',**at_proof),'fresh-approval-required')
    authority.ok('clock',now=3101)

    # The attacker can mutate transport artifacts, but cannot forge native signatures.
    valid = proof(endpoint(), reusable)
    for label, area, field, value, error in (
        ('subject name', 'request', 'name', 'substituted','signature'),
        ('subject role', 'request', 'role', 'client','signature'),
        ('subject version', 'request', 'version', 2,'signature'),
        ('noncanonical public key', 'request', 'public', valid['request']['payload']['public'].upper(),'noncanonical-key'),
        ('subject account', 'request', 'account', 'another-account','binding'),
        ('credential lifetime', 'credential', 'expires', 2**62,'signature'),
        ('delegated relay opt-in', 'delegation', 'relay', True,'signature'),
    ):
        attack=copy.deepcopy(valid)
        attack[area]['payload'][field]=value
        result=network(authority,'enroll',**attack)
        rejected(f'native receiver rejects altered {label}', result,error)
    wrong_holder=endpoint()
    rejected('wrong holder cannot delegate credential', wrong_holder.call('delegate', credential=reusable, request=valid['request']), 'holder-binding')
    bad_snapshot=copy.deepcopy(authority.ok('snapshot'))
    bad_snapshot['payload']['state']['revoked']=[]
    rejected('client rejects altered directory', newcomer.call('snapshot', snapshot=bad_snapshot), 'signature')
    rejected('client rejects signed older directory', newcomer.call('snapshot', snapshot=cached), 'rollback-or-fork')
    for op in ('issue','fresh-approve','revoke','remove','clock','crash-after-sync','crash-before-write'):
        rejected(f'network cannot invoke operator command {op}',network(authority,op,id='attack'),'operator-only-or-unknown')
    conflicting=proof(candidates[winners[0]],single,name='changed-name')
    rejected('existing server cannot change signed identity record on retry',network(authority,'enroll',**conflicting),'identity-conflict')
    rejected('fresh approval cannot overwrite existing identity record',authority.call('fresh-approve',request=conflicting['request']),'identity-conflict')
    unknown_request=endpoint().ok('request',credential='does-not-exist',name='unknown')
    rejected('fresh approval requires a registered historical credential reference',authority.call('fresh-approve',request=unknown_request),'unknown-credential')
    swapped=dict(valid,credential=rotation_new)
    rejected('request cannot substitute another valid credential',network(authority,'enroll',**swapped),'credential-binding')
    reused=proof(holder,reusable)
    rejected('credential holder key cannot double as new server identity',network(authority,'enroll',**reused),'key-purpose-reuse')
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        retry_results=list(pool.map(lambda _:network(authority,'enroll',**valid),range(12)))
    check('concurrent identical retries append one canonical admission',all(r['ok'] for r in retry_results) and len({r['value']['payload']['sequence'] for r in retry_results})==1)

    # Saturation bounds are a prototype constraint, not a proposed product quota.
    saturated=0
    while True:
        extra=proof(endpoint(),reusable,name='X'*128)
        result=network(authority,'enroll',**extra)
        if not result['ok']:
            rejected('native identity cap refuses growth before journal framing exhaustion',result,'identity-cap')
            break
        saturated+=1
    while True:
        result=authority.call('issue',id=('C'*110)+str(saturated),mode='reusable',holder=holder.ready['public'])
        if not result['ok']:
            rejected('native credential cap reserves journal headroom',result,'credential-cap')
            break
        saturated+=1
    saturated_snapshot=authority.ok('snapshot')
    check('saturated account still commits credential revocation',authority.call('revoke',id='deployment-a')['ok'])
    victim=next(iter(saturated_snapshot['payload']['state']['members']))
    check('saturated account still commits server removal',authority.call('remove',public=victim)['ok'])
    check('observed saturation stays within fixed journal frame budget',max(len(line) for line in journal.read_bytes().splitlines())<262144,max_journal_line_bytes=max(len(line) for line in journal.read_bytes().splitlines()))

    # A second process must fail rather than open the live journal as another writer.
    p=subprocess.Popen([str(binary),'authority',str(journal)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, error=p.communicate(json.dumps(dict(seed=seed))+'\n', timeout=5)
    check('OS journal lock excludes a second native authority', p.returncode!=0 and 'journal-locked' in error and not out)
    authority.stop()
    for kind in ('tampered','truncated','reordered','wrong-key'):
        path=scratch/f'{kind}.jsonl'
        data=journal.read_bytes()
        if kind=='tampered':
            event=json.loads(data.splitlines()[0]); event['payload']['sequence']=99
            data=json.dumps(event).encode()+b'\n'
        elif kind=='truncated':
            data=data[:-3]
        elif kind=='reordered':
            lines=data.splitlines();lines[0],lines[1]=lines[1],lines[0];data=b'\n'.join(lines)+b'\n'
        else:
            data=journal.read_bytes()
        path.write_bytes(data)
        p=subprocess.Popen([str(binary),'authority',str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out, error=p.communicate(json.dumps(dict(seed=secrets.token_hex(32) if kind=='wrong-key' else seed))+'\n', timeout=5)
        check(f'native journal replay fails closed on {kind} record', p.returncode!=0 and not out and {'tampered':'signature','truncated':'frame-limit-or-eof','reordered':'journal-chain','wrong-key':'signature'}[kind] in error)

    # Live expiry uses normal native clocks; deterministic boundaries above use fixture clocks.
    live = Node(binary,'authority',dict(seed=secrets.token_hex(32)),scratch/'live.jsonl',fixture=False)
    live_holder = Node(binary,'endpoint',dict(root=live.ready['public']),fixture=False)
    live_server = Node(binary,'endpoint',dict(root=live.ready['public']),fixture=False)
    cert=live.ok('issue',id='real-clock',mode='single-use',holder=live_holder.ready['public'],ttl=5)
    request=live_server.ok('request',credential='real-clock',name='live-clock')
    delegate=live_holder.ok('delegate',credential=cert,request=request)
    rejected('normal authority refuses fixture clock controls',live.call('clock',now=1),'fixture-disabled')
    rejected('normal endpoint refuses fixture clock input',live_server.call('warnings',credential=cert,now=1),'fixture-disabled')
    live_success_cert=live.ok('issue',id='real-before',mode='single-use',holder=live_holder.ready['public'],ttl=10)
    live_success_server=Node(binary,'endpoint',dict(root=live.ready['public']),fixture=False)
    live_success_req=live_success_server.ok('request',credential='real-before',name='live-before')
    live_success_del=live_holder.ok('delegate',credential=live_success_cert,request=live_success_req)
    check('real native clock admits an unredeemed credential before expiry',network(live,'enroll',credential=live_success_cert,request=live_success_req,delegation=live_success_del)['ok'])
    started=time.monotonic()
    while time.time()<cert['payload']['expires']:
        time.sleep(0.02)
    result=network(live,'enroll',credential=cert,request=request,delegation=delegate)
    rejected('real native wall-clock expiry rejects previously unredeemed credential',result,'fresh-approval-required')
    reusable_live=live.ok('issue',id='real-offline',mode='reusable',holder=live_holder.ready['public'],ttl=5)
    live_verifier=Node(binary,'endpoint',dict(root=live.ready['public']),fixture=False)
    live_verifier.ok('snapshot',snapshot=live.ok('snapshot'))
    req=live_server.ok('request',credential='real-offline',name='real-offline')
    delegated=live_holder.ok('delegate',credential=reusable_live,request=req)
    check('real endpoint clock recognizes reusable delegation before expiry',live_verifier.ok('recognize',credential=reusable_live,request=req,delegation=delegated)['basis']=='offline-delegation')
    late_server=Node(binary,'endpoint',dict(root=live.ready['public']),fixture=False)
    late_req=late_server.ok('request',credential='real-offline',name='real-late')
    late_del=live_holder.ok('delegate',credential=reusable_live,request=late_req)
    while time.time()<reusable_live['payload']['expires']:
        time.sleep(0.02)
    rejected('real endpoint clock rejects unfamiliar reusable delegation at expiry',live_verifier.call('recognize',credential=reusable_live,request=late_req,delegation=late_del),'fresh-approval-required')
    check('real endpoint clock reports expiry',live_server.ok('warnings',credential=cert)=='expired',wait_ms=round((time.monotonic()-started)*1000,3))


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--build',type=Path,default=Path('/private/tmp/myterm-193-build'))
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    subprocess.run(['cargo','build','--offline','--locked','--manifest-path',str(HERE/'Cargo.toml'),'--target-dir',str(args.build)],check=True)
    binary=args.build/'debug/enrollment-prototype'
    started=datetime.now(timezone.utc).isoformat()
    failure=None
    try:
        with tempfile.TemporaryDirectory(prefix='myterm-193-') as temp:
            exercise(binary,Path(temp))
    except Exception as exc:
        failure=f'{type(exc).__name__}: {exc}'
    finally:
        for node in reversed(PROCESSES):
            node.stop()
    report=dict(started_at=started,ended_at=datetime.now(timezone.utc).isoformat(),
                environment=dict(platform=platform.platform(),machine=platform.machine(),rust=subprocess.check_output(['rustc','--version'],text=True).strip()),
                sources={str(p.relative_to(HERE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (HERE/'src/main.rs',HERE/'Cargo.lock',HERE/'probe.py')},
                public_trace=TRACE,
                cases=CASES,passed=sum(c['passed'] for c in CASES),failure=failure,
                limits=['Disposable root pin, private operator pipes and cached account bootstrap are fixtures.',
                        'Loopback enrollment transport is plaintext; signatures bind public artifacts. No deployed relay, TLS composition, product keystore or Azure execution.',
                        'Boundary clocks are injected only in explicitly enabled native fixture mode; one expiry is observed with real clocks.',
                        'Offline identities and cached trust are native process memory, not durable product endpoint storage.',
                        'Directory-key HPKE evidence is reused from the earlier probe; encryption/key delivery is not integrated here.',
                        'No existing session runtime is transferred or exercised. Directory flags do not prove network relay opt-in enforcement.',
                        'Journal sync/restart covers process exit, not power failure or rollback protection against restored authority snapshots.',
                        'Cached revocation can be withheld indefinitely. Bootstrap freshness and honest clock/authority assumptions remain.',
                        'Only macOS ARM64 is executed; production and native Linux/Windows acceptance remain open.'])
    (args.output/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(passed=report['passed'],checks=len(CASES),failure=failure)))
    if failure:
        raise SystemExit(1)


if __name__=='__main__':
    main()
