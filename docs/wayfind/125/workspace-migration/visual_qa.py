"""Verify the discussion page through Browser.app; no keyboard focus is requested."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
JS = r'''function rgb(s){const m=s.match(/[\d.]+/g);return m?m.slice(0,3).map(Number):null}
function lum(c){return c.map(v=>{v/=255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4}).reduce((a,b,i)=>a+b*[.2126,.7152,.0722][i],0)}
let min=100,checked=0;for(const el of document.querySelectorAll('main *')){if(!el.getClientRects().length)continue;if(![...el.childNodes].some(n=>n.nodeType===3&&n.textContent.trim()))continue;let bg=null,p=el;while(p){let c=getComputedStyle(p).backgroundColor;if(c!=='rgba(0, 0, 0, 0)'&&c!=='transparent'){bg=rgb(c);break}p=p.parentElement}if(!bg)bg=[255,255,255];const fg=rgb(getComputedStyle(el).color);if(fg){let a=lum(fg),b=lum(bg);min=Math.min(min,(Math.max(a,b)+.05)/(Math.min(a,b)+.05));checked++}}
return {width:innerWidth,height:innerHeight,overflow:document.documentElement.scrollWidth>innerWidth,mojibake:/Ã|Â|â€|âœ|ï¿½/.test(document.body.innerText),contrast:min,checkedText:checked,state:state};'''


def command(*args):
    return subprocess.check_output(['browser', 'page', *args], text=True)


def evaluate(page, code):
    return json.loads(command('eval', page, code, '--json'))['value']


def run(page):
    observations = []
    for width, height in [(1920,1080),(390,844)]:
        command('resize', page, '--viewport', f'{width}x{height}')
        for scenario in range(9):
            evaluate(page, f'document.querySelectorAll("#tabs button")[{scenario}].click();return true')
            count = evaluate(page, 'return document.querySelectorAll("#steps button").length')
            for step in range(-1, count):
                if step >= 0:
                    evaluate(page, f'document.querySelectorAll("#steps button")[{step}].click();return true')
                result = evaluate(page, JS)
                result.update(scenario=scenario, step=step)
                assert result['width'] == width and result['height'] == height
                assert not result['overflow'] and not result['mojibake'] and result['contrast'] >= 4.5, result
                assert len(result['state']['backups']) <= 5
                assert result['state']['source'].startswith('original bytes')
                observations.append(result)
            expected = scenario not in (6,7,8)
            assert observations[-1]['state']['receipt'] == expected, observations[-1]
        evaluate(page, 'document.querySelectorAll("#tabs button")[1].click();return true')
        command('screenshot', page, '--out', str(HERE / 'evidence' / f'walkthrough-{width}.png'), '--full-page')
    evidence = {'pageSHA256': hashlib.sha256((HERE/'walkthrough.html').read_bytes()).hexdigest(),
                'views':len(observations),'observations':observations,
                'minimumContrast': min(v['contrast'] for v in observations)}
    (HERE/'evidence'/'visual.json').write_text(json.dumps(evidence,indent=2)+'\n')
    print(json.dumps({k:v for k,v in evidence.items() if k!='observations'}))


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('page')
    run(parser.parse_args().page)
