"""Render retained measured data; this page does not simulate an emulator."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--results", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--before-results", type=Path)
args = parser.parse_args()
data = {name: json.loads((args.results / filename).read_text()) for name, filename in
        [("swift", "swift-traces.json"), ("rust", "wezterm-traces.json"),
         ("comparison", "comparison.json"), ("run", "run.json")]}
if args.before_results:
    data["protocolProbe"] = json.loads((args.results / "protocol-probe.json").read_text())
    before = {name: json.loads((args.before_results / filename).read_text()) for name, filename in
              [("swift", "swift-traces.json"), ("rust", "wezterm-traces.json"),
               ("comparison", "comparison.json"), ("run", "run.json")]}
    middle = {"swift": before["swift"], "rust": data["rust"], "run": data["run"],
              "comparison": json.loads((args.results / "original-baseline-comparison.json").read_text())}
    data["scenarios"] = [dict(before, label="Before patches", swiftLabel="Original SwiftTerm", rustLabel="Original wezterm-term"),
                         dict(middle, label="After Rust fixes", swiftLabel="Original SwiftTerm", rustLabel="Patched wezterm-term"),
                         dict(data, label="After parser correction", swiftLabel="SwiftTerm with scratch parser fix", rustLabel="Patched wezterm-term")]
page = r'''<!doctype html>
<meta charset="utf-8">
<meta name="color-scheme" content="light">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>MyTerm · macOS terminal feasibility</title>
<style>
:root{--bg:#f8fafc;--surface:#fff;--surface-2:#f1f5f9;--text:#0f172a;--accent:#0e7490;--accent-soft:#ecfeff;--link:#155e75;--border:#e2e8f0;--font-display:'Space Grotesk',system-ui,sans-serif;--font-mono:'IBM Plex Mono',Menlo,monospace}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.5 var(--font-display)}main{max-width:1500px;margin:auto;padding:32px}h1{font-size:36px;line-height:1.2;margin:8px 0 16px}h2{font-size:22px}a{color:var(--link)}button,select,input{font:inherit}button,select{background:var(--surface);color:var(--text);border:1px solid var(--border);padding:10px;border-radius:6px}button[aria-selected=true]{background:var(--accent);color:var(--surface)}nav{display:flex;gap:8px;flex-wrap:wrap;margin:24px 0}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px}.card{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:20px;min-width:0}.callout{background:var(--accent-soft);border-left:4px solid var(--accent);padding:16px}.metric{font-size:30px;font-weight:700;color:var(--accent)}.split{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px;margin-top:18px}.split>*{min-width:0}pre{font:13px/1.6 var(--font-mono);background:var(--surface-2);padding:16px;overflow:auto;border-radius:6px}table{width:100%;border-collapse:collapse;font-size:14px}td,th{text-align:left;border-bottom:1px solid var(--border);padding:8px;vertical-align:top}code{overflow-wrap:anywhere}label{display:inline-flex;align-items:center;gap:12px;margin:12px 12px 0 0}details{margin-top:18px}summary{cursor:pointer}section[hidden]{display:none}.flow{display:flex;align-items:stretch;gap:12px;flex-wrap:wrap}.flow>.card{flex:1;min-width:220px}.muted{font-size:14px}.tablewrap{overflow:auto}#trace{max-width:100%}#differences{overflow-wrap:anywhere}
</style>
<main>
<div>MYTERM / LOCAL macOS EXPERIMENT</div>
<h1 id="heading">Promising engine; fidelity and reconnect remain open</h1>
<p>Actual headless wezterm-term and native SwiftTerm runs, using the same 17 retained traces and measured cell geometry. These are captured terminal models, not screenshots of the app.</p>
<div class="cards"><div class="card"><div class="metric" id="matches"></div>traces match the measured projection</div><div class="card"><div class="metric" id="diffCount"></div>traces contain differences</div><div class="card"><div class="metric">35 / 35</div>SwiftTerm checkpoint controls pass</div><div class="card"><div class="metric">Unproven</div>bounded Rust → SwiftTerm reconnect</div></div>
<nav id="scenarios" aria-label="Measured scenarios"></nav>
<p id="compatibilityStatus" hidden></p>
<nav aria-label="Evidence sections"><button aria-selected="true" data-tab="traces">Measured traces</button><button aria-selected="false" data-tab="protocol" id="protocolButton" hidden>Kitty protocol check</button><button aria-selected="false" data-tab="boundary">Reconnect boundary</button><button aria-selected="false" data-tab="options">Next options</button></nav>
<section id="traces">
<div class="callout">A projection match covers cells, basic styles, cursor, active buffer, history count and query bytes. It does not establish full modes, hyperlink equivalence, image fidelity, pixel rendering or reconnect. Image stripes and image cells use different representations and are not compared numerically.</div>
<p class="muted">Differences do not establish which engine is correct. Split Sixel has a known SwiftTerm baseline limitation; empty image state is not a graphics pass. Use the unsplit positive control when inspecting image support.</p>
<label>Trace <select id="trace"></select></label><label>Event <input id="event" type="range" min="0" value="0"><span id="eventNumber"></span></label>
<p id="differences"></p>
<div class="split"><div class="card"><h2 id="swiftLabel">SwiftTerm baseline</h2><pre id="swiftScreen"></pre><p id="swiftState"></p></div><div class="card"><h2 id="rustLabel">wezterm-term candidate</h2><pre id="rustScreen"></pre><p id="rustState"></p></div></div>
<details><summary>Full measured state for this event</summary><div class="split"><pre id="swiftRaw"></pre><pre id="rustRaw"></pre></div></details>
<h2>All traces</h2><div class="tablewrap"><table><thead><tr><th>Trace</th><th>Measured outcome</th><th>Different fields, by event</th></tr></thead><tbody id="rows"></tbody></table></div>
</section>
<section id="protocol" hidden>
<h2>Two image rows advance the cursor by two rows</h2>
<p>Fixture inputs: zero-based start <code>[2,1]</code>; placement <code>2 columns × 2 rows</code>. The current Kitty rule says to move right by columns and <a href="https://sw.kovidgoyal.net/kitty/graphics-protocol/#controlling-displayed-image-layout">“down by the number of rows in the image placement rectangle”</a>. The derived expectation is <code>[4,3]</code>.</p>
<nav id="protocolScenarios" aria-label="Cursor scenario"></nav><div class="card"><h3 id="protocolTitle"></h3><pre id="protocolGrid"></pre><p id="protocolOutcome"></p></div>
<p>The initial review interpreted the movement as rows minus one and withdrew that finding after checking the cited rule. Its superseded position lies beside the image’s last row. The measured native SwiftTerm and patched Rust cursor lie on the next row, matching the rule. This settles this placement example; it does not establish complete Kitty conformance.</p>
</section>
<section id="boundary" hidden>
<h2>There is no checkpoint bridge yet</h2>
<div class="flow"><div class="card"><h3>Rust server model</h3><p>Continuous parsing, screen state, graphics and query replies are exercised. Private parser and terminal state have no complete checkpoint export API at the pinned revision.</p></div><div class="card"><h3>Missing conversion</h3><p>A bounded representation must carry both buffers, history, cursor/saved state, modes, partial sequences and graphics references into SwiftTerm. No converter was built or measured in this gate.</p></div><div class="card"><h3>Fresh SwiftTerm client</h3><p>Native SwiftTerm-to-SwiftTerm checkpoints pass the existing controls. That format is not interchangeable with Rust's terminal model.</p></div></div>
<p>A formatted repaint cannot preserve the hidden state these tests exercise. Replaying an entire session would avoid conversion only by growing with session lifetime; it does not satisfy bounded reconnect.</p>
<h2>Error propagation also needs an embedding contract</h2><p>The injected BrokenPipe test confirms that advance_bytes returns normally after a failed query write. The embedding must retain and surface writer failures independently, or change that dependency API. The detached-query test confirms one cursor/status answer without a client attached.</p>
<h2>Limits of this gate</h2><p>No PTY/server integration, fresh-client initialization, replay-side-effect suppression, live output/resize race, production buffering budget or reconnect timing has been proved. Linux and Windows are deferred. No GitHub workflow ran.</p>
<p><a id="terminalSource">Pinned terminal/parser boundary</a> · <a id="performerSource">Pinned query writer</a></p>
</section>
<section id="options" hidden>
<h2>Choose the next bounded experiment</h2><div class="cards"><div class="card"><h3>1. Test compatibility fixes first</h3><p>Recommended. Keep wezterm-term and SwiftTerm. Investigate resize, image cursor placement and Kitty acknowledgements on macOS, then measure explicit fixes against these traces. Stop if preserving behavior requires maintaining substantial engine changes.</p></div><div class="card"><h3>2. Explore the checkpoint bridge first</h3><p>Prototype a versioned state conversion with strict bounds. It tackles the larger architectural uncertainty, but screen/reply differences remain and could invalidate the effort.</p></div><div class="card"><h3>3. Reconsider the engine boundary</h3><p>Return to the decision with these measured costs. Other Rust engines or a shared emulator core would need fresh evidence. A Swift server helper conflicts with the currently agreed one-process Rust boundary.</p></div></div>
<p>Accepting changed terminal behavior requires an explicit decision. This ticket remains open for Gordon's judgment.</p>
</section>
<details><summary>Environment and provenance</summary><pre id="metadata"></pre><p>Debug builds. Startup measurements inside the captured JSON are single observations, not regression budgets. The retained time log records process resource use. Wezterm-term declares MIT; its dependency graph includes separately licensed crates and still needs distribution review.</p></details>
</main>
<script>
const evidence=__DATA__;
let data=evidence;
const q=id=>document.getElementById(id);
function loadScenario(scenario){
data=scenario;q('trace').replaceChildren();q('rows').replaceChildren();
q('swiftLabel').textContent=data.swiftLabel||'SwiftTerm baseline';q('rustLabel').textContent=data.rustLabel||'wezterm-term candidate';
q('matches').textContent=Object.values(data.comparison).filter(x=>x.projectionMatches).length+' / 17';
q('diffCount').textContent=Object.values(data.comparison).filter(x=>!x.projectionMatches).length;
const metadata={...data.run};delete metadata.timestampUtc;metadata.measuredAt=new Date(data.run.timestampUtc).toLocaleString('en-AU',{timeZone:'Australia/Brisbane'})+' AEST';q('metadata').textContent=JSON.stringify(metadata,null,2);
q('terminalSource').href='https://github.com/wezterm/wezterm/blob/'+data.run.wezterm+'/term/src/terminal.rs';
q('performerSource').href='https://github.com/wezterm/wezterm/blob/'+data.run.wezterm+'/term/src/terminalstate/performer.rs';
document.querySelectorAll('[data-tab]').forEach(b=>b.onclick=()=>{document.querySelectorAll('[data-tab]').forEach(x=>{q(x.dataset.tab).hidden=x!==b;x.setAttribute('aria-selected',String(x===b));});});
for(const [name,result] of Object.entries(data.comparison)){
 const o=document.createElement('option');o.value=name;o.textContent=name;q('trace').append(o);
 const row=document.createElement('tr');for(const text of [name,result.projectionMatches?'Projection match':'Differences',result.differences.map(x=>x.event+': '+x.fields.join(', ')).join('; ')||'None']){const cell=document.createElement('td');cell.textContent=text;row.append(cell);}q('rows').append(row);
}
q('trace').value='alternate-shrink-grow';q('trace').onchange();
}
function render(){const name=q('trace').value;const i=Number(q('event').value);const s=data.swift[name].snapshots[i],r=data.rust[name].snapshots[i];q('eventNumber').textContent=i;
const fields=['cells','styles','cursor','alt','history','replies'].filter(k=>JSON.stringify(s[k])!==JSON.stringify(r[k]));
q('differences').textContent=fields.length?'Different: '+fields.join(', '):'Measured projection matches at this event.';
for(const [prefix,state] of [['swift',s],['rust',r]]){q(prefix+'Screen').textContent=state.cells.map(row=>row.map(c=>c||'·').join(' ')).join('\n');q(prefix+'State').textContent='Cursor '+JSON.stringify(state.cursor)+' · '+(state.alt?'alternate':'normal')+' buffer · history '+state.history+' · replies '+JSON.stringify(state.replies);q(prefix+'Raw').textContent=JSON.stringify(state,null,2);}}
q('trace').onchange=()=>{q('event').max=data.swift[q('trace').value].snapshots.length-1;q('event').value=q('event').max;render();};
q('event').oninput=render;
if(evidence.scenarios){
 q('protocolButton').hidden=false;
 const probe=evidence.protocolProbe;
 [['Original Rust (measured)',probe.originalRust],['Patched Rust (measured)',probe.patchedRust],['Native SwiftTerm (measured)',probe.nativeSwift],['Superseded review interpretation',probe.reviewerInterpretation]].forEach(([label,cursor],i)=>{
  const b=document.createElement('button');b.textContent=label;b.dataset.protocolScenario=i;b.onclick=()=>{document.querySelectorAll('[data-protocol-scenario]').forEach(x=>x.setAttribute('aria-selected',String(x===b)));q('protocolTitle').textContent=label;let rows=['       columns → 0 1 2 3 4 5 6'];for(let y=0;y<6;y++){let row=[];for(let x=0;x<7;x++)row.push(x===cursor[0]&&y===cursor[1]?'C':x>=2&&x<4&&y>=1&&y<3?'I':'.');rows.push('row '+y+'          '+row.join(' '));}q('protocolGrid').textContent=rows.join('\n');q('protocolOutcome').textContent='I = image cell; C = cursor. Position '+JSON.stringify(cursor)+(i===3?' (review interpretation)':' (captured engine state)')+'.';};q('protocolScenarios').append(b);});q('protocolScenarios').children[1].click();
 q('heading').textContent='Compatibility fixes clear the measured macOS differences';
 const counts=evidence.scenarios.map(s=>Object.values(s.comparison).filter(t=>t.projectionMatches).length+'/17');
 q('compatibilityStatus').hidden=false;q('compatibilityStatus').textContent='Scratch copies only. Original comparison: '+counts[0]+' → '+counts[1]+' after Rust fixes → '+counts[2]+' after correcting SwiftTerm DCS finalization. Nine compatibility traces and '+evidence.run.reviewControlPasses+' review controls pass; full split/unsplit Sixel retains graphics within each engine. The production Vendor/SwiftTerm files were not changed.';
 evidence.scenarios.forEach((s,i)=>{const b=document.createElement('button');b.textContent=s.label;b.dataset.scenario=i;b.onclick=()=>{document.querySelectorAll('[data-scenario]').forEach(x=>x.setAttribute('aria-selected',String(x===b)));loadScenario(s);};q('scenarios').append(b);});
 q('scenarios').lastElementChild.click();
 q('options').innerHTML='<h2>The next uncertainty is bounded state transfer</h2><div class="cards"><div class="card"><h3>Build a narrow checkpoint bridge</h3><p>Recommended next. Prove fresh SwiftTerm initialization with both buffers, hidden parser state, modes and retained graphics, then sequence subsequent output and resize under strict bounds. A repaint or unbounded log does not settle this.</p></div><div class="card"><h3>Keep the compatibility costs visible</h3><p>The experiment carries explicit Rust source patches and one scratch SwiftTerm parser correction. These require regression coverage, maintenance or upstream adoption before production use. General Kitty error responses, resource budgets and broad graphics fidelity remain open.</p></div></div><p>The ticket remains open. No production engine replacement or release acceptance follows from these trace matches.</p><p><a href="https://sw.kovidgoyal.net/kitty/graphics-protocol/#controlling-displayed-image-layout">Kitty cursor movement</a> · <a href="https://sw.kovidgoyal.net/kitty/graphics-protocol/#display-images-on-screen">Kitty placement acknowledgements</a></p>';
}else{q('scenarios').hidden=true;loadScenario(evidence);}
</script>'''
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(page.replace("__DATA__", json.dumps(data).replace("<", "\\u003c")))
print(args.output)
