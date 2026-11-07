#!/usr/bin/env python3
"""Run the throwaway native adapters and engine traces without launching any app UI."""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import socket
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
WINDOWS = os.name == 'nt'
EXE = '.exe' if WINDOWS else ''
ANSI = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)')


def run(command, *, cwd=ROOT, stdin=None, timeout=180):
    result = subprocess.run([str(a) for a in command], cwd=cwd, input=stdin,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{command}: exit {result.returncode}\n{result.stderr.decode(errors="replace")}\n{result.stdout.decode(errors="replace")}')
    return result.stdout


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def normalize(results):
    for trace in results.values():
        for snap in trace['snapshots']:
            if isinstance(snap['replies'], str):
                snap['replies'] = list(base64.b64decode(snap['replies']))
        if isinstance(trace['finalReplies'], str):
            trace['finalReplies'] = list(base64.b64decode(trace['finalReplies']))
    return results


class Session:
    def __init__(self, binary, command, directory):
        self.token = secrets.token_hex(32)
        self.log = (directory / 'session-stderr.log').open('ab')
        self.process = subprocess.Popen([str(binary), '--session', *map(str, command)],
                                        stdout=subprocess.PIPE, stderr=self.log,
                                        env={**os.environ, 'MYTERM_PROBE_TOKEN': self.token})
        # Bound startup independently of the candidate watchdog, including a failed native spawn.
        import concurrent.futures
        self.pool = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        try:
            line = self.pool.submit(self.process.stdout.readline).result(timeout=15)
            hello = json.loads(line)
            host, port = hello['address'].rsplit(':', 1)
            if host != '127.0.0.1':
                raise RuntimeError('probe must bind IPv4 loopback only')
            self.address = (host, int(port))
            self.pid = hello['pid']
        except BaseException:
            self.close()
            raise

    def request(self, op, **values):
        if isinstance(values.get('data'), bytes):
            values['data'] = list(values['data'])
        with socket.create_connection(self.address, timeout=8) as client:
            client.sendall((json.dumps({'token': self.token, 'op': op, **values}) + '\n').encode())
            response = json.loads(client.makefile('rb').readline(2 * 1024 * 1024))
        if response.get('error'):
            raise RuntimeError(response['error'])
        if response['pid'] != self.pid:
            raise RuntimeError('child PID changed across reconnect')
        response['data'] = (base64.b64decode(response['data']) if isinstance(response['data'], str)
                            else bytes(response['data']))
        return response

    def wait_for(self, marker, timeout=12, require_retained=False):
        deadline = time.monotonic() + timeout
        last = b''
        while time.monotonic() < deadline:
            response = self.request('read')
            last = response['data']
            if marker in ANSI.sub(b'', last):
                if require_retained and marker not in ANSI.sub(b'', last[:response['outputLengthAtAccept']]):
                    time.sleep(.025)
                    continue
                return last
            time.sleep(.025)
        raise RuntimeError(f'output marker {marker!r} missing; captured {last[-3000:]!r}')

    def close(self):
        if self.process.poll() is None and hasattr(self, 'address'):
            try:
                self.request('terminate')
                self.process.wait(timeout=8)
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
                print(f"graceful probe cleanup failed: {error}", file=sys.stderr)
        if self.process.poll() is None:
            # The probe normally kills/reaps its child when the listener exits. This is
            # only the independent outer failure bound, never the normal cleanup path.
            self.process.terminate()
            try:
                self.process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.process.stdout.close()
        self.log.close()
        self.pool.shutdown(wait=False, cancel_futures=True)


def native_geometry(binary, fixture, directory):
    session = Session(binary, [fixture, '--child'], directory)
    try:
        if WINDOWS:
            session.wait_for(b'MYTERM_CHILD_READY')
        for request in [('read', {'token': 'invalid'}), ('resize', {'cols': 0, 'rows': 31})]:
            try:
                session.request(request[0], **request[1])
            except RuntimeError:
                continue
            raise RuntimeError('probe accepted invalid token or geometry')
        session.request('resize', cols=101, rows=31)
        session.request('write', data=b'PTY_INPUT\r' if WINDOWS else b'PTY_INPUT\n')
        captured = session.wait_for(b'MYTERM_NATIVE_OK 101 31')
        session.request('stop')
        code = session.process.wait(timeout=8)
        if code:
            raise RuntimeError(f'geometry adapter exited {code}')
        return {'status': 'pass', 'pid': session.pid, 'bytes': len(captured),
                'checks': ['native terminal stdin/stdout', '101x31 child-observed geometry',
                           'input/output', 'invalid token and invalid geometry rejected', 'successful child exit and adapter teardown']}
    finally:
        session.close()


def shell_commands(kind, marker):
    begin = 'MYTERM_START_' + marker.removeprefix('MYTERM_')
    if kind == 'cmd':
        def emit(value):
            return 'echo ' + '^'.join(value)
        command = emit(marker)
        delayed = 'ping -n 2 127.0.0.1 >nul & ' + command
        final = emit(begin) + '& (for /L %i in (1,1,4096) do @echo xxxxxxxxxxxxxxxx)& ' + command + '& exit 0'
    elif kind == 'powershell':
        def emit(value):
            return '[Console]::WriteLine([Text.Encoding]::UTF8.GetString([byte[]](' + ','.join(map(str, value.encode())) + ')))'
        command = emit(marker)
        delayed = 'Start-Sleep -Milliseconds 250; ' + command
        final = emit(begin) + "; [Console]::Write(([char]120).ToString()*65536); " + command + '; exit 0'
    else:
        def emit(value):
            return "printf '" + ''.join('\\%03o' % b for b in value.encode()) + "\\n'"
        command = emit(marker)
        delayed = 'sleep 0.25; ' + command
        final = emit(begin) + "; head -c 65536 /dev/zero | tr '\\000' '\\170'; " + command + '; exit 0'
    return command, delayed, final


def shell_session(binary, command, kind, directory):
    session = Session(binary, command, directory)
    # A marker is generated per stage, so stale output cannot satisfy later assertions.
    ready, detached, final = ['MYTERM_' + secrets.token_hex(8).upper() for _ in range(3)]
    newline = '\r' if WINDOWS else '\n'
    try:
        session.request('write', data=(shell_commands(kind, ready)[0] + newline).encode())
        session.wait_for(ready.encode())
        session.request('resize', cols=101, rows=31)
        before_detach = session.request('write', data=(shell_commands(kind, detached)[1] + newline).encode())
        if detached.encode() in ANSI.sub(b'', before_detach['data']):
            raise RuntimeError('detached marker arrived before the observer disconnected')
        # No client socket is connected while the delayed command emits its output.
        time.sleep(1.5 if kind == 'cmd' else .5)
        captured = session.wait_for(detached.encode(), require_retained=True)
        session.request('write', data=(shell_commands(kind, final)[2] + newline).encode())
        captured = session.wait_for(final.encode(), timeout=20)
        session.request('stop')
        code = session.process.wait(timeout=8)
        if code:
            raise RuntimeError(f'shell adapter exited {code}')
        clean = ANSI.sub(b'', captured)
        begin = ('MYTERM_START_' + final.removeprefix('MYTERM_')).encode()
        start = clean.index(begin) + len(begin)
        end = clean.index(final.encode(), start)
        payload = clean[start:end].replace(b'\r', b'').replace(b'\n', b'')
        if payload != b'x' * 65536:
            raise RuntimeError(f'final payload mismatch: {len(payload)} bytes between fresh output-only markers')
        return {'status': 'pass', 'shell': command, 'pid': session.pid,
                'capturedBytes': len(captured), 'checks': ['shell startup and input/output', 'resize API',
                'real loopback disconnect and reconnect, same child PID', 'retained detached output',
                'exact 65536-byte payload between output-only markers', 'successful child exit and adapter teardown'],
                'limits': ['retained raw bytes, not engine checkpoints',
                           'one probe client; no production transport, writer lease or slow reader policy',
                           'process-tree termination and service lifecycle not verified']}
    finally:
        session.close()


def build(output, skip_swift):
    binaries = {}
    go_bin = output / ('go-probe' + EXE)
    run(['go', 'build', '-trimpath', '-o', go_bin, '.'], cwd=HERE / 'go')
    binaries['go'] = go_bin
    rust_target = output / 'rust-build'
    run(['cargo', 'build', '--locked', '--target-dir', rust_target], cwd=HERE / 'rust')
    binaries['rust'] = rust_target / 'debug' / ('myterm-native-comparison-prototype' + EXE)
    fixture = output / ('pty-probe' + EXE)
    compiler = 'clang' if WINDOWS else 'cc'
    args = [compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', ROOT / 'script/native-validation/pty_probe.c', '-o', fixture]
    if platform.system() == 'Linux':
        args.append('-lutil')
    run(args)
    if not skip_swift:
        scratch = output / 'swift-build'
        args = ['swift', 'build', '--package-path', HERE / 'swift', '--scratch-path', scratch]
        run(args, timeout=240)
        bin_path = run([*args, '--show-bin-path']).decode().strip().splitlines()[-1]
        binaries['swiftterm'] = Path(bin_path) / 'Baseline'
    return binaries, fixture


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--skip-swift', action='store_true', help='non-Mac native adapters only; no SwiftTerm parity claim')
    options = parser.parse_args()
    output = options.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    (output / 'session-stderr.log').write_bytes(b'')
    fixtures = (HERE / 'fixtures.json').read_bytes()
    meta = {'startedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'os': platform.platform(), 'cpu': platform.machine(), 'python': sys.version,
            'fixturesSHA256': hashlib.sha256(fixtures).hexdigest(), 'status': 'running',
            'scope': 'Throwaway Go/Rust server candidates; all client apps stay native. macOS server may use Go/Rust.'}
    for tool in ['go', 'rustc', 'cargo'] + ([] if options.skip_swift else ['swift']):
        meta[tool] = run([tool, 'version' if tool == 'go' else '--version']).decode().strip()
    write_json(output / 'run.json', meta)
    try:
        binaries, fixture = build(output, options.skip_swift)
        results = {}
        for name, binary in binaries.items():
            results[name] = normalize(json.loads(run([binary], stdin=fixtures, timeout=30)))
            write_json(output / f'{name}-traces.json', results[name])
            if name == 'swiftterm':
                for trace in json.loads(fixtures):
                    if trace.get('requireImages') and not results[name][trace['name']]['snapshots'][-1]['imageStripes']:
                        raise RuntimeError(f"baseline image fixture produced no image: {trace['name']}")
                if not all(all(trace['checkpointChecks']) for trace in results[name].values()):
                    raise RuntimeError('SwiftTerm baseline checkpoint continuation failed')
            print(name, 'completed', len(results[name]), 'traces', flush=True)
        sessions = {}
        if WINDOWS:
            shells = [('cmd', ['cmd.exe', '/Q', '/D']), ('powershell', ['pwsh.exe', '-NoLogo', '-NoProfile'])]
        else:
            shells = [('posix', ['/bin/sh', '-i'])]
            for shell, flags in [('bash', ['--noprofile', '--norc', '-i']), ('zsh', ['-f', '-i'])]:
                executable = shutil.which(shell)
                if executable:
                    shells.append(('posix', [executable, *flags]))
        failures = []
        for name in ['go', 'rust']:
            sessions[name] = {}
            cases = [('native-geometry', lambda: native_geometry(binaries[name], fixture, output))]
            cases.extend((command[0], lambda c=command, k=kind: shell_session(binaries[name], c, k, output)) for kind, command in shells)
            for label, exercise in cases:
                try:
                    sessions[name][label] = exercise()
                    print(name, label, 'PASS', flush=True)
                except Exception as error:
                    sessions[name][label] = {'status': 'fail', 'error': str(error)}
                    failures.append(f'{name}: {label}')
                    print(name, label, 'FAIL', error, flush=True)
                write_json(output / 'sessions.json', sessions)
        if 'swiftterm' in results:
            comparisons = {}
            for name in ['go', 'rust']:
                comparisons[name] = {}
                for trace, baseline in results['swiftterm'].items():
                    candidate = results[name][trace]
                    mismatches = []
                    for i, (left, right) in enumerate(zip(baseline['snapshots'], candidate['snapshots'])):
                        fields = [key for key in ['cells', 'styles', 'cursor', 'alt'] if left[key] != right[key]]
                        if fields:
                            mismatches.append({'event': i, 'fields': fields})
                    comparisons[name][trace] = {'visibleStateMismatches': mismatches,
                        'finalRepliesMatch': (baseline['finalReplies'] == candidate['finalReplies'] if candidate.get('replyImplementation', True) else (False if baseline['finalReplies'] else None)),
                        'replyImplementation': candidate.get('replyImplementation', True),
                        'checkpointChecks': candidate.get('checkpointChecks'),
                        'baselineCheckpointChecks': baseline['checkpointChecks'],
                        'scope': 'Cells, basic styles/colors, cursor and active buffer only. Matching state does not establish modes, images or keyboard input parity.'}
            write_json(output / 'comparison.json', comparisons)
        meta['status'] = 'fail' if failures else 'pass'
        meta['adapterFailures'] = failures
        meta['fidelityVerdict'] = 'inspection required; trace differences are findings, not harness failures'
    except BaseException as error:
        meta['status'] = 'error'
        meta['error'] = str(error)
        raise
    finally:
        meta['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        write_json(output / 'run.json', meta)
    if failures:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
