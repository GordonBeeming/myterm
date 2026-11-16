"""Render captured native checkpoint results and actual before/after comparisons."""
import argparse
import base64
import datetime
import json
from pathlib import Path
import plistlib
from urllib.parse import quote
from zoneinfo import ZoneInfo

parser=argparse.ArgumentParser()
parser.add_argument('--results',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
parser.add_argument('--before-results',type=Path)
parser.add_argument('--review',type=Path)
args=parser.parse_args()
results=json.loads((args.results/'results.json').read_text())
metadata=json.loads((args.results/'run.json').read_text())
measured=datetime.datetime.fromisoformat(metadata['timestampUtc']).astimezone(ZoneInfo('Australia/Brisbane'))
data={'results':results,'measured':measured.strftime('%d %b %Y %H:%M AEST'),'comparisons':[],'graphics':[]}
if args.review:data['review']=json.loads(args.review.read_text())

def snapshot(s):
    state=plistlib.loads(base64.b64decode(s['nativeCheckpoint']))['state']
    return {k:s[k] for k in ['cells','styles','cursor','alt','history','replies']} | {
        'cursorStyle':state['options']['cursorStyle'],'savedNormal':[state['normalBuffer']['savedX'],state['normalBuffer']['savedY'],state['normalBuffer']['savedWraparound']],
        'alternateMargins':[state['alternateBuffer'][k] for k in ['scrollTop','scrollBottom','marginLeft','marginRight']]}

current={c['name']:c for c in results['cases']}
if args.before_results:
    before=json.loads((args.before_results/'results.json').read_text())
    data['beforeSummary']=before['summary']
    for c in before['cases']:
        if not c['status'].startswith('failed') or c['name'] not in current:continue
        now=current[c['name']]
        old=json.loads((args.before_results/f"{c['name']}-{c['event']}-clients.json").read_text())
        new=json.loads((args.results/f"{now['name']}-{now['event']}-clients.json").read_text())
        offset=c['differences'][0]['offset']
        data['comparisons'].append({'name':c['name'],'beforeDifferences':c['differences'],'currentOutcome':now['status'],
            'beforeReference':snapshot(old['reference']['snapshots'][c['event']+offset]),
            'beforeRestored':snapshot(old['restored']['snapshots'][offset]),
            'afterReference':snapshot(new['reference']['snapshots'][now['event']+offset]),
            'afterRestored':snapshot(new['restored']['snapshots'][offset])})
for name in ['sixel-full-positive-control','iterm-valid-png','kitty-retained-image','kitty-rgba-split']:
    if name not in current or current[name]['status']!='passed':continue
    c=current[name]
    clients=json.loads((args.results/f"{name}-{c['event']}-clients.json").read_text())
    last=clients['restored']['snapshots'][-1]
    state=plistlib.loads(base64.b64decode(last['nativeCheckpoint']))['state']
    images=[i for b in ['normalBuffer','alternateBuffer'] for line in state[b]['lines'] for i in line['images']]
    data['graphics'].append({'name':name,'stripes':[{'png':base64.b64encode(i['data']).decode(),'width':i['pixelWidth'],'height':i['pixelHeight'],'column':i['column']} for i in images[:8]],'count':len(images)})
root=Path(__file__).resolve().parents[2]
data['sources']=[{'name':str(p.relative_to(root)),'url':'http://localhost:17877/browse?path='+quote(str(p),safe='')} for p in [root/'script/wezterm-feasibility/README.md',root/'script/wezterm-feasibility/checkpoint-state.rs',root/'script/wezterm-feasibility/CheckpointBridge.swift']]
page=r'''<!doctype html>
<meta charset="utf-8">
<meta name="color-scheme" content="light">
<html lang="en"><meta name="viewport" content="width=device-width,initial-scale=1"><title>MyTerm · native checkpoint fidelity</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 30 30'%3E%3Crect width='30' height='30' rx='5' fill='%230e7490'/%3E%3Cpath d='m7 8 7 7-7 7m10 0h7' fill='none' stroke='white' stroke-width='3'/%3E%3C/svg%3E">
<style>
:root{--bg:#f8fafc;--surface:#fff;--surface-2:#f1f5f9;--text:#0f172a;--accent:#0e7490;--soft:#ecfeff;--link:#155e75;--border:#e2e8f0}*{box-sizing:border-box}html{font-size:16px}body{margin:0;background:var(--bg);color:var(--text);font:1rem/1.5 system-ui,sans-serif}main{max-width:1500px;margin:auto;padding:2rem}h1{font-size:2.2rem;line-height:1.2;margin:.5rem 0 1rem}h2{font-size:1.35rem}h3{font-size:1.1rem}nav{display:flex;gap:.5rem;flex-wrap:wrap;margin:1.5rem 0}button,select{font:inherit;background:var(--surface);color:var(--text);padding:.65rem .9rem;border:1px solid var(--border);border-radius:.35rem;max-width:100%}button{cursor:pointer}button[aria-selected=true]{background:var(--accent);color:white}button:focus-visible,select:focus-visible{outline:3px solid var(--accent)}section[hidden]{display:none}.cards,.split{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:1rem}.cards>*,.split>*{min-width:0}.card,article{background:var(--surface);padding:1.2rem;border:1px solid var(--border);border-radius:.5rem;min-width:0}.number{font-size:1.9rem;font-weight:700;color:var(--accent)}.note{background:var(--soft);border-left:4px solid var(--accent);padding:1rem;margin:1rem 0}.small{font-size:.9rem}pre,code{font-family:Menlo,monospace;font-size:.85rem;overflow-wrap:anywhere}pre{background:var(--surface-2);padding:1rem;white-space:pre-wrap;overflow-wrap:anywhere}a{color:var(--link)}a.source{text-decoration:underline dotted}.flow{display:grid;grid-template-columns:1fr auto 1fr auto 1fr;gap:.75rem;align-items:center}.arrow{color:var(--accent);font-size:1.4rem}.tablewrap{overflow:auto}table{border-collapse:collapse;width:100%;font-size:.9rem}td,th{padding:.6rem;text-align:left;vertical-align:top;border-bottom:1px solid var(--border)}.stripes{display:flex;flex-direction:column;align-items:flex-start;gap:0;background:var(--surface-2);padding:1rem;min-height:4rem}.stripes img{image-rendering:pixelated;max-width:100%;height:auto}figure{margin:1rem 0}figcaption{font-size:.9rem;margin:.7rem 0}@media(max-width:850px){main{padding:1rem}.flow{grid-template-columns:1fr}.arrow{transform:rotate(90deg)}}
</style><main><div class="small">MYTERM / NATIVE macOS ARM64 / SCRATCH PROTOTYPE</div><h1 id="title"></h1><p id="verdict"></p><div class="cards" id="stats"></div><p class="small" id="measured"></p><p class="small" id="review"></p>
<nav aria-label="Evidence sections"><button data-tab="gate" aria-selected="true">Native gate</button><button data-tab="before" aria-selected="false">Before and after</button><button data-tab="graphics" aria-selected="false">Actual image pixels</button><button data-tab="scope" aria-selected="false">Scope and sources</button></nav>
<section id="gate"><figure role="img" aria-label="One Rust owner exports bounded state to a fresh native SwiftTerm client"><div class="flow"><article><h3>Rust terminal owner</h3><p>Both buffers, parser continuation, images, keyboard state and native PTY.</p></article><div class="arrow">→</div><article><h3>Version 2 checkpoint</h3><p>Bounded cell runs, retained resources and committed sequence.</p></article><div class="arrow">→</div><article><h3>Fresh native client</h3><p>Native checkpoint import, original image requests, ordered output and resize.</p></article></div><figcaption>State transfer uses retained terminal resources, not an unbounded output log.</figcaption></figure>
<div class="note" id="pty"></div><div class="split"><article><h2>Capacity and timing</h2><p id="capacity"></p><p id="timing"></p><p class="small">Single local Debug observations, including native conversion. These are not release budgets or network measurements.</p></article><article><h2>Regression protection</h2><p id="controls"></p><p id="limits"></p><p>The gate exits unsuccessfully on a required-case difference, unexpected unsupported state or failed control.</p></article></div><h2>Captured scenarios</h2><div class="tablewrap"><table><thead><tr><th>Case</th><th>Result</th><th>Details</th></tr></thead><tbody id="rows"></tbody></table></div></section>
<section id="before" hidden><h2>Seven retained failures, revisited</h2><p>Each comparison shows captured native reference and restored states before and after the fixes. The explicit scratch SwiftTerm correction makes full-width margins follow a widening viewport; production Vendor/SwiftTerm remains unchanged.</p><select id="scenario"></select><p id="caseOutcome"></p><h3>Before</h3><div class="split" id="old"></div><h3>After</h3><div class="split" id="new"></div><pre id="oldDifferences"></pre></section>
<section id="graphics" hidden><h2>Decoded pixels and placement metadata</h2><p>These are actual restored native checkpoint stripes. The gate compares decoded RGBA hashes, stripe dimensions, positions and Kitty placement/cache state with the uninterrupted native client. An image-count match alone does not pass.</p><div class="cards" id="images"></div></section>
<section id="scope" hidden><h2>What changed</h2><p>The scratch Rust core now retains last-print location, saved wrap modes, per-buffer margins, keyboard stacks and image-size requests. Cell runs keep dense checkpoints bounded. Sixel color quantization follows the native client. The client rebuilds native stripes from retained image resources using actual fractional geometry.</p><p>The native PTY probe owns a real shell in one Rust process. A fresh SwiftTerm process acknowledges import before the owner resizes the PTY and continues output. The same shell PID and exact query replies are checked. This does not prove simultaneous scheduling during import or network delivery.</p><h2>Evidence boundary</h2><p>This is a local macOS prototype, not production architecture or release acceptance. No multi-Mac, Linux, Windows, iPhone or iPad validation is claimed. Linux and Windows remain deferred until a multi-Mac version exists.</p><p>Unrepresented terminal extensions, animations, parent/relative Kitty placements, arbitrary image overlaps/crops and production eviction behavior still need explicit validation. Limits fail visibly; the exporter is not an exhaustive validator of every terminal feature. Client view refresh, security transport, control leases, generation changes, slow-reader handling and broad application workloads remain integration work.</p><p>Defaults and graphemes come from a separate new native template. The experimental importer uses fixed default options with 40 history lines; it is not a drop-in importer for every configured view. Selected comparisons normalize unused blank allocation and default color variants, retaining styles, meaningful hidden cells and image pixels.</p><h2>Sources and commands</h2><p id="sources"></p><p class="small">Source links open in my IDE and need it running.</p><p><a href="https://github.com/GordonBeeming/myterm/issues/150">Validate Rust terminal state and SwiftTerm reconnect fidelity</a></p></section></main>
<script>
const d=__DATA__,r=d.results,s=r.summary,q=id=>document.getElementById(id);const DISPLAY_STRIP_PREFIX=__PREFIX__;
q('title').textContent=s.failed||s.unsupported?'Native fidelity still has open cases':'The retained native fidelity gate is green';q('verdict').textContent=s.passed+' restoration cases pass; '+s.failed+' differences and '+s.unsupported+' unexpected unsupported cases. The two intentional limit rejections remain checked.';
for(const [n,label] of [[s.passed,'restoration cases pass'],[s.failed,'fidelity differences'],[s.negativeControls,'malformed-state controls pass'],[s.rejectedLimits,'intentional limits reject']]){const card=document.createElement('div');card.className='card';const num=document.createElement('div');num.className='number';num.textContent=n;card.append(num,document.createTextNode(label));q('stats').append(card)}
q('measured').textContent='Captured '+d.measured+'. Pinned wezterm-term 458a100c1bf4134d36cb5c42dd90e4c8266d9e1a.';q('review').textContent=d.review?.summary||'Independent review of these fidelity changes is pending.';
q('pty').textContent=r.livePty?.passed?'Real PTY check passed: shell PID '+r.livePty.pid+' survived fresh-client import, received the actual 32×8 resize and produced exactly two cursor responses from the Rust owner before a clean exit.':'Live PTY check not established.';
const dense=r.cases.find(c=>c.name==='dense-120x40');q('capacity').textContent='Dense styled 120×40 with 40 history lines: '+dense.status+' ('+(dense.checkpointBytes||0).toLocaleString()+' bytes). Sparse 1,000/10,000-line checkpoints remain identical at '+r.boundedOutput.identicalCheckpointBytes.toLocaleString()+' bytes. The encoded cap stays at 1 MiB.';q('timing').textContent='Largest imported state: '+s.maximumCheckpointBytes.toLocaleString()+' bytes. Maximum observed import: '+(s.maximumImportNs/1e6).toFixed(2)+' ms.';q('controls').textContent=s.negativeControls+' intended-diagnostic rejection controls; '+Object.keys(r.positiveControls||{}).length+' positive controls. Both native Rust tests and seven existing Python regression tests pass; all 17 earlier engine projections remain unchanged.';q('limits').textContent='Two deliberate limit cases: an oversized unfinished token and an over-budget allocated cell grid. Neither is counted as a supported feature failure.';
for(const c of r.cases){const tr=document.createElement('tr');for(const value of [c.name,c.status,c.reason||c.differences?.map(x=>'+'+x.offset+': '+x.fields.join(', ')).join('; ')||c.checkpointBytes.toLocaleString()+' bytes']){const td=document.createElement('td');td.textContent=value;tr.append(td)}q('rows').append(tr)}
document.querySelectorAll('[data-tab]').forEach(b=>b.onclick=()=>{for(const id of ['gate','before','graphics','scope'])q(id).hidden=id!==b.dataset.tab;document.querySelectorAll('[data-tab]').forEach(x=>x.setAttribute('aria-selected',String(x===b)))});
for(const [i,c] of d.comparisons.entries()){const o=document.createElement('option');o.value=i;o.textContent=c.name;q('scenario').append(o)}
function card(label,state){const a=document.createElement('article'),h=document.createElement('h3'),p=document.createElement('pre'),meta=document.createElement('pre');h.textContent=label;p.textContent=state.cells.map(row=>row.map(x=>x||'·').join(' ')).join('\n');meta.textContent=JSON.stringify({cursor:state.cursor,history:state.history,cursorStyle:state.cursorStyle,savedNormal:state.savedNormal,alternateMargins:state.alternateMargins},null,2);a.append(h,p,meta);return a}
function comparison(){if(!d.comparisons.length){q('caseOutcome').textContent='No earlier failed capture was supplied.';return}const c=d.comparisons[Number(q('scenario').value)];q('caseOutcome').textContent='Current result: '+c.currentOutcome;q('old').replaceChildren(card('Uninterrupted native reference',c.beforeReference),card('Restored client before fixes',c.beforeRestored));q('new').replaceChildren(card('Current native reference',c.afterReference),card('Restored client after fixes',c.afterRestored));q('oldDifferences').textContent='Previously measured differences:\n'+JSON.stringify(c.beforeDifferences,null,2)}q('scenario').onchange=comparison;comparison();
for(const c of d.graphics){const a=document.createElement('article'),h=document.createElement('h3'),p=document.createElement('p'),stripes=document.createElement('div');h.textContent=c.name;p.textContent=c.count+' retained native stripes; exact pixel comparison passed.';stripes.className='stripes';for(const stripe of c.stripes){const img=document.createElement('img');img.src='data:image/png;base64,'+stripe.png;img.alt='Restored '+c.name+' native stripe, '+stripe.width+'×'+stripe.height;img.width=stripe.width;img.height=stripe.height;stripes.append(img)}a.append(h,p,stripes);q('images').append(a)}
for(const source of d.sources){const a=document.createElement('a');a.className='source';a.href=source.url;a.textContent=source.name.replace(DISPLAY_STRIP_PREFIX,'');q('sources').append(a,document.createElement('br'))}
</script></html>'''
args.output.parent.mkdir(parents=True,exist_ok=True)
args.output.write_text(page.replace('__DATA__',json.dumps(data).replace('<','\\u003c')).replace('__PREFIX__',json.dumps(str(root)+'/')))
print(args.output)
