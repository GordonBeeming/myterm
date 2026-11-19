// Mocked API safety checks, separate from native CLI compatibility evidence.
import fs from 'node:fs';
import assert from 'node:assert/strict';

let source = fs.readFileSync(new URL('./claude-mod/hooks/register.js', import.meta.url), 'utf8');
source = source.replace('__MYTERM_PYTHON__', '"python"').replace('__MYTERM_OBSERVER__', '"observer"').replace('__MYTERM_CAPTURE__', '"private"');
const { register, prototypeHealth } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
const handlers = {};
register((name, fn) => { handlers[name] = fn; });
let failObserver = false;
const records = [], failures = [];
const api = {
  process: { run: async argv => {
    if (failObserver) return { exitCode: 1, stdout: '', stderr: 'fixture sink failure' };
    records.push(JSON.parse(argv.at(-1)));
    return { exitCode: 0, stdout: '', stderr: '' };
  } },
  ui: { log: text => failures.push(text) },
};
let checks = 0;
function check(name, run) { return Promise.resolve().then(run).then(() => { checks++; process.stdout.write('PASS: ' + name + '\n'); }); }

await check('A child turn cannot replace the main call owner', async () => {
  await handlers['turn.start'](api, { turnId: 'main-turn' }, async () => ({}));
  await handlers['turn.start'](api, { turnId: 'child-turn', agentId: 'child' }, async () => ({}));
  await handlers['tool.call'](api, { tool: 'AskUserQuestion', tool_use_id: 'main-call' }, async () => ({ result: {} }));
  assert.equal(records.findLast(x => x.hook_event_name === 'mod.tool.start').turn_id, 'main-turn');
});
await check('A child completion cannot clear main ownership', async () => {
  await handlers['turn.complete'](api, { turnId: 'child-turn', agentId: 'child', reason: 'answer' }, async () => ({}));
  await handlers['tool.call'](api, { tool: 'Bash', tool_use_id: 'main-call-2' }, async () => ({ result: {} }));
  assert.equal(records.findLast(x => x.hook_event_name === 'mod.tool.start').turn_id, 'main-turn');
});
await check('A sink failure does not re-execute or change a tool result', async () => {
  failObserver = true; let calls = 0; const expected = { result: { value: 'unchanged' } };
  const result = await handlers['tool.call'](api, { tool: 'Bash', tool_use_id: 'fixture' }, async () => { calls++; return expected; });
  assert.equal(calls, 1); assert.equal(result, expected); assert.ok(failures.length);
});
await check('A sink failure cannot weaken a permission denial', async () => {
  const expected = { decision: 'deny', reason: 'fixture policy' }; let calls = 0;
  const result = await handlers['tool.check'](api, { tool: 'Bash', tool_use_id: 'fixture' }, async () => { calls++; return expected; });
  assert.equal(calls, 1); assert.equal(result, expected);
});
await check('A sink failure does not replace the original tool error', async () => {
  const expected = new Error('original fixture failure'); let caught;
  try { await handlers['tool.call'](api, { tool: 'Bash', tool_use_id: 'fixture' }, async () => { throw expected; }); } catch (error) { caught = error; }
  assert.equal(caught, expected);
});
await check('An aborted native turn passes through unchanged', async () => {
  const expected = { text: '' };
  const result = await handlers['turn.complete'](api, { turnId: 'main-turn', reason: 'aborted', isAborted: true }, async () => expected);
  assert.equal(result, expected);
});
await check('A null tool result passes through unchanged', async () => {
  failObserver = false;
  assert.equal(await handlers['tool.call'](api, { tool: 'Bash', tool_use_id: 'null-result' }, async () => null), null);
});
await check('An undefined tool result passes through unchanged', async () => {
  assert.equal(await handlers['tool.call'](api, { tool: 'Bash', tool_use_id: 'undefined-result' }, async () => undefined), undefined);
});
await check('An undefined permission result passes through unchanged', async () => {
  assert.equal(await handlers['tool.check'](api, { tool: 'Bash', tool_use_id: 'undefined-policy' }, async () => undefined), undefined);
});
await check('Failure of both observer sinks preserves a denial', async () => {
  failObserver = true; const expected = { decision: 'deny' };
  const failingDebug = { process: api.process, ui: { log: () => { throw new Error('debug sink unavailable'); } } };
  assert.equal(await handlers['tool.check'](failingDebug, { tool: 'Bash', tool_use_id: 'both-sinks' }, async () => expected), expected);
  assert.ok(prototypeHealth().observerFailures.length >= 2);
});
process.stdout.write(`${checks} mocked API safety checks passed\n`);
