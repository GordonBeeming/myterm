"""Native interactive CLI diagnostics; never substitutes fabricated agent events.

Uses installed, trusted MyTerm hooks unchanged. Raw terminal diagnostics stay in
a private temporary directory; retained evidence contains normalized markers.
"""
import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[2]
OSC = re.compile(rb'\x1b\]7337;([^\x1b\x07]*)(?:\x1b\\|\x07)')
QUESTION = ('Use your built-in question tool to ask exactly one question: '
            'For the MyTerm lifecycle test, choose Alpha or Beta. Offer Alpha and Beta. '
            'Wait for my answer. After the answer reply exactly LIFECYCLE_COMPLETE. '
            'Do not call any other tool, read files, create files, or delegate.')
PERMISSION = ('Use your shell tool to execute exactly printf LIFECYCLE_PERMISSION_OK once. '
              'Wait for any native permission decision. If I reject or cancel, do not retry. '
              'Do not ask a question with another tool or read or write files.')
PARALLEL = ('In this scratch directory, make exactly two parallel Bash tool calls, not one combined command: '
            'printf ALPHA > myterm-permission-a.txt and printf BETA > myterm-permission-b.txt. '
            'Wait for each separate native permission decision. Do not create other files or retry a denial.')
WRITE_PERMISSION = ('In this scratch directory, create only myterm-permission-proof.txt containing APPROVED using the shell command '
                    'printf APPROVED > myterm-permission-proof.txt. Keep the current read-only policy and request native command approval if required. '
                    'Do not change global permissions, read files, use other tools, or retry if I deny approval.')


