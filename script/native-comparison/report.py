#!/usr/bin/env python3
"""Render captured probe results as a self-contained inspection page."""
import argparse
import json
from pathlib import Path

TEMPLATE = r'''<!doctype html>
<meta charset="utf-8">
<meta name="color-scheme" content="light">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Native session comparison</title>
<style>
:root{--bg:#f8fafc;--surface:#fff;--surface-2:#f1f5f9;--text:#0f172a;--text-muted:#64748b;--border:#e2e8f0;--accent:#0e7490;--accent-soft:#ecfeff;--accent-soft-text:#155e75;--link:#0e7490;--danger:#e11d48;--font-body:'Space Grotesk',ui-sans-serif,system-ui,-apple-system,'Segoe UI',sans-serif;--font-mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.5 var(--font-body)}main{max-width:1600px;margin:auto;padding:32px}h1{font-size:36px;letter-spacing:-.035em;margin:0 0 8px}h2{font-size:23px;margin:0 0 14px}h3{font-size:18px;margin:0}p{margin:8px 0 16px}a{color:var(--link)}.muted{color:var(--text-muted)}.tag{display:inline-block;padding:5px 12px;border-radius:20px;background:var(--accent-soft);color:var(--accent-soft-text);font-size:14px;font-weight:650}.summary,.engines{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px;margin:20px 0}.card,section{min-width:0;border:1px solid var(--border);border-radius:14px;background:var(--surface);padding:20px}.card strong{display:block;font-size:27px;color:var(--accent)}section{margin-top:20px}table{width:100%;border-collapse:collapse;font-size:14px}th,td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--border);vertical-align:top}th{background:var(--surface-2)}.controls{display:flex;align-items:center;flex-wrap:wrap;gap:12px}select,button{font:inherit;padding:8px 12px;border-radius:8px;border:1px solid var(--border);background:var(--surface);color:var(--text)}button[aria-pressed=true]{background:var(--accent);color:white}.engine{background:var(--surface-2);border-radius:10px;padding:16px;min-width:0}.screen{font:15px/1.55 var(--font-mono);white-space:pre-wrap;overflow-wrap:anywhere;margin:12px 0;border:1px solid var(--border);border-radius:8px;padding:12px;background:var(--surface)}code,pre{font-family:var(--font-mono);overflow-wrap:anywhere}pre{white-space:pre-wrap;font-size:13px}.facts{font-size:14px}.finding{border-left:4px solid var(--accent);padding-left:16px;margin:16px 0}.engine p{font-size:14px}.file-link{border-bottom:1px dotted var(--link);text-decoration:none}footer{font-size:13px;color:var(--text-muted);padding-top:20px}#trace-note{font-size:14px}details{margin-top:12px}summary{cursor:pointer} @media(max-width:700px){main{padding:16px}h1{font-size:28px}th,td{padding:8px 5px;font-size:12px}}
</style>
<main>
<span class="tag">Local macOS evidence · cross-platform runs pending</span>
<h1>Both adapters work locally; terminal fidelity needs work</h1>
<p class="muted" id="environment"></p>
<p>Go and Rust are server candidates, including the macOS server. The Mac, iPhone and iPad clients remain native.</p>
<div class="summary"><div class="card"><strong id="adapter-count"></strong>Native adapter cases passed on this Mac</div><div class="card"><strong id="trace-count"></strong>Same bytes and resizes across three engines</div><div class="card"><strong id="checkpoint-count"></strong>SwiftTerm checkpoint equality checks passed</div><div class="card"><strong>Still open</strong>Linux, Windows and Gordon's fidelity judgment</div></div>
<section>
<h2>What the evidence supports</h2>
<table><thead><tr><th>Behavior</th><th>Go candidate</th><th>Rust candidate</th></tr></thead><tbody>
<tr><td>Local process adapters</td><td id="go-adapters"></td><td id="rust-adapters"></td></tr>
<tr><td>Observer reconnect</td><td colspan="2">Actual loopback disconnect, same child PID, detached output retained, 64 KiB final payload plus exit marker. This measures raw-byte retention.</td></tr>
<tr><td>Parsing continuously</td><td>Unicode trace matches measured fields; resize cases differ</td><td>Unicode and alternate resize cases differ</td></tr>
<tr><td>Query responses</td><td>Status reply differs; Kitty keyboard/image replies absent</td><td>No responder added to the parser in this probe</td></tr>
<tr><td>Reconnect state</td><td>Full parser/checkpoint export remains unproven</td><td>Formatted-state reconstruction loses split-parser continuation and alternate state</td></tr>
<tr><td>Graphics</td><td colspan="2">SwiftTerm retains images in PNG, Kitty and full Sixel positive controls. Neither candidate demonstrates image preservation.</td></tr>
</tbody></table>
<p class="finding">The split Sixel baseline emits no image even though its checkpoint equality passes. The full Sixel control retains seven image stripes. Empty graphics state is not counted as parity.</p>
</section>
<section>
<h2>Inspect a recorded trace</h2>
<div class="controls"><label>Trace <select id="trace"></select></label><label>Event <select id="event"></select></label><button id="cells" aria-pressed="true">Captured cells</button><button id="styles" aria-pressed="false">Style differences</button><button id="reconstruction" aria-pressed="false">Reconstructed state</button></div>
<p class="muted" id="trace-note"></p>
<div class="engines" id="engines"></div>
<p class="muted facts">Cell projection only: · means an empty cell; separators preserve column identity. These are captured emulator states, not native-client screenshots. Final replies are escaped below each engine. Reconstructed state shows SwiftTerm's checkpoint-equal state and Rust's actual fresh-parser state. Image pixels, full mode state, history equivalence and key-event encoding need separate evidence.</p>
</section>
<section>
<h2>Native experiment details</h2><div id="sessions"></div>
<details><summary>Scope, sources and repeatable command</summary>
<p>The prototype tests one observer and bounds retained output to 1 MiB. It does not test the production transport, multiple viewers, writer leases, process-tree cleanup, service restart or upgrade survival. Terminal traces run separately from the PTY adapter, so server-owned detached query handling remains unverified.</p>
<pre>python3 script/native-comparison/run.py --output /tmp/myterm-native-comparison</pre>
<p><a href="https://github.com/GordonBeeming/myterm/issues/138">Compare native session adapters and terminal fidelity</a> · <a href="https://github.com/GordonBeeming/myterm/issues/130">Choose the standalone server boundary and runtime</a></p>
<p><a class="file-link" href="__REPORT_URL__" title="__REPORT_PATH__">__REPORT_PATH__</a></p>
</details>
</section>
<footer>Recorded <span id="recorded"></span>. Local file links open in Gordon's IDE and need it running. The prepared native-runner workflow has not been published.</footer>
</main>
<script type="application/json" id="data">__DATA__</script>
<script>
const D=JSON.parse(document.getElementById('data').textContent),$=id=>document.getElementById(id);
const DISPLAY_STRIP_PREFIX='/Users/gordonbeeming/Developer/';
document.querySelectorAll('.file-link').forEach(a=>{a.textContent=a.title.startsWith(DISPLAY_STRIP_PREFIX)?a.title.slice(DISPLAY_STRIP_PREFIX.length):a.title});
$('environment').textContent=D.run.os+' · '+D.run.go+' · '+D.run.rustc;
$('recorded').textContent=new Intl.DateTimeFormat('en-AU',{timeZone:'Australia/Brisbane',dateStyle:'medium',timeStyle:'short'}).format(new Date(D.run.finishedAt))+' AEST';
const adapterCases=Object.values(D.sessions).flatMap(Object.values);$('adapter-count').textContent=adapterCases.filter(s=>s.status==='pass').length+' / '+adapterCases.length;
$('trace-count').textContent=D.fixtures.length+' traces';const checks=Object.values(D.traces.swiftterm).flatMap(t=>t.checkpointChecks);$('checkpoint-count').textContent=checks.filter(Boolean).length+' / '+checks.length;
for(const n of ['go','rust'])$(n+'-adapters').textContent=Object.entries(D.sessions[n]).map(([label,s])=>label+' '+s.status).join(' · ');
const names=['swiftterm','go','rust'],labels={swiftterm:'SwiftTerm baseline',go:'Go · x/vt 0.1.0',rust:'Rust · vt100 0.18.1'};
let mode='cells';
D.fixtures.forEach(f=>{const option=new Option(f.name,f.name);$('trace').add(option)});
$('trace').value='split-utf8';
function escaped(bytes){return Array.from(bytes,b=>b===27?'ESC ':b<32?'\\x'+b.toString(16).padStart(2,'0'):String.fromCharCode(b)).join('')||'(none)'}
function render(){
 const trace=$('trace').value,i=Number($('event').value),fixture=D.fixtures.find(f=>f.name===trace);
 $('engines').replaceChildren();
 $('trace-note').textContent=fixture.note||'Each event applies its bytes and/or resize. The checkpoint marker captures state before the next event; compare the final event to inspect continuation.';
 for(const name of names){
  const t=D.traces[name][trace],baseline=D.traces.swiftterm[trace].snapshots[i];
  const snap=mode==='reconstruction'&&name==='rust'?t.reconstructionSnapshots[i]:t.snapshots[i];
  const panel=document.createElement('div');panel.className='engine';
  const title=document.createElement('h3');title.textContent=labels[name];panel.append(title);
  if(mode==='reconstruction'&&(name==='go'||!snap)){const p=document.createElement('p');p.textContent=name==='go'?'Full parser/checkpoint reconstruction was not implemented for this candidate.':'No reconstruction exists before the checkpoint event.';panel.append(p);$('engines').append(panel);continue;}
  const state=document.createElement('p');state.textContent=`Cursor [${snap.cursor.join(', ')}] · ${snap.alt?'alternate':'normal'} buffer · ${snap.cells[0].length} × ${snap.cells.length}`;panel.append(state);
  const screen=document.createElement('pre');screen.className='screen';
  if(mode==='styles'){const differences=[];snap.styles.forEach((r,y)=>r.forEach((s,x)=>{if(baseline.styles[y]?.[x]!==s)differences.push(`[${x},${y}] ${s}`)}));screen.textContent=differences.slice(0,15).join('\n')||'No basic style differences from baseline at this event.';if(differences.length>15)screen.textContent+=`\n… ${differences.length} differences total`;}
  else screen.textContent=snap.cells.map(row=>row.map(c=>c||'·').join('│')).join('\n');
  panel.append(screen);
  const checks=t.checkpointChecks;let checkpoint='Full parser checkpoint not exercised';if(checks)checkpoint=checks.every(Boolean)?'Recorded reconstruction checks passed ('+checks.length+')':'Recorded reconstruction checks include failures';
  const p=document.createElement('p');p.textContent=(name==='swiftterm'?'Binary checkpoint: ':name==='rust'?'Formatted-state reconstruction: ':'')+checkpoint;panel.append(p);
  const graphics=document.createElement('p');graphics.textContent=name==='swiftterm'?'Retained image stripes: '+snap.imageStripes:'Image retention not demonstrated by this probe';panel.append(graphics);
  const replies=document.createElement('pre');replies.textContent=(name==='rust'?'Responder not implemented. Emitted bytes: ':'Final replies: ')+escaped(t.finalReplies);panel.append(replies);
  $('engines').append(panel);
 }
}
function changeTrace(){const count=D.traces.swiftterm[$('trace').value].snapshots.length;$('event').replaceChildren();for(let i=0;i<count;i++)$('event').add(new Option((i+1)+' / '+count,i));$('event').value=count-1;render()}
$('trace').onchange=changeTrace;$('event').onchange=render;
for(const choice of ['cells','styles','reconstruction'])$(choice).onclick=()=>{mode=choice;for(const value of ['cells','styles','reconstruction'])$(value).setAttribute('aria-pressed',String(mode===value));render()};
changeTrace();
for(const name of ['go','rust']){const p=document.createElement('p');p.textContent=name.toUpperCase()+': '+Object.entries(D.sessions[name]).map(([label,s])=>label+' '+s.status.toUpperCase()+' (PID '+s.pid+')').join(' · ');$('sessions').append(p)}
</script>
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--results', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    options = parser.parse_args()
    root = options.results
    run = json.loads((root / 'run.json').read_text())
    if run['status'] != 'pass':
        raise SystemExit('A successful local adapter run is required before rendering this report.')
    data = {'run': run, 'fixtures': json.loads((Path(__file__).parent / 'fixtures.json').read_text()),
            'sessions': json.loads((root / 'sessions.json').read_text()),
            'traces': {name: json.loads((root / f'{name}-traces.json').read_text()) for name in ['swiftterm', 'go', 'rust']}}
    import hashlib
    if run['fixturesSHA256'] != hashlib.sha256((Path(__file__).parent / 'fixtures.json').read_bytes()).hexdigest():
        raise SystemExit('Results do not match the current fixture hash.')
    report = Path(__file__).resolve().parents[2] / 'docs/research/myterm-native-adapter-comparison.md'
    from urllib.parse import quote
    html = TEMPLATE.replace('__DATA__', json.dumps(data, ensure_ascii=False).replace('<', '\\u003c'))
    html = html.replace('__REPORT_PATH__', str(report)).replace('__REPORT_URL__', 'http://localhost:17877/browse?path=' + quote(str(report), safe=''))
    options.output.parent.mkdir(parents=True, exist_ok=True)
    options.output.write_text(html, encoding='utf-8')
    print(options.output)


if __name__ == '__main__':
    main()
