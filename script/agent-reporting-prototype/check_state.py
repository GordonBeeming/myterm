"""Protocol fixtures for edge conditions; not additional native CLI runs."""
from candidate import Candidate

checks = 0


def check(name, test):
    global checks
    test()
    checks += 1
    print('PASS:', name)


def assert_state(candidate, expected, pending=None):
    assert candidate.activity == expected, candidate.state()
    if pending is not None: assert len(candidate.waits) == pending, candidate.state()


def code_wait():
    c = Candidate('codex')
    c.apply({'hook_event_name': 'SessionStart', 'session_id': 'session-a', 'source': 'startup'})
    c.apply({'hook_event_name': 'UserPromptSubmit', 'session_id': 'session-a', 'turn_id': 'turn-a'})
    c.apply({'hook_event_name': 'PreToolUse', 'session_id': 'session-a', 'turn_id': 'turn-a', 'tool_name': 'request_user_input', 'tool_use_id': 'call-a'})
    return c


def stale_session_end():
    c = code_wait(); c.apply({'hook_event_name': 'SessionEnd', 'session_id': 'other-session'})
    assert_state(c, 'awaiting_input', 1)


def clear_then_late_end():
    c = code_wait(); c.apply({'hook_event_name': 'SessionEnd', 'session_id': 'session-a'})
    c.apply({'hook_event_name': 'SessionStart', 'session_id': 'session-b', 'source': 'clear'})
    c.apply({'hook_event_name': 'UserPromptSubmit', 'session_id': 'session-b', 'turn_id': 'turn-b'})
    c.apply({'hook_event_name': 'SessionEnd', 'session_id': 'session-a'})
    assert_state(c, 'working', 0)


def compact_preserves_wait():
    c = code_wait(); c.apply({'hook_event_name': 'SessionStart', 'session_id': 'session-a', 'source': 'compact'})
    assert_state(c, 'awaiting_input', 1)


def closed_rejects_old_start():
    c = code_wait(); c.apply({'hook_event_name': 'SessionEnd', 'session_id': 'session-a'})
    c.apply({'hook_event_name': 'SessionStart', 'session_id': 'session-a', 'source': 'startup'})
    assert_state(c, 'exited', 0)


def explicit_resume():
    c = code_wait(); c.apply({'hook_event_name': 'SessionEnd', 'session_id': 'session-a'})
    c.apply({'hook_event_name': 'SessionStart', 'session_id': 'session-a', 'source': 'resume'})
    assert_state(c, 'ready', 0)


def permission_invalidates_stream():
    c = code_wait(); c.apply({'hook_event_name': 'PermissionRequest', 'session_id': 'session-a', 'turn_id': 'turn-a', 'tool_name': 'Bash'})
    assert_state(c, 'unknown')
    assert c.outputs[-1]['usable'] is False and c.outputs[-1]['payload'] is None


def old_permission_cannot_poison_new_turn():
    c = code_wait(); c.apply({'hook_event_name': 'Stop', 'session_id': 'session-a', 'turn_id': 'turn-a'})
    c.apply({'hook_event_name': 'UserPromptSubmit', 'session_id': 'session-a', 'turn_id': 'turn-b'})
    c.apply({'hook_event_name': 'PermissionRequest', 'session_id': 'session-a', 'turn_id': 'turn-a', 'tool_name': 'Bash'})
    assert_state(c, 'working')


def tool_error_does_not_end_turn():
    c = Candidate('claude')
    c.apply({'hook_event_name': 'mod.session.start'})
    c.apply({'hook_event_name': 'mod.turn.start', 'turn_id': 'turn-a'})
    c.apply({'hook_event_name': 'mod.tool.start', 'turn_id': 'turn-a', 'tool_name': 'Bash', 'tool_use_id': 'call-a'})
    c.apply({'hook_event_name': 'mod.tool.complete', 'turn_id': 'turn-a', 'tool_use_id': 'call-a', 'is_error': True})
    assert_state(c, 'working', 0)


for name, function in [
    ('Old session end cannot close current wait', stale_session_end),
    ('New conversation can start after old end', clear_then_late_end),
    ('Compaction cannot downgrade a wait', compact_preserves_wait),
    ('Delayed startup cannot resurrect ended conversation', closed_rejects_old_start),
    ('Explicit native resume can reopen a conversation', explicit_resume),
    ('Unsupported command route explicitly invalidates snapshot authority', permission_invalidates_stream),
    ('Old permission event cannot invalidate new turn', old_permission_cannot_poison_new_turn),
    ('Tool error does not pretend the turn has ended', tool_error_does_not_end_turn),
]: check(name, function)

print(checks, 'protocol-fixture checks passed')
