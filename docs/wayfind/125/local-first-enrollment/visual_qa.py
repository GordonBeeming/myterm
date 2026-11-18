"""Check an opened walkthrough through Browser.app without focusing its window."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("page", help="Browser.app page ID opened on the generated walkthrough")
args = parser.parse_args()


def browser(*arguments):
    return subprocess.check_output(["browser", "page", *arguments], text=True)


def evaluate(script):
    return json.loads(browser("eval", args.page, script, "--raw"))


frames_script = """
const frames=[];
for(const name of Object.keys(scenarios)){
  document.querySelector('[data-case="'+name+'"]').click();
  const inspect=()=>({scenario:name,step,overflow:document.documentElement.scrollWidth>innerWidth,
    mojibake:/Ã|Â|â€|âœ|ï¿½/.test(document.body.innerText),
    freeVisible:!document.getElementById('free').hidden});
  frames.push(inspect());
  for(const a of scenarios[name].steps){document.getElementById('next').click();frames.push(inspect())}
  if(name==='free')for(const a of ['approve','join','delete','return','revoke','join']){
    document.querySelector('[data-action="'+a+'"]').click();frames.push(inspect());
  }
}
document.querySelector('[data-case="first"]').click();
return {width:innerWidth,height:innerHeight,frames};
"""
contrast_script = r"""
function lum(s){return s.match(/[\d.]+/g).slice(0,3).map(Number).map(x=>{
  x/=255;return x<=.04045?x/12.92:((x+.055)/1.055)**2.4;
}).reduce((sum,x,i)=>sum+x*[.2126,.7152,.0722][i],0)}
const pairs=[['body','#f8fafc'],['a','#ffffff'],['.tag','#ecfeff'],
  ['button[aria-selected=true]','#0e7490'],['pre','#f1f5f9']];
return pairs.map(([selector,bg])=>{
  const color=getComputedStyle(document.querySelector(selector)).color;
  const div=document.createElement('div');div.style.color=bg;document.body.append(div);
  const back=getComputedStyle(div).color;div.remove();const a=lum(color),b=lum(back);
  return {selector,contrast:(Math.max(a,b)+.05)/(Math.min(a,b)+.05)};
});
"""
browser("reload", args.page)
artifact = Path.home() / "Developer/artifacts/myterm/local-first-enrollment.html"
assert evaluate("return {url:location.href}")["url"] == artifact.as_uri()
page_hash = hashlib.sha256(artifact.read_bytes()).hexdigest()
runs = []
for size in ["1920x1080", "390x844"]:
    browser("resize", args.page, "--viewport", size)
    run = evaluate(frames_script)
    assert all(not x["overflow"] and not x["mojibake"] for x in run["frames"]), run
    assert all(x["freeVisible"] == (x["scenario"] == "free") for x in run["frames"]), run
    runs.append(run)
contrast = evaluate(contrast_script)
assert all(x["contrast"] >= 4.5 for x in contrast), contrast
assert page_hash == hashlib.sha256(artifact.read_bytes()).hexdigest()
result = dict(views=sum(len(x["frames"]) for x in runs), runs=runs, contrast=contrast,
              page_sha256=page_hash)
path = Path(__file__).resolve().parent / "evidence/visual-qa.json"
path.write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(dict(views=result["views"], path=str(path))))
