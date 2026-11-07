#!/usr/bin/env python3
"""Regression checks for the probe's evidence boundaries and captured data."""
import io
import json
from pathlib import Path
import tempfile
import shlex
import subprocess
import unittest
from unittest.mock import Mock, patch

import report
import run as probe


class ProbeEvidenceTests(unittest.TestCase):
    def test_maximum_retained_rust_byte_array_survives_json_transport(self):
        response = {'data': [255] * probe.MAX_RAW_OUTPUT, 'pid': 42, 'error': '',
                    'readerStatus': '', 'outputLengthAtAccept': probe.MAX_RAW_OUTPUT}
        encoded = json.dumps(response, separators=(',', ':')).encode() + b'\n'
        self.assertGreater(len(encoded), 2 * 1024 * 1024)
        decoded = probe.read_response(io.BytesIO(encoded))
        self.assertEqual(bytes(decoded['data']), b'\xff' * probe.MAX_RAW_OUTPUT)
        self.assertEqual(decoded['pid'], 42)

    def test_oversized_and_incomplete_json_responses_are_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'encoded output bound'):
            probe.read_response(io.BytesIO(b' ' * (probe.MAX_RESPONSE_BYTES + 1)))
        with self.assertRaisesRegex(RuntimeError, 'incomplete'):
            probe.read_response(io.BytesIO(b'{"data":[]}'))

    def test_marker_drained_during_reconnect_cannot_pass_on_a_retry(self):
        session = probe.Session.__new__(probe.Session)
        session.request = Mock(side_effect=[
            {'data': b'MARKER', 'outputLengthAtAccept': 0},
            {'data': b'MARKER', 'outputLengthAtAccept': 6},
        ])
        with self.assertRaisesRegex(RuntimeError, 'before the first reconnect'):
            session.wait_for(b'MARKER', require_retained=True)
        self.assertEqual(session.request.call_count, 1)

    def test_marker_absent_at_first_reconnect_fails_without_polling(self):
        session = probe.Session.__new__(probe.Session)
        session.request = Mock(return_value={'data': b'pending', 'outputLengthAtAccept': 7})
        with self.assertRaisesRegex(RuntimeError, 'before the first reconnect'):
            session.wait_for(b'MARKER', require_retained=True)
        self.assertEqual(session.request.call_count, 1)

    def test_marker_retained_before_first_reconnect_is_accepted(self):
        session = probe.Session.__new__(probe.Session)
        session.request = Mock(return_value={'data': b'prefixMARKERlater', 'outputLengthAtAccept': 12})
        self.assertEqual(session.wait_for(b'MARKER', require_retained=True), b'prefixMARKERlater')
        self.assertEqual(session.request.call_count, 1)

    @unittest.skipIf(probe.WINDOWS, 'POSIX shell startup isolation')
    def test_shell_startup_environment_is_isolated(self):
        with tempfile.TemporaryDirectory(prefix='myterm-shell-profile-') as directory:
            marker = Path(directory) / 'startup-ran'
            startup = Path(directory) / 'startup.sh'
            startup.write_text('printf startup > ' + shlex.quote(str(marker)) + '\n', encoding='utf-8')
            with patch.dict(probe.os.environ, {'ENV': str(startup)}):
                command = ['/bin/sh', '-i', '-c', 'printf ready']
                control = subprocess.run(command, env=dict(probe.os.environ), capture_output=True, timeout=5)
                self.assertEqual(control.returncode, 0)
                self.assertTrue(marker.exists(), 'control must demonstrate inherited startup execution')
                marker.unlink()
                isolated = subprocess.run(command, env=probe.probe_environment('capability'), capture_output=True, timeout=5)
                self.assertEqual(isolated.stdout, b'ready')
                self.assertEqual(isolated.returncode, 0)
                self.assertFalse(marker.exists(), 'probe must not execute inherited shell startup')

    def test_unicode_result_files_are_decoded_as_utf8(self):
        captured = {'cells': ['界', '😀', 'e\u0301']}
        with tempfile.TemporaryDirectory(prefix='myterm-utf8-evidence-') as directory:
            path = Path(directory) / 'results.json'
            path.write_bytes(json.dumps(captured, ensure_ascii=False).encode('utf-8'))
            self.assertEqual(report.read_json(path), captured)


if __name__ == '__main__':
    unittest.main()
