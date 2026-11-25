"""Disposable event adapter. Its input is native hook/mod data, never terminal prose."""
from dataclasses import dataclass, field
import hashlib
import json


def fingerprint(value):
    return hashlib.sha256(value.encode()).hexdigest()


@dataclass
class Candidate:
    agent: str
    session: str = 'prototype-session'
    turn: str | None = None
    activity: str = 'ready'
    calls: dict = field(default_factory=dict)
    waits: set = field(default_factory=set)
    ended: set = field(default_factory=set)
    started: set = field(default_factory=set)
    outputs: list = field(default_factory=list)
    ignored: list = field(default_factory=list)
    notice: str | None = None
    mod_available: bool = False
    closed: bool = False
    retired_sessions: set = field(default_factory=set)
    unsupported_permission: bool = False

    def emit(self, event):
        # Aggregate snapshots leave per-request counting inside this adapter.
        # Production migration must choose one authority rather than double-count
        # these snapshots alongside the old raw reporter.
        usable = self.activity != 'unknown'
        payload = f'agent={self.agent};event={self.activity};session={self.session};snapshot=1' if usable else None
        if self.turn:
            if payload: payload += ';turn=' + fingerprint(self.turn)
        self.outputs.append({'sourceEvent': event, 'payload': payload, 'activity': self.activity,
                             'pending': sorted(self.waits), 'turn': self.turn, 'notice': self.notice,
                             'usable': usable, 'authority': 'candidate' if usable else 'unsupported-route'})

    def reject(self, reason):
        self.ignored.append(reason)

    def active(self, turn):
        if not turn or turn != self.turn or turn in self.ended:
            self.reject('event outside current live native turn')
            return False
        return True

    def settle_activity(self):
        self.activity = 'awaiting_input' if self.waits else 'working'

    def apply(self, event):
        kind = event.get('hook_event_name')
        if event.get('agent_id') or event.get('agentId'):
            self.reject('subagent event excluded from main-loop state'); return
        if kind == 'SessionStart':
            session = event.get('session_id')
            if not isinstance(session, str) or not session:
                self.reject('missing native session identity'); return
            proposed = fingerprint(session)[:32]
            explicit_transition = event.get('source') in ['clear', 'resume', 'fork']
            if proposed in self.retired_sessions and not explicit_transition:
                self.reject('delayed start of an ended native session'); return
            if proposed == self.session and self.turn is not None and not explicit_transition:
                self.reject('session callback cannot downgrade an active or settled turn'); return
            if self.session != 'prototype-session' and proposed != self.session:
                self.retired_sessions.add(self.session)
            if self.turn: self.ended.add(self.turn)
            self.session = proposed; self.closed = False; self.turn = None
            self.calls.clear(); self.waits.clear(); self.notice = None; self.unsupported_permission = False
            self.activity = 'ready'; self.emit(kind); return
        supplied_session = event.get('session_id')
        if supplied_session and fingerprint(supplied_session)[:32] != self.session:
            self.reject('event from a different native session'); return
        if self.closed:
            self.reject('late event after native session end'); return
        if kind == 'SessionEnd':
            if self.turn: self.ended.add(self.turn)
            self.retired_sessions.add(self.session)
            self.closed = True
            self.calls.clear(); self.waits.clear(); self.activity = 'exited'; self.emit(kind); return
        if self.agent == 'codex':
            self.codex(event)
        else:
            self.claude(event)

    def begin(self, turn, kind):
        if not isinstance(turn, str) or not turn or turn in self.ended:
            self.reject('missing or retired native turn identity'); return
        if turn in self.started:
            self.reject('duplicate or delayed native turn start'); return
        self.started.add(turn)
        self.turn = turn; self.calls.clear(); self.waits.clear(); self.notice = None
        self.unsupported_permission = False
        self.activity = 'working'; self.emit(kind)

    def codex(self, event):
        kind = event.get('hook_event_name'); turn = event.get('turn_id')
        if kind == 'UserPromptSubmit':
            self.begin(turn, kind); return
        if kind not in ['PreToolUse', 'PostToolUse', 'PermissionRequest', 'Stop', 'Interrupt']:
            return
        if not self.active(turn): return
        if kind == 'PermissionRequest':
            self.unsupported_permission = True
            self.activity = 'unknown'
            self.notice = 'Bash/command approval route is outside this focused question prototype; retain the existing adapter'
            self.reject(self.notice); self.emit(kind); return
        if self.unsupported_permission and kind not in ['Stop', 'Interrupt']:
            self.reject('command permission state requires the retained existing adapter'); return
        call = event.get('tool_use_id')
        if kind == 'PreToolUse' and call:
            self.calls[call] = event.get('tool_name')
            if event.get('tool_name') == 'request_user_input': self.waits.add(call)
            self.settle_activity(); self.emit(kind)
        elif kind == 'PostToolUse' and call:
            if call not in self.calls:
                self.reject('completion for an unknown or already settled native call'); return
            self.calls.pop(call, None); self.waits.discard(call)
            self.settle_activity(); self.emit(kind)
        elif kind in ['Stop', 'Interrupt']:
            self.calls.clear(); self.waits.clear(); self.ended.add(turn)
            self.activity = 'ready' if kind == 'Interrupt' else 'finished'; self.emit(kind)

    def claude(self, event):
        kind = event.get('hook_event_name'); turn = event.get('turn_id')
        if kind == 'mod.session.start':
            self.mod_available = True; return
        if kind == 'UserPromptSubmit' and not self.mod_available:
            self.activity = 'unknown'
            self.notice = 'native mod is not available; no activity snapshot emitted'
            self.reject(self.notice); return
        # Classic activity callbacks remain comparison data. This candidate uses
        # the mod's native main-loop identities as its single activity authority.
        if kind == 'mod.turn.start':
            self.begin(turn, kind); return
        if kind not in ['mod.turn.step', 'mod.tool.start', 'mod.tool.decision', 'mod.tool.complete', 'mod.tool.rejected', 'mod.turn.complete']:
            return
        if not self.active(turn): return
        call = event.get('tool_use_id')
        if kind == 'mod.turn.step':
            self.settle_activity(); self.emit(kind)
        elif kind == 'mod.tool.start' and call:
            self.calls[call] = event.get('tool_name')
            if event.get('tool_name') == 'AskUserQuestion': self.waits.add(call)
            self.settle_activity(); self.emit(kind)
        elif kind == 'mod.tool.decision' and call and call in self.calls:
            if event.get('decision') == 'ask' and event.get('approver') == 'person': self.waits.add(call)
            self.settle_activity(); self.emit(kind)
        elif kind in ['mod.tool.complete', 'mod.tool.rejected'] and call:
            if call not in self.calls:
                self.reject('completion for an unknown or already settled native call'); return
            self.calls.pop(call, None); self.waits.discard(call)
            self.settle_activity()
            self.emit(kind)
        elif kind == 'mod.turn.complete':
            reason = event.get('reason')
            if reason not in ['answer', 'aborted', 'refusal', 'error']:
                self.reject('native completion reason was not captured'); return
            self.calls.clear(); self.waits.clear(); self.ended.add(turn)
            self.activity = 'finished' if reason == 'answer' else 'ready'
            self.notice = reason if reason in ['refusal', 'error'] else None
            self.emit(kind)

    def state(self):
        return {'agent': self.agent, 'session': self.session, 'turn': self.turn, 'activity': self.activity,
                'pending': sorted(self.waits), 'calls': self.calls, 'endedTurns': sorted(self.ended),
                'outputs': self.outputs, 'ignored': self.ignored, 'notice': self.notice,
                'modAvailable': self.mod_available, 'sessionClosed': self.closed,
                'unsupportedPermissionRoute': self.unsupported_permission,
                'retiredSessions': sorted(self.retired_sessions)}


def replay(agent, records):
    candidate = Candidate(agent)
    for record in records:
        candidate.apply(record['event'])
    return candidate