class Session:
    def __init__(self, agent, command, work):
        self.agent = agent
        self.data = bytearray()
        self.status = None
        self.terminal_replies_enabled = True
        self.started = time.monotonic()
        self.work = Path(work)
        self.log = self.work / 'terminal.bin'
        self.log.touch(mode=0o600)
        self.actions = []
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 48, 160, 0, 0))
            os.chdir(work)
            env = dict(os.environ, TERM='xterm-256color', MYTERM_PANE_ID='disposable-lifecycle-test', MYTERM_RESOURCE_DIR=str(ROOT / 'Resources'))
            os.execvpe(command[0], command, env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', 48, 160, 0, 0))

    def send(self, data):
        os.write(self.fd, data.encode() if isinstance(data, str) else data)

    def read(self, duration=1):
        readable, _, _ = select.select([self.fd], [], [], duration)
        if readable:
            try:
                chunk = os.read(self.fd, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                chunk = b''
            if chunk:
                self.data.extend(chunk)
                with self.log.open('ab') as out:
                    out.write(chunk)
                if self.terminal_replies_enabled and b'\x1b[6n' in chunk:
                    self.send(b'\x1b[1;1R')
                if self.terminal_replies_enabled and b'\x1b[c' in chunk:
                    self.send(b'\x1b[?1;2c')
                if self.terminal_replies_enabled and b'\x1b]11;?' in chunk:
                    self.send(b'\x1b]11;rgb:ffff/ffff/ffff\x1b\\')
                if len(self.data) > 8 * 1024 * 1024:
                    raise RuntimeError('Diagnostic output bound exceeded')
        if self.status is None:
            waited, status = os.waitpid(self.pid, os.WNOHANG)
            if waited:
                self.status = os.waitstatus_to_exitcode(status)

    def markers(self):
        result = []
        for match in OSC.finditer(self.data):
            fields = dict(field.split('=', 1) for field in match[1].decode(errors='replace').split(';') if '=' in field)
            if fields.get('agent') != self.agent:
                raise RuntimeError('Unexpected reporter identity in owned PTY capture')
            result.append({
                'byteOffset': match.start(),
                'agent': fields.get('agent'), 'activity': fields.get('event'),
                'sessionHash': hashlib.sha256(fields.get('session', '').encode()).hexdigest()[:16] if fields.get('session') else None,
                'turn': fields.get('turn'), 'request': fields.get('tool'), 'call': fields.get('call'),
                'captured': fields.get('captured'), 'snapshot': fields.get('snapshot'),
            })
        return result

    def text(self):
        value = OSC.sub(b'', self.data).decode(errors='replace')
        value = re.sub(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', '', value)
        return re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', value).replace('\r', '\n')

    def wait(self, predicate, timeout=120):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.read()
            if predicate(self):
                return True
            if self.status is not None:
                return False
        return False

    def stop(self):
        def group_exists():
            try:
                os.killpg(self.pid, 0)
                return True
            except ProcessLookupError:
                return False
        if group_exists():
            try:
                os.killpg(self.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            if not self.wait(lambda s: s.status is not None and not group_exists(), timeout=3):
                try:
                    os.killpg(self.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                if self.status is None:
                    _, status = os.waitpid(self.pid, 0)
                    self.status = os.waitstatus_to_exitcode(status)
                self.wait(lambda _: not group_exists(), timeout=3)
        elif self.status is None:
            _, status = os.waitpid(self.pid, 0)
            self.status = os.waitstatus_to_exitcode(status)
        self.cleanup = {'leaderReaped': self.status is not None, 'ownedForegroundGroupEmpty': not group_exists(),
                        'scope': 'Owned foreground group only; separate/shared provider daemons are outside this check.'}
        os.close(self.fd)

    def record(self, label, version):
        self.actions.append({'label': label, 'observedAfterSeconds': round(time.monotonic() - self.started, 3), 'bytes': len(self.data), 'markerCount': len(self.markers()), 'processExitCode': self.status})
        evidence = {'agent': self.agent, 'version': version, 'pid': self.pid, 'actions': self.actions,
                    'markers': self.markers(), 'processExitCode': self.status,
                    'rawOutputSHA256': hashlib.sha256(self.data).hexdigest(),
                    'signInWarningObserved': 'sign-in is missing permissions' in self.text().lower()}
        evidence['proofFiles'] = {}
        for name in ['myterm-permission-proof.txt', 'myterm-permission-a.txt', 'myterm-permission-b.txt']:
            path = self.work / name
            if path.is_file():
                data = path.read_bytes()
                evidence['proofFiles'][name] = {'exists': True, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
            else:
                evidence['proofFiles'][name] = {'exists': False}
        if hasattr(self, 'cleanup'):
            evidence['cleanup'] = self.cleanup
        (self.work / 'observations.json').write_text(json.dumps(evidence, indent=2) + '\n')
        return evidence


def commands(agent, case='question'):
    prompt = {'question': QUESTION, 'permission': PERMISSION, 'parallel': PARALLEL, 'write': WRITE_PERMISSION}[case]
    return {
        'claude': ['claude', '--permission-mode', 'manual', '--settings', '{"permissions":{"ask":["Bash"]}}', '--tools', 'AskUserQuestion,Bash', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', '--', prompt],
        'grok': ['grok', '--permission-mode', 'default', '--no-subagents', '--disable-web-search', prompt],
        'antigravity': ['agy', '--mode', 'plan', '-i', prompt],
        'codex': ['codex', '--no-alt-screen', '--sandbox', 'read-only', '--ask-for-approval', 'on-request', prompt],
    }[agent]


def inspect(agent, work=None, case='question'):
    work = work or tempfile.mkdtemp(prefix=f'myterm-native-lifecycle-{agent}-')
    version = subprocess.check_output([commands(agent, case)[0], '--version'], text=True).strip()
    session = Session(agent, commands(agent, case), work)
    try:
        # Pause at the first genuine question signal or a startup gate so the driver
        # can decide its next action from observed output rather than guessing keys.
        session.wait(lambda s: any(x['activity'] == 'awaiting_input' for x in s.markers()) or any(
            gate in re.sub(r'\s+', '', s.text().lower()) for gate in ['trustthis', 'trustthefiles', 'trustthecontents', 'yes,itrust', 'selectatheme', 'allowaccess']), timeout=60)
        session.record('Startup observed', version)
        print(json.dumps({'agent': agent, 'version': version, 'pid': session.pid, 'privateDiagnostics': work,
                          'status': session.status, 'markers': session.markers()}, indent=2), flush=True)
        # Keep the controlling Python process alive for subsequent observed actions.
        while True:
            readable, _, _ = select.select([sys.stdin] + ([session.fd] if session.status is None else []), [], [], 1)
            if session.fd in readable:
                session.read(0)
            if session.status is not None:
                session.record('Native CLI exited', version)
                print(json.dumps({'status': session.status, 'events': [x['activity'] for x in session.markers()], 'privateDiagnostics': work}), flush=True)
                break
            if sys.stdin not in readable:
                continue
            try:
                request = json.loads(input())
            except EOFError:
                break
            if request.get('stop'):
                break
            if request.get('kill'):
                os.killpg(session.pid, signal.SIGKILL)
            if 'send' in request:
                while select.select([session.fd], [], [], 0)[0] and session.status is None:
                    session.read(0)
                if session.status is not None:
                    session.record('CLI exited before requested input was sent', version)
                    break
                session.send(request['send'])
            count = len(session.markers())
            send_offset = len(session.data)
            target = request.get('waitActivity')
            if target:
                satisfied = session.wait(lambda s: any(x['activity'] == target and x['byteOffset'] >= send_offset for x in s.markers()[count:]), request.get('timeout', 60))
            else:
                satisfied = session.wait(lambda s: len(s.data) > request.get('afterBytes', len(s.data)), request.get('timeout', 2))
            session.actions.append({'target': target, 'satisfied': satisfied, 'timeoutSeconds': request.get('timeout', 60 if target else 2),
                                    'startByteOffset': send_offset, 'markersBefore': count, 'markersAfter': len(session.markers()),
                                    'sentKeysSHA256': hashlib.sha256(request.get('send', '').encode()).hexdigest()})
            evidence = session.record(request.get('label', 'Observed driver action'), version)
            output = {'status': session.status, 'events': [x['activity'] for x in evidence['markers']], 'privateDiagnostics': work}
            if request.get('includeTail'):
                output['tail'] = session.text()[-1600:]
            print(json.dumps(output, indent=2), flush=True)
    finally:
        session.stop()
        session.record('Driver closed; see explicit cleanup checks', version)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('agent', choices=['claude', 'codex', 'grok', 'antigravity'])
    parser.add_argument('--work')
    parser.add_argument('--case', choices=['question', 'permission', 'parallel', 'write'], default='question')
    args = parser.parse_args()
    inspect(args.agent, args.work, args.case)
