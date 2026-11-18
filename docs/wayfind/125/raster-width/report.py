"""Build a self-contained visual comparison from the retained native captures."""
import argparse
import base64
import gzip
import io
import json
from pathlib import Path
from PIL import Image

HERE = Path(__file__).resolve().parent


def crop(encoded):
    with Image.open(io.BytesIO(base64.b64decode(encoded))) as image:
        # The terminal view is flipped: the first terminal row is at the top.
        result = image.crop((0, 0, 36, 36))
        stream = io.BytesIO()
        result.save(stream, format='PNG')
        return base64.b64encode(stream.getvalue()).decode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, default=HERE/'evidence')
    parser.add_argument('--output', type=Path, default=HERE/'comparison.html')
    args = parser.parse_args()
    data = json.load(gzip.open(args.evidence/'captures.json.gz', 'rt'))
    summary = json.loads((args.evidence/'summary.json').read_text())
    assessment = json.loads((args.evidence/'assessment.json').read_text())
    records = {r['name']: r for r in data['records']}
    scenarios = [
        ('headless', 'Headless mismatch', data['negative']['one']['snapshots'][0], data['negative']['two']['snapshots'][0],
         'Controlled font grid 1× → 2×; image scale stays 1×',
         'The same image request produces an 18-pixel or 17-pixel stripe. A deliberate cross-geometry checkpoint import also restores these different widths, and exact pixel comparison detects it. This reproduces the historical symptom through a controlled measurement condition; the original failed run did not record its scale values. The main-screen fallback was 1× in all 34 retained trial records. A later controlled-import process reported 2×, so the value varies between run sets. The unforced headless trials did not exercise the 2× fallback.'),
        ('window', 'Real Retina window', records['window-early-0-reset-0']['reference']['snapshots'][0], records['window-early-0-reset-1']['reference']['snapshots'][0],
         'Same 2× window; cached cells → explicitly refreshed cells',
         'The view starts with a 9-point cell measured before window attachment. Attaching to the Retina window changes image scale to 2× and keeps that cached cell width. Assigning the same font again measures an 8.5-point cell. Both geometries restore exactly when reference and importer use the same measurements.'),
    ]
    tabs = ''.join(f'<button role="tab" id="tab-{key}" aria-controls="{key}" aria-selected="{str(i==0).lower()}">{title}</button>' for i,(key,title,*_) in enumerate(scenarios))
    sections = []
    for index,(key,title,left,right,subtitle,description) in enumerate(scenarios):
        cards = []
        for label,snapshot in [('Before',left),('After',right)]:
            geometry = snapshot['imageGeometry']
            cards.append(f'''<div class="capture"><h3>{label}</h3><p>Cell width <strong>{geometry[0]} pt</strong> · image scale <strong>{geometry[2]}×</strong></p><img class="crop" width="216" height="216" alt="Actual native raster crop, top left 36 by 36 logical pixels" src="data:image/png;base64,{crop(snapshot['renderedPNG'])}"><p class="small">Actual NSView capture, 36 × 36 crop enlarged 6×.</p><details><summary>Full native view</summary><img class="full" alt="Full actual native terminal view capture" src="data:image/png;base64,{snapshot['renderedPNG']}"></details></div>''')
        sections.append(f'''<section id="{key}" role="tabpanel" aria-labelledby="tab-{key}" {'hidden' if index else ''}><h2>{subtitle}</h2><p>{description}</p><div class="captures">{''.join(cards)}</div></section>''')
    html = '''<!doctype html>
<meta charset="utf-8">
<meta name="color-scheme" content="light">
<html lang="en"><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MyTerm raster-width investigation</title><link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Ctext y='24' font-size='25'%3E%26gt;%3C/text%3E%3C/svg%3E">
<style>
:root{--bg:#f8fafc;--surface:#ffffff;--text:#0f172a;--muted:#64748b;--accent:#0e7490;--soft:#ecfeff;--border:#e2e8f0;--code:#f1f5f9}
*{box-sizing:border-box}html{font-size:17px}body{margin:0;background:var(--bg);color:var(--text);font-family:'Space Grotesk',system-ui,sans-serif}main{max-width:1260px;margin:auto;padding:2rem}h1{font-size:2.25rem;letter-spacing:-.04em;margin-bottom:.8rem}h2{font-size:1.4rem}h3{font-size:1.1rem}p{line-height:1.6;max-width:80ch}a{color:var(--accent)}code{font-family:'IBM Plex Mono',monospace;font-size:.85rem;overflow-wrap:anywhere;background:var(--code);padding:.15rem}.status{background:var(--soft);padding:1rem;border:1px solid var(--border)}figure{margin:1.5rem 0}.flow{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:.7rem}.flow>*{min-width:0;border:1px solid var(--accent);background:var(--surface);padding:1rem}.flow b{display:block;margin-bottom:.5rem}.small,figcaption{font-size:.85rem;color:var(--muted)}figcaption{margin-top:.7rem;line-height:1.5}nav{display:flex;gap:.5rem;flex-wrap:wrap;margin-top:1.6rem}button{font:inherit;background:var(--surface);color:var(--accent);border:1px solid var(--accent);padding:.7rem 1rem;cursor:pointer}button[aria-selected=true]{background:var(--accent);color:white}button:focus-visible,summary:focus-visible{outline:3px solid var(--text);outline-offset:3px}section{padding:1.4rem;background:var(--surface);border:1px solid var(--border)}.captures{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:1rem}.captures>*{min-width:0}.capture{border:1px solid var(--border);padding:1rem}.crop{image-rendering:pixelated;border:1px solid var(--border);max-width:100%;height:auto}.full{width:100%;height:auto;margin-top:.6rem}summary{cursor:pointer;color:var(--accent)}footer{font-size:.85rem;color:var(--muted);line-height:1.6;margin:1.5rem 0}[hidden]{display:none!important}
</style></head><body><main>
<a href="https://github.com/GordonBeeming/myterm/issues/197">Investigate intermittent native checkpoint raster width</a>
<h1>Two valid cell widths, one mismatched comparison</h1>
<p class="status">COMPARISONS exact checkpoint comparisons passed. ASSERTIONS independent geometry assertions passed. The controlled 17-versus-18-pixel negative control still fails exact equality.</p>
<figure><div class="flow" role="img" aria-label="Raw glyph width snaps to a display pixel grid, is cached in the cell dimensions, and determines image stripe width"><div><b>Font measurement</b>Raw glyph advance<br><code>8.0361328125 pt</code></div><div><b>Snap to display grid</b><code>ceil(raw × scale) / scale</code><p>1× → 9 pt<br>2× → 8.5 pt</p></div><div><b>Cache and paint</b>Two columns →<br><code>2 × cell width</code><p>9 pt → 18-pixel stripe<br>8.5 pt → 17-pixel stripe</p></div></div><figcaption>The measured Mac image-stripe bitmap uses the cached cell width in points. Physical wire-cell dimensions also include display scale; the importer validates those separately.</figcaption></figure>
<nav role="tablist" aria-label="Measured scenarios">TABS<button role="tab" id="tab-production" aria-controls="production" aria-selected="false">Production integration</button></nav>
SECTIONS
<section id="production" role="tabpanel" aria-labelledby="tab-production" hidden><h2>Geometry changes need an ordered integration contract</h2><p>The diagnostic moved real windows between all three available displays, including 1× ↔ 2× transitions. Window/image scale changed immediately; cached cell width stayed fixed unless the diagnostic explicitly refreshed the font. Twelve movement runs retain the actual screen reached and measurements at each step.</p><p>Existing images keep their prepared stripes after a move. Updating scale or cell metrics alone therefore does not prove reconnect equivalence after a geometry change. The production server and clients must agree on authoritative geometry and image rematerialization, with ordered checkpoints and live output.</p><p><a href="https://github.com/GordonBeeming/myterm/issues/189">Validate production terminal checkpoints and native SwiftTerm reconnect</a> retains that acceptance work, including fonts, scale transitions, controller/viewer behavior and retained images. This investigation changes no production code.</p><p>The captures exercise the native CoreGraphics NSView path and the bounded Rust checkpoint bridge. Metal onscreen pixels, iPhone/iPad, other machines and full MyTerm controller/transport integration remain unverified. The historical failing run had no geometry instrumentation, so its exact initialization sequence cannot be reconstructed.</p></section>
<footer>Actual native captures from the verified diagnostic build. The mixed headless condition is deliberately controlled. State, exact logical/backing bitmap pixels and continuation output were compared separately. All disposable native diagnostic windows were closed.</footer>
</main><script>const tabs=[...document.querySelectorAll('[role=tab]')];function select(tab){for(const b of tabs){const active=b===tab;b.setAttribute('aria-selected',String(active));b.tabIndex=active?0:-1;document.getElementById(b.getAttribute('aria-controls')).hidden=!active;}}for(const tab of tabs){tab.onclick=()=>select(tab);tab.onkeydown=e=>{let index=tabs.indexOf(tab);if(e.key==='ArrowRight')index=(index+1)%tabs.length;else if(e.key==='ArrowLeft')index=(index+tabs.length-1)%tabs.length;else return;e.preventDefault();select(tabs[index]);tabs[index].focus();};}select(tabs[0]);</script></body></html>'''
    html = html.replace('COMPARISONS', str(summary['comparisons'])).replace('ASSERTIONS', str(assessment['passed'])).replace('TABS', tabs).replace('SECTIONS', ''.join(sections))
    args.output.write_text(html)
    print(args.output)


if __name__ == '__main__':
    main()
