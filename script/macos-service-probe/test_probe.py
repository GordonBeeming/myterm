"""Native tests for the throwaway probe, not product acceptance tests."""
import os
from pathlib import Path
import subprocess
import socket
import tempfile
import time
import unittest

BINARY = Path(os.environ['MYTERM_PROBE_BINARY'])


class NativeProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mt168-', dir='/tmp')
        self.root = Path(self.temp.name)
        self.processes = []

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()
        self.temp.cleanup()

    def start(self, name='a'):
        root = self.root / name
        process = subprocess.Popen([str(BINARY), 'serve', str(root), 'com.gordonbeeming.myterm.native-probe168.absent'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(process)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if process.poll() is not None:
                self.fail(process.stderr.read())
            if (root / 'control.sock').exists():
                try:
                    self.request(root, 'status')
                    return process, root
                except subprocess.CalledProcessError:
                    pass
            time.sleep(.02)
        self.fail('probe readiness timed out')

    def request(self, root, command):
        return subprocess.check_output([str(BINARY), 'request', str(root), command], text=True, timeout=5)

    def test_duplicate_owner_refused(self):
        first, root = self.start()
        duplicate = subprocess.run([str(BINARY), 'serve', str(root), 'unused'], capture_output=True, text=True, timeout=5)
        self.assertNotEqual(duplicate.returncode, 0)
        self.assertIn('already owned', duplicate.stderr)
        self.assertIn(f'pid={first.pid}', self.request(root, 'status'))

    def test_identity_survives_restart(self):
        process, root = self.start()
        identity = (root / 'instance-id').read_text()
        process.terminate()
        process.wait(timeout=5)
        replacement, _ = self.start()
        self.assertNotEqual(process.pid, replacement.pid)
        self.assertEqual(identity, (root / 'instance-id').read_text())

    def test_separate_instances_and_client_independence(self):
        first, a = self.start('a')
        second, b = self.start('b')
        for _ in range(3):
            self.assertIn(f'pid={first.pid}', self.request(a, 'status'))
        first.terminate()
        first.wait(timeout=5)
        self.assertIn(f'pid={second.pid}', self.request(b, 'status'))
        self.assertNotEqual((a / 'instance-id').read_text(), (b / 'instance-id').read_text())

    def test_missing_key_is_noninteractive_and_retains_identity(self):
        _, root = self.start()
        identity = (root / 'instance-id').read_text()
        response = self.request(root, 'key')
        self.assertIn('OSStatus=-25300', response)
        self.assertIn('needs attention', response)
        self.assertEqual(identity, (root / 'instance-id').read_text())

    def test_invalid_request_does_not_crash_service(self):
        process, root = self.start()
        with socket.socket(socket.AF_UNIX) as stream:
            stream.connect(str(root / 'control.sock'))
            stream.sendall(b'\xff')
        self.assertIn(f'pid={process.pid}', self.request(root, 'status'))

    def test_request_bytes_can_arrive_after_accept(self):
        process, root = self.start()
        with socket.socket(socket.AF_UNIX) as stream:
            stream.settimeout(3)
            stream.connect(str(root / 'control.sock'))
            time.sleep(.2)
            stream.sendall(b'status')
            stream.shutdown(socket.SHUT_WR)
            self.assertIn(f'pid={process.pid}', stream.recv(1024).decode())

    def test_private_state_and_socket(self):
        _, root = self.start()
        self.assertEqual(root.stat().st_mode & 0o777, 0o700)
        self.assertEqual((root / 'control.sock').stat().st_mode & 0o777, 0o600)
        self.assertEqual((root / 'instance-id').stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main(verbosity=2)
