"""Build the final self-contained native correction report from retained evidence."""
import argparse
import gzip
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    evidence = HERE/'evidence/final'
    with gzip.open(evidence/'matrix.json.gz', 'rt') as stream:
        matrix = json.load(stream)
    controls = json.loads((evidence/'controls.json').read_text())
    with gzip.open(HERE/'evidence/development/alpha-before.json.gz', 'rt') as stream:
        before = json.load(stream)['results'][0]['native'][0]['renderedPNG']
    after = next(c for c in matrix['results'] if c['name'] == 'alpha-overlap')['native'][0]['renderedPNG']
    summary = matrix['summary']
    page = '''<!doctype html>
<meta charset="utf-8">
<meta name="color-scheme" content="light">
<html lang="en"><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kitty placement correction</title><link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Ctext y='24' font-size='25'%3E%26gt;%3C/text%3E%3C/svg%3E">
<style>
:root{--bg:#f8fafc;--surface:#fff;--text:#0f172a;--muted:#64748b;--accent:#0e7490;--soft:#ecfeff;--line:#e2e8f0}*{box-sizing:border-box}html{font-size:17px}body{margin:0;background:var(--bg);color:var(--text);font-family:'Space Grotesk',system-ui,sans-serif}main{max-width:1260px;margin:auto;padding:2rem}h1{font-size:2.3rem;letter-spacing:-.04em;margin:.5rem 0}h2{font-size:1.45rem}p{line-height:1.55;max-width:80ch}a{color:var(--accent)}.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:.8rem;margin:1.6rem 0}.stat{border:1px solid var(--line);padding:1rem;background:var(--surface);min-width:0}.stat strong{font-size:2rem;display:block;color:var(--accent)}.stat span{font-size:.85rem}nav{display:flex;gap:.5rem;flex-wrap:wrap}button{font:inherit;padding:.7rem 1rem;border:1px solid var(--accent);background:var(--surface);color:var(--accent);cursor:pointer}button[aria-selected=true]{background:var(--accent);color:white}button:focus-visible{outline:3px solid var(--text);outline-offset:3px}section{background:var(--surface);padding:1.5rem;border:1px solid var(--line)}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:1rem}.grid>*{min-width:0}.card{padding:1rem;border:1px solid var(--line);background:var(--bg)}code{font-family:'IBM Plex Mono',monospace;font-size:.85rem;overflow-wrap:anywhere}.flow{display:flex;gap:.8rem;align-items:center;flex-wrap:wrap;margin:1.3rem 0}.node{border:2px solid var(--accent);padding:1rem;max-width:310px}.edge{color:var(--accent);font-size:.85rem}.callout{padding:1rem;background:var(--soft);margin:1rem 0}.crop{width:146px;height:258px;overflow:hidden;border:1px solid var(--accent);background:var(--text)}.crop img{width:5120px;max-width:none;image-rendering:pixelated}.small{color:var(--muted);font-size:.85rem}table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:.65rem;border-bottom:1px solid var(--line);vertical-align:top}th{background:var(--soft)}footer{color:var(--muted);font-size:.85rem;margin:1.3rem 0}.ide{border-bottom:1px dotted var(--accent);text-decoration:none}[hidden]{display:none!important}
</style></head><body><main>
<p><a href="https://github.com/GordonBeeming/myterm/issues/187">Resolve virtual and parent Kitty placement fidelity</a></p>
<h1>Bounded native correction verified</h1>
<p>Virtual and relative placements keep their identities, graph and complete clipped resources through reconnect. Both engines follow the accepted protocol behavior. The retained patch is ready for the production integration workstream.</p>
<div class="stats"><div class="stat"><strong>CASES</strong><span>native traces pass</span></div><div class="stat"><strong>COMPARISONS</strong><span>state and pixel comparisons pass</span></div><div class="stat"><strong>TRUTHS</strong><span>independent protocol assertions</span></div><div class="stat"><strong>REJECTIONS</strong><span>new malformed states rejected</span></div><div class="stat"><strong>49 + 2</strong><span>broader cases and Rust tests pass</span></div></div>
<nav role="tablist" aria-label="Correction report"><button role="tab" id="t-behavior" aria-controls="behavior" aria-selected="true">Behavior and state</button><button role="tab" id="t-before" aria-controls="before" aria-selected="false">Before and after</button><button role="tab" id="t-validation" aria-controls="validation" aria-selected="false">Verification and boundaries</button></nav>
<section id="behavior" role="tabpanel" aria-labelledby="t-behavior"><h2>Resources survive without historical output replay</h2><figure><div class="flow" role="img" aria-label="Rust retains original resources and placement graph, checkpoint validates bounded state, native client rebuilds clipped pixels"><div class="node"><strong>Rust service state</strong><p>Original image + each paint request<br>Placement identities and parent graph<br>Complete relative resource</p></div><span class="edge">checkpoint carries →</span><div class="node"><strong>Native client</strong><p>Validates graph and bounds<br>Restores full resources<br>Paints the visible intersection</p></div></div><figcaption class="small">A parent move can reveal previously clipped pixels after a fresh client import.</figcaption></figure>
<div class="grid"><div class="card"><h3>Graph and lifetime</h3><p>Cycles and missing/foreign parents are rejected. Deletion cascades to children. Virtual placements survive geometric delete modes. Automatic identities skip live identities.</p></div><div class="card"><h3>Rendering</h3><p>Alpha uses straight sRGB. Explicit dimensions letterbox. Truecolor placeholders use protocol byte order. Equal image/grid dimensions retain different paint requests independently.</p></div><div class="card"><h3>Failure and cost</h3><p>Preparation happens before replacement. Admission failure preserves old state. Relative count and raster budgets apply before placement. Unchanged output does not rebuild image planes.</p></div></div>
<p><a href="kitty-rendering-review.html">Open the measured sizing and geometry comparison</a>.</p></section>
<section id="before" role="tabpanel" aria-labelledby="t-before" hidden><h2>A shared alpha bug needed an independent truth check</h2><p>Both engines once matched while making a half-transparent midtone too bright. These are actual native raster crops of the same midtone-over-green input; the earlier exploratory capture used automatic bitmap scale, and the final capture uses explicit coherent 1× geometry. Image display is normalized to the same logical view region.</p><div class="grid"><div class="card"><h3>Before correction</h3><div class="crop"><img alt="Earlier native midtone blend, too bright and stretched" src="data:image/png;base64,BEFOREPNG"></div><p class="small">Shared interpretation produced red channel 143. The rectangle was also stretched.</p></div><div class="card"><h3>Corrected native renderer</h3><div class="crop"><img alt="Corrected native midtone blend with preserved aspect ratio and clear letterboxing" src="data:image/png;base64,AFTERPNG"></div><p class="small">Red channel 71; independent blending and letterbox checks pass.</p></div></div><div class="callout">Eight overlapping additions now retain 12 image cells. The retained old executable retains 514. After the initial placement, 100 unchanged output reads produce no additional projection in either engine.</div></section>
<section id="validation" role="tabpanel" aria-labelledby="t-validation" hidden><h2>Fresh replay, retained evidence</h2><table><thead><tr><th>Check</th><th>Result</th><th>Evidence</th></tr></thead><tbody><tr><td>Native matrix</td><td>CASES traces; COMPARISONS matching comparisons; no rejected exports/imports</td><td>Decoded pixels, graph, buffers, cursors and replies</td></tr><tr><td>Protocol and rejection controls</td><td>TRUTHS truths; REJECTIONS new controlled rejections</td><td>Independent pixel bounds, byte order, cap admission, invalid graph/cache inputs</td></tr><tr><td>Broader regression</td><td>49 pass; 2 expected bounds; 28 receiver negatives</td><td>Native stream and a real native PTY pass</td></tr><tr><td>Rust probe tests</td><td>2 pass</td><td>Query ownership and writer-failure boundary</td></tr><tr><td>Build and review</td><td>Fresh replay; source/executable hashes match; no review blockers</td><td>Twenty source files, patch and both measured binaries verified</td></tr></tbody></table>
<div class="callout">This is an unwindowed native NSView experiment with explicit coherent 1× font/image geometry. It is not live-window, Retina, iPhone/iPad, Linux/Windows, multi-Mac or production acceptance.</div>
<p>Experimental limits include 1 MiB checkpoint bytes, forty normal history lines, 32 cache images, 1,024 placements, 128 relative placements and 2 MiB aggregate relative raster cost. Anonymous image identity, animation and leased formats remain unsupported in this experiment.</p>
<p><a href="https://github.com/GordonBeeming/myterm/issues/189">Production terminal integration</a>, the <a href="https://github.com/GordonBeeming/myterm/issues/197">native raster-width investigation</a> and other platform/alternate-buffer acceptance remain required. Production must paint from the retained native request and original pixels, rather than treating Rust's logical cell texture grid as a final pixel raster.</p>
<p><a class="ide" data-path="README.md">README.md</a> · <a class="ide" data-path="prepare.py">prepare.py</a> · <a class="ide" data-path="evidence/final/matrix.json.gz">matrix.json.gz</a></p></section>
<footer>Local source links open in the IDE and need it running. The research branch stays pushed and is never merged.</footer>
</main><script>
const DISPLAY_STRIP_PREFIX='ROOT/';for(const link of document.querySelectorAll('[data-path]')){const path=DISPLAY_STRIP_PREFIX+link.dataset.path;link.href='http://localhost:17877/browse?path='+encodeURIComponent(path);link.textContent=path.replace(DISPLAY_STRIP_PREFIX,'');}
const tabs=[...document.querySelectorAll('[role=tab]')];function choose(t){for(const b of tabs){const a=b===t;b.setAttribute('aria-selected',a);b.tabIndex=a?0:-1;document.getElementById(b.getAttribute('aria-controls')).hidden=!a;}}for(const t of tabs){t.onclick=()=>choose(t);t.onkeydown=e=>{let i=tabs.indexOf(t);if(e.key==='ArrowRight')i=(i+1)%tabs.length;else if(e.key==='ArrowLeft')i=(i+tabs.length-1)%tabs.length;else return;e.preventDefault();choose(tabs[i]);tabs[i].focus();};}choose(tabs[0]);
</script></body></html>'''
    for key, value in [('CASES', summary['cases']), ('COMPARISONS', summary['comparisons']),
                       ('TRUTHS', len(controls['truths'])), ('REJECTIONS', len(controls['rejected']))]:
        page = page.replace(key, str(value))
    page = page.replace("DISPLAY_STRIP_PREFIX='ROOT/'", "DISPLAY_STRIP_PREFIX='"+str(HERE)+"/'")
    page = page.replace('BEFOREPNG', before).replace('AFTERPNG', after)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(page)
    (HERE/'result.html').write_text(page)
    print(args.output)


if __name__ == '__main__':
    main()
