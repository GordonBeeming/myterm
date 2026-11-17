"""Render measured sizing and geometry evidence for the independent review."""
import argparse
import base64
import gzip
import hashlib
import io
import json
import os
from pathlib import Path

from PIL import Image
from probe import fixtures, invoke, decoded_pixels

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build = args.build.resolve()
    args.output.mkdir(parents=True)
    env = dict(os.environ, CELL_WIDTH='9', CELL_HEIGHT='16', MYTERM_PROBE_RASTER='1')
    selected = [f for f in fixtures() if f['name'] in ('single-width-preserves-aspect',
                'natural-width-one-hundred', 'virtual-parent-hidden-reveal')]
    candidates = invoke(build/'server', selected, env)
    evidence = {}
    for case in selected:
        events = [{'sequence': i, 'event': e} for i, e in enumerate(case['events'])]
        reference = invoke(build/'client', {'events': events}, env)
        checkpoint = candidates[case['name']]['checkpoints'][0]
        restored = invoke(build/'client', {'checkpoint': checkpoint['bytes'], 'events': events[1:]}, env)
        comparisons = [decoded_pixels(a['renderedPNG']) == decoded_pixels(b['renderedPNG'])
                       for a, b in zip(reference['snapshots'], restored['snapshots'], strict=True)]
        if not all(comparisons):
            raise AssertionError(case['name'])
        evidence[case['name']] = {'reference': reference, 'restored': restored,
                                  'checkpoint': json.loads(bytes(checkpoint['bytes'])),
                                  'pixelMatches': comparisons}
    case = next(case for case in selected if case['name'] == 'single-width-preserves-aspect')
    checkpoint = candidates[case['name']]['checkpoints'][0]
    normal = invoke(build/'client', {'events': [{'sequence': i, 'event': e}
                    for i, e in enumerate(case['events'])]}, dict(env, PROTOTYPE_FONT_GRID_SCALE='1'))
    mixed = invoke(build/'client', {'checkpoint': checkpoint['bytes'], 'events': []},
                   dict(env, PROTOTYPE_FONT_GRID_SCALE='2'))
    evidence['geometry-diagnostic'] = {
        'fontGridOneImageOne': normal['snapshots'][0],
        'fontGridTwoImageOne': mixed['snapshots'][0],
        'samePixels': decoded_pixels(normal['snapshots'][0]['renderedPNG']) == decoded_pixels(mixed['snapshots'][0]['renderedPNG']),
    }
    evidence['binaries'] = {name: hashlib.sha256((build/name).read_bytes()).hexdigest()
                            for name in ('server', 'client')}
    with gzip.open(args.output/'data.json.gz', 'xt') as stream:
        json.dump(evidence, stream)
    first = evidence['single-width-preserves-aspect']
    graphic = first['checkpoint']['state']['graphics'][0]
    data = {
        'grid': [graphic['displayWidth'], graphic['displayHeight']],
        'request': graphic['request'],
        'geometryOne': evidence['geometry-diagnostic']['fontGridOneImageOne']['imageGeometry'],
        'geometryTwo': evidence['geometry-diagnostic']['fontGridTwoImageOne']['imageGeometry'],
        'samePixels': evidence['geometry-diagnostic']['samePixels'],
    }
    (args.output/'summary.json').write_text(json.dumps(data, indent=2)+'\n')
    actual = first['reference']['snapshots'][0]['renderedPNG']
    imported = first['restored']['snapshots'][0]['renderedPNG']
    html = '''<!doctype html>
<meta charset="utf-8">
<meta name="color-scheme" content="light">
<html lang="en"><head><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kitty rendering evidence</title><link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Ctext y='24' font-size='25'%3E%26gt;%3C/text%3E%3C/svg%3E">
<style>
:root{--bg:#f8fafc;--surface:#fff;--text:#0f172a;--muted:#64748b;--accent:#0e7490;--soft:#ecfeff;--line:#e2e8f0}
*{box-sizing:border-box}html{font-size:17px}body{margin:0;background:var(--bg);color:var(--text);font-family:'Space Grotesk',system-ui,sans-serif}main{max-width:1260px;margin:auto;padding:2rem}h1{font-size:2.2rem;letter-spacing:-.04em}p{line-height:1.55;max-width:78ch}a{color:var(--accent)}nav{display:flex;gap:.5rem;flex-wrap:wrap;margin:1.5rem 0 0}button{font:inherit;padding:.7rem 1rem;border:1px solid var(--accent);background:var(--surface);color:var(--accent);cursor:pointer}button[aria-selected=true]{background:var(--accent);color:white}button:focus-visible{outline:3px solid var(--text);outline-offset:3px}section{background:var(--surface);padding:1.5rem;border:1px solid var(--line)}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:1.2rem}.grid>*{min-width:0}.box{border:1px solid var(--line);padding:1rem;background:var(--bg)}code{font-family:'IBM Plex Mono',monospace;font-size:.85rem;overflow-wrap:anywhere}.crop{width:74px;height:130px;overflow:hidden;border:1px solid var(--accent);background:var(--text)}.crop img{width:2560px;max-width:none;image-rendering:pixelated}.model{width:74px;height:130px;border:1px solid var(--accent);background:var(--accent)}.diagram{display:flex;align-items:center;gap:1rem;flex-wrap:wrap;margin:1rem 0}.node{border:2px solid var(--accent);padding:1rem;max-width:330px}.edge{color:var(--accent);font-size:.85rem}.note{color:var(--muted);font-size:.85rem}.facts{background:var(--soft);padding:1rem;margin-top:1rem}td,th{padding:.6rem;text-align:left;border-bottom:1px solid var(--line)}table{width:100%;border-collapse:collapse}footer{margin:1.5rem 0;color:var(--muted);font-size:.85rem}[hidden]{display:none!important}
</style></head><body><main>
<p><a href="https://github.com/GordonBeeming/myterm/issues/187">Resolve virtual and parent Kitty placement fidelity</a></p>
<h1>Image pixels and stored grid cells</h1>
<p>A one-pixel square requested at two columns renders as an 18 × 18 square. Its transport resource spans an 18 × 32 cell rectangle, and retains the original native size request. Fresh import paints the same pixels.</p>
<nav role="tablist" aria-label="Rendering scenarios"><button role="tab" id="t-native" aria-controls="native" aria-selected="true">Measured native output</button><button role="tab" id="t-review" aria-controls="review" aria-selected="false">Reviewer's sizing model</button><button role="tab" id="t-bridge" aria-controls="bridge" aria-selected="false">What the harness builds</button><button role="tab" id="t-geometry" aria-controls="geometry" aria-selected="false">Geometry conditions</button></nav>
<section id="native" role="tabpanel" aria-labelledby="t-native"><h2>Both native renders preserve the square</h2><p><code>a=T,f=32,s=1,v=1,i=1,p=1,c=2,C=1</code> leaves height automatic. The following crops show the 18 × 32 grid region enlarged four times; black pixels below the red square remain unpainted.</p><div class="grid"><div class="box"><h3>Uninterrupted client</h3><div class="crop"><img alt="Actual native red square with black padding below" src="data:image/png;base64,REFERENCE"></div></div><div class="box"><h3>Fresh checkpoint import</h3><div class="crop"><img alt="Actual imported native red square with matching black padding below" src="data:image/png;base64,IMPORTED"></div></div></div><p class="facts">Matching decoded RGBA, including padding and subsequent output. The separate natural-width case remains exactly 100 × 1 pixels.</p></section>
<section id="review" role="tabpanel" aria-labelledby="t-review" hidden><h2>The predicted stretch would paint the whole rectangle</h2><div class="diagram" role="img" aria-label="Hypothetical review model paints the full 18 by 32 rectangle"><div class="node"><code>columns = 2<br>rows = 2</code><p>Stored grid: 18 × 32</p></div><span class="edge">review hypothesis →</span><div class="model" aria-hidden="true"></div></div><p>This colored rectangle is a diagram of the review hypothesis, not a native screenshot. It predicts painted height 32. The measured screenshot has painted height 18, so that hypothesis would fail the pixel gate.</p><p>Both explicitly requested dimensions do require letterboxing under the protocol. That shared native bug was confirmed and corrected; the controls check that a square remains square inside a taller rectangle.</p></section>
<section id="bridge" role="tabpanel" aria-labelledby="t-bridge" hidden><h2>The native request survives the transport grid</h2><figure><div class="diagram" role="img" aria-label="Original pixels and original size request cross the checkpoint and enter the native renderer"><div class="node"><strong>Rust retained state</strong><p>Original RGBA: 1 × 1<br>Grid resource: 18 × 32</p><code>width: 2 cells<br>height: auto<br>preserve: true</code></div><span class="edge">checkpoint carries →</span><div class="node"><strong>Native renderer</strong><p>Paints an 18 × 18 square<br>Builds two 16-pixel stripes<br>Leaves the lower padding clear</p></div></div><figcaption class="note">Rust stores image cells and resources; this prototype has no Rust pixel painter.</figcaption></figure><p>A hidden virtual parent retains the child's complete resource without placing visible child cells. Placeholder output later supplies its origin and reveals it. Both native state and rendered pixels are checked before and after import.</p><p>Each protocol H/V offset is limited to a signed 32-bit value. A descendant coordinate can be the sum of up to 32 such offsets, so logical coordinate bounds are wider. Offscreen coordinates allocate no offscreen canvas.</p></section>
<section id="geometry" role="tabpanel" aria-labelledby="t-geometry" hidden><h2>An unwindowed fallback changes cell snapping</h2><table><thead><tr><th>Controlled condition</th><th>Cell width</th><th>Image scale</th><th>Two-column raster</th></tr></thead><tbody><tr><td>Font grid 1×; image 1×</td><td>9 points</td><td>1×</td><td>18 pixels</td></tr><tr><td>Font grid 2×; image 1×</td><td>8.5 points</td><td>1×</td><td>17 pixels</td></tr></tbody></table><p>The font-grid helper falls back to NSScreen when there is no window. Image scale falls back to one. The experiment now declares a coherent 1× headless condition and retains the mixed-scale diagnostic. It does not claim live-window, Retina or device acceptance.</p><p><a href="https://github.com/GordonBeeming/myterm/issues/197">Investigate intermittent native checkpoint raster width</a> remains the separate production gate. This diagnostic gives it a reproducible measurement condition; it is not a release waiver.</p></section>
<footer>Actual native NSView raster capture at controlled 1× geometry. No MyTerm app window was controlled. <a href="https://sw.kovidgoyal.net/kitty/graphics-protocol/#controlling-displayed-image-layout">Kitty layout specification</a>.</footer>
</main><script>const tabs=[...document.querySelectorAll('[role=tab]')];function choose(t){for(const b of tabs){const a=b===t;b.setAttribute('aria-selected',a);b.tabIndex=a?0:-1;document.getElementById(b.getAttribute('aria-controls')).hidden=!a;}}for(const t of tabs){t.onclick=()=>choose(t);t.onkeydown=e=>{let i=tabs.indexOf(t);if(e.key==='ArrowRight')i=(i+1)%tabs.length;else if(e.key==='ArrowLeft')i=(i+tabs.length-1)%tabs.length;else return;e.preventDefault();choose(tabs[i]);tabs[i].focus();};}choose(tabs[0]);</script></body></html>'''.replace('REFERENCE', actual).replace('IMPORTED', imported)
    (HERE/'rendering-review.html').write_text(html)
    target = Path('/Users/gordonbeeming/Developer/artifacts/myterm/kitty-rendering-review.html')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(html)
    print(json.dumps(data))


if __name__ == '__main__':
    main()
