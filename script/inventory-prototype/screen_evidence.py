"""Regenerate the decisive terminal-cell excerpts from retained real captures.

Run with the scratch venv containing pyte. No provider requests are made.
Private terminal bytes stay outside the repository; public excerpts omit status
lines, account identities, prices, paths and native session identifiers.
"""
import hashlib
import json
from datetime import datetime
from pathlib import Path
import re

import pyte

HERE = Path(__file__).resolve().parent
EVIDENCE = HERE / 'evidence' / 'lifecycle'


def markers(raw):
    return [(match.start(), dict(field.split('=', 1) for field in match[1].decode().split(';') if '=' in field))
            for match in re.finditer(rb'\x1b\]7337;([^\x1b\x07]*)(?:\x1b\\|\x07)', raw)]


def generate():
    captures = {row['name']: row for row in json.loads((EVIDENCE / 'native-captures.json').read_text())}
    results = []
    for name, capture_name in [('codex-blocking-question', 'codex-question'), ('claude-cancelled-question', 'claude-question')]:
        capture = captures[capture_name]
        raw = Path(capture['privateRawFile']).read_bytes()
        assert hashlib.sha256(raw).hexdigest() == capture['rawSHA256']
        reports = markers(raw)
        screen = pyte.Screen(160, 48)
        stream = pyte.ByteStream(screen)
        for offset in range(0, len(raw), 16):
            stream.feed(raw[offset:offset + 16])
            rows = screen.display
            if name.startswith('codex'):
                hits = [i for i, row in enumerate(rows) if '1 unanswered' in row]
                region = '\n'.join(rows[hits[0]:]) if hits else ''
                matched = bool(hits) and all(text in region for text in ['Alpha', 'Beta', 'enter to submit answer', 'esc to interrupt'])
                excerpts = [row.strip() for row in rows[hits[0]:] if row.strip()] if matched else []
            else:
                menu_present = any('Enter to select' in row or '1. Alpha' in row for row in rows)
                matched = not menu_present and any('User declined to answer questions' in row for row in rows) and any(row.strip() == '❯' for row in rows)
                excerpts = [row.strip() for row in rows if 'declined' in row or row.strip() == '❯'] if matched else []
            if matched:
                boundary = min(offset + 16, len(raw))
                before = [fields.get('event') for position, fields in reports if position < boundary]
                after = [fields.get('event') for position, fields in reports if position >= boundary]
                results.append({'name': name, 'captureName': capture_name, 'byteOffset': boundary,
                                'terminalColumns': 160, 'terminalRows': 48, 'screenExcerpts': excerpts,
                                'nativeActivities': before, 'lastNativeActivity': before[-1],
                                'followingNativeActivities': after, 'totalCapturedMarkers': len(reports),
                                'rawSHA256': capture['rawSHA256'], 'captureEndIncludedExitMarker': reports[-1][1].get('event') == 'exited',
                                'source': 'Terminal cell reconstruction of captured PTY bytes; not a native GUI screenshot.'})
                break
        else:
            raise AssertionError('Decisive native terminal state not present: ' + name)

        # These boundaries come from this test's own provider transcript. Retain
        # the hashes and UTC times; the review page displays elapsed seconds only.
        sid = reports[0][1]['session']
        if name.startswith('codex'):
            transcript = next((Path.home() / '.codex/sessions/2026/11/15').glob('*' + sid + '*.jsonl'))
            call = started = ended = None
            for line in transcript.read_text().splitlines():
                item = json.loads(line); payload = item.get('payload', {})
                if payload.get('type') == 'function_call' and payload.get('name') == 'request_user_input':
                    call = payload['call_id']; started = item['timestamp']
                if payload.get('type') == 'function_call_output' and call and payload.get('call_id') == call:
                    ended = item['timestamp']; break
        else:
            transcript = next((Path.home() / '.claude/projects').glob('*myterm-native-lifecycle-claude-wmevqkk9/' + sid + '.jsonl'))
            started = ended = None
            for line in transcript.read_text().splitlines():
                item = json.loads(line); content = item.get('message', {}).get('content', [])
                if isinstance(content, list) and item.get('timestamp') and any(part.get('type') == 'tool_result' and part.get('is_error') for part in content):
                    started = item['timestamp']
                if started and isinstance(content, str) and content.startswith('Use Bash'):
                    ended = item['timestamp']; break
        assert started and ended
        results[-1].update({'intervalStartUTC': started, 'intervalEndUTC': ended,
                            'intervalSeconds': (datetime.fromisoformat(ended.replace('Z', '+00:00')) - datetime.fromisoformat(started.replace('Z', '+00:00'))).total_seconds(),
                            'nativeTranscriptSHA256': hashlib.sha256(transcript.read_bytes()).hexdigest()})
    (EVIDENCE / 'screen-evidence.json').write_text(json.dumps(results, indent=2) + '\n')
    print('Reconstructed', len(results), 'decisive native terminal states')


if __name__ == '__main__':
    generate()
