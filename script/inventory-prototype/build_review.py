"""Build a standalone review of recorded Swift model outputs and native captures."""
import base64
from datetime import datetime
import html
import json
from pathlib import Path
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
EVIDENCE = HERE / 'evidence'
OUTPUT = Path('/Users/gordonbeeming/Developer/artifacts/myterm/inventory-activity-prototype.html')


def encoded_image(name):
    return 'data:image/png;base64,' + base64.b64encode((EVIDENCE / name).read_bytes()).decode()


def build():
    checks = json.loads((EVIDENCE / 'verification.json').read_text())
    agents = json.loads((EVIDENCE / 'native-signals.json').read_text())
    steps = json.loads((EVIDENCE / 'native-ui.json').read_text())
    scenarios = (EVIDENCE / 'walkthroughs.json').read_text().replace('</', '<\\/')
    agent_rows = ''.join(
        '<tr><td>' + html.escape(row['agent']) + '</td><td>' + html.escape(row.get('version', 'Unavailable')) + '</td><td>' +
        html.escape(', '.join(dict.fromkeys(event['event'] for event in row.get('oscReports', [])))) + '</td></tr>'
        for row in agents)
    checked_at = datetime.now(ZoneInfo('Australia/Brisbane')).strftime('%d %B %Y, %H:%M AEST')
    report = '''<!doctype html>
<meta charset="utf-8">
<meta name="color-scheme" content="light">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>MyTerm inventory and agent activity</title>
<style>
:root{--bg:#f8fafc;--surface:#fff;--surface-2:#f1f5f9;--text:#0f172a;--muted:#475569;--border:#e2e8f0;--accent:#0e7490;--accent-hover:#155e75;--soft:#ecfeff;--code:#1e293b;--font: 'Space Grotesk',ui-sans-serif,system-ui,-apple-system,sans-serif}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.55 var(--font)}main{max-width:1440px;margin:auto;padding:40px 32px 64px}header{max-width:980px;margin-bottom:28px}h1{font-size:clamp(30px,4vw,48px);line-height:1.1;letter-spacing:-1.5px;margin:12px 0 20px}h2{font-size:26px;line-height:1.25;margin-top:0}h3{font-size:18px;margin:0 0 6px}p{margin:10px 0 16px}.eyebrow{color:var(--accent);font-weight:700;letter-spacing:.07em;font-size:13px;text-transform:uppercase}.muted{color:var(--muted)}a{color:var(--accent-hover)}button,input{font:inherit}button{cursor:pointer;border:1px solid var(--border);background:var(--surface);color:var(--text);border-radius:9px;padding:9px 13px}button:hover{background:var(--surface-2)}button:focus-visible,a:focus-visible{outline:3px solid var(--accent);outline-offset:3px}button.primary,button[aria-selected=true]{background:var(--accent);border-color:var(--accent);color:#fff}button:disabled{cursor:default;opacity:.65}.pill{display:inline-block;background:var(--soft);color:#155e75;border-radius:6px;padding:3px 9px;font-size:13px;font-weight:600}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,260px),1fr));gap:18px}.card,section{background:var(--surface);border:1px solid var(--border);border-radius:16px;padding:24px;min-width:0}section{margin:22px 0}.stat{font-size:32px;font-weight:700;letter-spacing:-1px}.tabs{display:flex;flex-wrap:wrap;gap:8px;margin:18px 0}.toolbar{display:flex;gap:12px;align-items:center;flex-wrap:wrap;margin:15px 0}.toolbar #stepLabel{margin-left:auto}.inventory{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,300px),1fr));gap:12px}.item{border:1px solid var(--border);border-radius:12px;padding:18px;background:var(--bg);min-width:0}.item.attention{border-color:var(--accent);background:var(--soft)}.item p{margin:5px 0}.small{font-size:13px}code{font:13px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;overflow-wrap:anywhere;color:var(--code)}.state{background:var(--surface-2);border-radius:10px;padding:14px;margin-top:14px}.empty{padding:30px;color:var(--muted)}.flow{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,260px),1fr));gap:14px}.flow>div{border-left:3px solid var(--accent);padding:12px 16px;background:var(--surface-2);border-radius:5px}.flow b{display:block}.table-wrap{overflow-x:auto}table{width:100%;border-collapse:collapse;text-align:left}th,td{border-bottom:1px solid var(--border);padding:12px;vertical-align:top;overflow-wrap:anywhere}th{background:var(--surface-2);font-weight:600}.screens img{display:block;width:100%;height:auto;border:1px solid var(--border);border-radius:8px}.screens figcaption{padding:10px 0;color:var(--muted)}figure{margin:0;min-width:0}summary{cursor:pointer;color:var(--accent-hover);font-weight:600}li{margin:8px 0}.ide{border-bottom:1px dotted;text-decoration:none}footer{font-size:13px;color:var(--muted);margin-top:24px}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:var(--surface-2);padding:15px;border-radius:8px}#scenarioDetail{max-width:920px}#allState{font-size:12px;max-height:500px;overflow:auto}@media(max-width:600px){main{padding:24px 14px}section,.card{padding:18px}td,th{padding:8px}.toolbar #stepLabel{margin-left:0;width:100%}}
</style>
<main>
<header><div class="eyebrow">MyTerm · decision prototype</div><h1>Inventory, activity and attention</h1>
<p>Reading a result acknowledges the exact completed turn. A newer result keeps its attention, and a question stays visible until the agent resumes or exits.</p>
<p class="muted">Native Mac prototype with recorded model walkthroughs below. Server connections, account layout and synchronized peers are fixtures. The separate agent probes used real installed CLIs.</p>
<a href="https://github.com/GordonBeeming/myterm/issues/165">Validate cross-server inventory and agent activity synchronization</a><p class="small muted">CHECKED_AT · Ticket remains open.</p></header>
<div class="grid">
<div class="card"><div class="stat">CHECK_COUNT</div><h3>Native model checks</h3><p class="muted">Ordering, lifecycle, exact reads, CryptoKit authentication and recovery in a fresh process.</p></div>
<div class="card"><div class="stat">UI_COUNT</div><h3>Mac walkthrough steps</h3><p class="muted">AppleScript drove the disposable SwiftUI window and checked visible state. Your workspaces were untouched.</p></div>
<div class="card"><div class="stat">4 / 4</div><h3>Real CLI smoke probes</h3><p class="muted">One no-tool turn per agent on macOS ARM64. Interactive permissions remain unverified.</p></div>
</div>
<section><h2>Explore the recorded state</h2><p class="muted">Each step displays output exported by the same Swift model used in the Mac app. This page replays those records; it does not connect to agents, clients or a relay.</p>
<div id="tabs" class="tabs" role="tablist" aria-label="Scenarios"></div><h3 id="scenarioName"></h3><p id="scenarioDetail"></p>
<div class="toolbar"><button id="reset">Reset</button><button class="primary" id="next">Next recorded step</button><span id="stepLabel" class="muted"></span></div>
<p id="action" aria-live="polite"></p><div id="inventory" class="inventory"></div><div id="local" class="state"></div>
<details><summary>Full model state</summary><pre id="allState"></pre></details></section>
<section><h2>Keep three identities separate</h2><div class="flow">
<div><b>Terminal runtime</b>Assigned server + content ID + runtime incarnation. Agent exit keeps the shell. Confirmed runtime loss stays ended.</div>
<div><b>Agent report</b>Agent incarnation + server report number + turn/request correlation. Reordered deltas wait for a missing report.</div>
<div><b>Read receipt</b>Exact content + runtime + completion event. Viewing an older result cannot acknowledge a newer one.</div>
</div><p class="muted">The report sequencer is a model input. Production adapters still need reliable source correlation before assigning those numbers; ordering messages after a delayed hook has arrived cannot recover the producer's original order.</p></section>
<section><h2>Native Mac captures</h2><p class="muted">Before and after stepping through the same disposable prototype. These are native screenshots, not webpage renderings.</p>
<div class="grid screens"><figure><img src="BEFORE_IMAGE" alt="Native prototype at its initial inventory state"><figcaption>Before: duplicate Studio names resolve to distinct server IDs.</figcaption></figure><figure><img src="AFTER_IMAGE" alt="Native prototype after a delayed old read, with newer Finished attention retained"><figcaption>After: turn B still needs attention after the delayed read of turn A. Control remains None.</figcaption></figure></div></section>
<section><h2>What ran on this Mac</h2><div class="table-wrap"><table><thead><tr><th>Agent</th><th>Installed version</th><th>Observed OSC activity</th></tr></thead><tbody>AGENT_ROWS</tbody></table></div>
<p>All four print/exec probes ran in native pseudoterminals and exited successfully. Antigravity did not emit an exit marker in this mode. Its foreground-process exit path needs a separate check. These probes did not open permission dialogs or ask questions.</p>
<p>The existing app passed 108 focused agent tests and 9 terminal/reattachment checks, including a real helper that reattached to the same shell. Those tests cover the current app; they do not prove the future Rust service or account inventory.</p>
<details><summary>Repeatable commands and sources</summary><pre>bash script/inventory-prototype/run.sh --verify script/inventory-prototype/evidence
bash script/inventory-prototype/run.sh
python3 script/inventory-prototype/native_ui.py
python3 script/inventory-prototype/native_signals.py
swift test --filter 'AgentAttention|AgentLifecycle|NativeAgentHooks|AgentActivityMarker|AgentNotificationInbox'
swift test --filter 'AgentActivityTerminalTests|PersistentTerminalStartupTests.testDetachReattachesSameShellAndReappliesCurrentRuntimeAndFittedGeometry'</pre><div id="sources"></div></details></section>
<section><h2>Storage evidence and limits</h2><p>The native checks sealed current state with AES-GCM, wrote ciphertext to a local file and recovered it in a fresh native process. A disposable key travelled through stdin and was never written to disk. Modified ciphertext and context were rejected. Restored runtime status stayed stale.</p>
<p>The command-expiry check uses a local fixture clock and a separate command file. It establishes separation in that fixture. Cloudflare retention, transactional crash recovery and retrieval through a real relay remain untested.</p>
<p class="muted">MEASUREMENTS The illustrative model bounds are 32 buffered reports per item, a report number ceiling of 1,000,000 and an 8 MiB sealed snapshot. Acknowledgment/tombstone/retired-run compaction is not implemented. These values are prototype guards, not a service quota or production resource budget.</p>
<p class="muted">Complete account-layout validation, endpoint membership, key distribution, rollback checkpoints and server-side replacement allocation are fixture inputs. The local checkpoint floor does not establish globally latest state. Server names use a versioned fixture register with stable operation identities; conflicting signed histories require the accepted layout/trust repair path.</p></section>
<section><h2>Still needed before this ticket closes</h2><ul>
<li>Human review of this candidate, including exact completion reads, persistent waits and explicit replacement after confirmed loss.</li>
<li>Real two-Mac synchronization through the Rust service and encrypted relay, including a fresh client with no other client online, stale-client deletion/acknowledgment recovery and a relay outage with approved direct access.</li>
<li>Interactive request and permission tests for each supported external-agent version, including concurrent requests, cancellation, forced exit and detached restoration.</li>
<li>Native iPhone/iPad inventory integration. Linux and Windows validation remains deferred under the agreed Mac-first scope.</li>
</ul></section>
<footer>Source links open in your IDE and need it running. This prototype remains local and uncommitted.</footer>
</main>
<script>
const SCENARIOS=SCENARIO_DATA;
const DISPLAY_STRIP_PREFIX=SOURCE_ROOT+'/';
let active=0,step=0;
const $=id=>document.getElementById(id);
function add(parent,tag,text,cls){const el=document.createElement(tag);el.textContent=text;if(cls)el.className=cls;parent.append(el);return el}
function render(){const scenario=SCENARIOS[active],frame=scenario.frames[step],s=frame.state;
 $('scenarioName').textContent=scenario.name;$('scenarioDetail').textContent=scenario.detail;$('action').textContent=frame.label;
 $('stepLabel').textContent=`Step ${step} of ${scenario.frames.length-1}`;$('next').disabled=step===scenario.frames.length-1;
 document.querySelectorAll('#tabs button').forEach((el,i)=>el.setAttribute('aria-selected',String(i===active)));
 $('inventory').replaceChildren();
 const label=id=>{const server=s.servers[id];if(!server)return id;return Object.values(s.servers).filter(x=>x.name===server.name).length>1?`${server.name} · ${id}`:server.name};
 const items=Object.values(s.items).filter(x=>(!frame.filter||x.server===frame.filter)&&(!frame.query||[x.title,x.workspace,label(x.server),x.agent||'',x.id].join(' ').toLowerCase().includes(frame.query.toLowerCase()))).sort((a,b)=>a.id.localeCompare(b.id));
 items.forEach(item=>{const attention=item.waits.length>0||(item.activity==='Finished'&&item.completion&&!s.acknowledgments.includes(item.completion));
 const card=add($('inventory'),'div','',`item ${attention?'attention':''}`);add(card,'h3',item.title);add(card,'p',`${item.workspace} · ${label(item.server)} · ${item.kind}`,'muted');
 if(attention)add(card,'span','Needs attention','pill');add(card,'p',item.kind==='Browser'?`Browser · ${item.terminal}`:`${item.agent||'Shell'} · ${item.waits.length?'Waiting for input':item.activity} · ${item.terminal}`);
 const server=s.servers[item.server];add(card,'p',`${server?.connected&&server?.reconciled?'Current':'Stale · unavailable or reconciling'} · ${item.observed}`,'small muted');
 add(card,'code',`Content ${item.id} · runtime ${item.runtime} · turn ${item.turn||'none'} · requests ${item.waits.join(', ')||'none'}`)});
 if(!items.length)add($('inventory'),'p','No inventory items match this recorded view.','empty');
 $('local').textContent=`Selected: ${frame.selected} · Control: ${frame.controller} · Focus: ${frame.focus} · Query: ${frame.query||'none'} · Server filter: ${frame.filter||'all'}\nExisting target: ${frame.selectedWorkspace} / ${frame.selectedPane} / ${frame.selectedTab}\nAcknowledged: ${s.acknowledgments.join(', ')||'none'} · Deleted: ${s.tombstones.join(', ')||'none'}`;
 $('allState').textContent=JSON.stringify(s,null,2);
}
SCENARIOS.forEach((s,i)=>{const button=add($('tabs'),'button',s.name);button.setAttribute('role','tab');button.onclick=()=>{active=i;step=0;render()}});
$('next').onclick=()=>{if(step<SCENARIOS[active].frames.length-1)step++;render()};$('reset').onclick=()=>{step=0;render()};
const SOURCE_FILES=['script/inventory-prototype/Model.swift','script/inventory-prototype/main.swift','script/inventory-prototype/evidence/verification.json','script/inventory-prototype/evidence/native-signals.json','script/inventory-prototype/evidence/native-ui.json'];
SOURCE_FILES.forEach(file=>{const path=SOURCE_ROOT+'/'+file;const p=add($('sources'),'p','');const a=add(p,'a',path.replace(DISPLAY_STRIP_PREFIX,'')+':1','ide');a.href='http://localhost:17877/browse?path='+encodeURIComponent(path)});
render();
</script>
'''
    replacements = {
        'CHECKED_AT': checked_at,
        'CHECK_COUNT': f"{checks['passed']} / {checks['passed'] + checks['failed']}",
        'UI_COUNT': str(len(steps)),
        'AGENT_ROWS': agent_rows,
        'BEFORE_IMAGE': encoded_image('native-before.png'),
        'AFTER_IMAGE': encoded_image('native-attention-6.png'),
        'MEASUREMENTS': f"The sample ciphertext envelope is {checks['snapshotBytes']:,} bytes. The {checks['loadFixture']['items']:,}-item fixture encoded to {checks['loadFixture']['jsonBytes']:,} bytes; one encode and 100 searches took {checks['loadFixture']['oneEncodeAnd100SearchesMilliseconds']:.0f} ms on this Mac. This is a single local sample.",
        'SCENARIO_DATA': scenarios,
        'SOURCE_ROOT': json.dumps(str(ROOT)),
    }
    # One pass prevents inserted text from being mistaken for another placeholder.
    import re
    report = re.sub('|'.join(map(re.escape, replacements)), lambda match: replacements[match.group()], report)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(report)
    print(OUTPUT)


if __name__ == '__main__':
    build()
