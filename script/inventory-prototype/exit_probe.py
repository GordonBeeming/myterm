"""Check real macOS foreground-group return after an owned CLI is killed."""
import argparse
import json
import os
import re
from pathlib import Path
import shlex
import signal
import subprocess
import tempfile

from lifecycle_probe import Session


def run(agent):
    command = {
        'claude': ['claude', '--permission-mode', 'manual', '--tools', '', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}'],
        'codex': ['codex', '--no-alt-screen', '--sandbox', 'read-only', '--ask-for-approval', 'on-request'],
        'antigravity': ['agy', '--mode', 'plan'],
        'grok': ['grok', '--permission-mode', 'default', '--no-subagents', '--disable-web-search'],
    }[agent]
    work = tempfile.mkdtemp(prefix=f'myterm-foreground-{agent}-')
    session = Session(agent, ['/bin/zsh', '-f', '-i'], work)
    foreground = None
    result = {'agent': agent, 'version': subprocess.check_output([command[0], '--version'], text=True).strip(),
              'scope': 'Actual CLI foreground process group and live zsh return. No MyTerm UI assertion or native agent marker is fabricated.'}
    try:
        session.wait(lambda s: len(s.data) > 0, 10)
        shell_group = os.tcgetpgrp(session.fd)
        session.send(shlex.join(command) + '\r')
        found = session.wait(lambda s: os.tcgetpgrp(s.fd) != shell_group, 15)
        if not found:
            raise RuntimeError('CLI did not become the PTY foreground job')
        foreground = os.tcgetpgrp(session.fd)
        expected = {'claude': {'claude'}, 'codex': {'codex', 'codex-statusline'}, 'antigravity': {'agy'}, 'grok': {'grok', 'grok-macos-aarch64', 'grok-macos-aarch', 'grok-macos-x86_64'}}[agent]
        members = []
        def native_member(_):
            nonlocal foreground, members
            foreground = os.tcgetpgrp(session.fd)
            rows = subprocess.check_output(['ps', '-ax', '-o', 'pgid=', '-o', 'comm='], text=True).splitlines()
            members = [Path(parts[1]).name for row in rows if len(parts := row.strip().split(maxsplit=1)) == 2 and parts[0] == str(foreground)]
            return foreground != shell_group and bool(expected.intersection(members))
        # Node launchers can lead the foreground group before the native child execs.
        native_started = session.wait(native_member, 20)
        result.update({'shellGroup': shell_group, 'agentGroup': foreground, 'foregroundExecutables': members})
        if not native_started:
            raise RuntimeError('Foreground group was not the expected native CLI')
        def input_screen_visible(s):
            text = re.sub(r'\s+', '', s.text().lower())
            return any(x in text for x in ['trustthis', 'trustthecontents', 'askcodextodoanything', 'buildanything'])
        ready = session.wait(input_screen_visible, 30)
        result['inputScreenObserved'] = ready
        if not ready:
            raise RuntimeError('Native input/trust screen was not observed before kill')
        # This is the exact child job just started by this disposable shell.
        killed_group = foreground
        # A query queued by the dying CLI must not inject its reply into the shell.
        session.terminal_replies_enabled = False
        os.killpg(foreground, signal.SIGKILL)
        foreground = None
        def killed_group_empty():
            try:
                os.killpg(killed_group, 0)
                return False
            except ProcessLookupError:
                return True
        returned = session.wait(lambda s: os.tcgetpgrp(s.fd) == shell_group and killed_group_empty(), 15)
        output_offset = len(session.data)
        # The typed command contains neither the expanded suffix nor the PID result.
        session.send("printf 'LIFECYCLE_RESULT_%s_PID_%s' $((40+2)) $$\r")
        expected_output = f'LIFECYCLE_RESULT_42_PID_{session.pid}'.encode()
        alive = session.wait(lambda s: expected_output in s.data[output_offset:], 10)
        result.update({'returnedToSameShell': returned, 'shellProducedPostKillOutput': alive,
                       'expectedShellPID': session.pid, 'outputMatchedAfterByteOffset': output_offset,
                       'killedForegroundGroupEmpty': killed_group_empty(),
                       'result': 'pass' if returned and alive else 'fail'})
    except Exception as error:
        result.update({'result': 'fail', 'error': str(error)})
    finally:
        if foreground is not None:
            try:
                os.killpg(foreground, signal.SIGKILL)
            except ProcessLookupError:
                pass
        session.stop()
        result['cleanup'] = session.cleanup
    destination = Path(__file__).resolve().parent / 'evidence' / 'lifecycle'
    destination.mkdir(parents=True, exist_ok=True)
    (destination / f'{agent}-forced-exit.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('agent', choices=['claude', 'codex', 'antigravity', 'grok'])
    run(parser.parse_args().agent)
