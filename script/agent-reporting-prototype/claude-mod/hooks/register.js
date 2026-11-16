// Disposable native observer. All decisions and tool results pass through unchanged.
const python = __MYTERM_PYTHON__;
const observer = __MYTERM_OBSERVER__;
const capture = __MYTERM_CAPTURE__;
let activeTurn;
const observerFailures = [];

function noteFailure($, message) {
  observerFailures.push(message);
  try {
    $.ui.log('[DEBUG-myterm-agent-reporting] observer failed; this capture is invalid', { to: 'debug' });
  } catch (error) {
    // Retain the diagnostic without letting a second observer API failure alter
    // the original tool result or permission decision. Recovery reports the count.
    observerFailures.push('debug sink failed: ' + String(error));
  }
}

export function prototypeHealth() { return { observerFailures: observerFailures.slice() }; }

async function record($, name, event, extra = {}) {
  const metadata = {
    hook_event_name: name,
    keys: Object.keys(event),
    turn_id: event.turnId,
    agent_id: event.agentId,
    session_id: event.sessionId,
    tool_name: event.tool,
    tool_use_id: event.tool_use_id,
    tool_call_id: event.toolCallId,
    id: event.id,
    is_aborted: event.isAborted,
    reason: event.reason,
    observer_error_count: observerFailures.length,
    ...extra,
  };
  try {
    const result = await $.process.run([python, observer, 'claude', capture, '--record', JSON.stringify(metadata)], { timeoutMs: 1000 });
    if (result.exitCode !== 0) {
      noteFailure($, 'observer process failed');
    }
  } catch (error) {
    noteFailure($, String(error));
  }
}

export function register(on) {
  on('session.start', async ($, event, next) => {
    await record($, 'mod.session.start', event);
    return next(event);
  });
  on('turn.start', async ($, event, next) => {
    if (!event.agentId) activeTurn = event.turnId;
    await record($, 'mod.turn.start', event);
    return next(event);
  });
  on('turn.complete', async ($, event, next) => {
    await record($, 'mod.turn.complete', event);
    if (!event.agentId && activeTurn === event.turnId) activeTurn = undefined;
    return next(event);
  });
  on('turn.step', async function* ($, event, next) {
    await record($, 'mod.turn.step', event);
    return yield* next(event);
  });
  on('tool.check', async ($, event, next) => {
    const ownerTurn = event.turnId ?? (event.agentId ? undefined : activeTurn);
    const result = await next(event);
    await record($, 'mod.tool.decision', event, { turn_id: ownerTurn, decision: result?.decision, approver: event.approver });
    return result;
  });
  on('tool.call', async ($, event, next) => {
    const ownerTurn = event.turnId ?? (event.agentId ? undefined : activeTurn);
    await record($, 'mod.tool.start', event, { turn_id: ownerTurn });
    try {
      const result = await next(event);
      await record($, 'mod.tool.complete', event, {
        result_keys: Object.keys(result ?? {}),
        is_error: result?.isError === true,
        denied: typeof result?.deny === 'string',
        turn_id: ownerTurn,
      });
      return result;
    } catch (error) {
      await record($, 'mod.tool.rejected', event, { turn_id: ownerTurn });
      throw error;
    }
  });
}
