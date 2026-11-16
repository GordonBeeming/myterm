const {chromium}=require('playwright');
const fs=require('node:fs');
const path=require('node:path');
(async()=>{
 const browser=await chromium.launch({headless:true});const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
 const out=process.argv[3]||'/private/tmp';fs.mkdirSync(out,{recursive:true});const file=path.resolve(process.argv[2]);await page.goto('file://'+file);
 const checks=[];
 for(const width of [1920,800]){
  await page.setViewportSize({width,height:1080});
  const tabs=page.getByRole('tab');const count=await tabs.count();
  for(let i=0;i<count;i++){
   await tabs.nth(i).click();
   for(let j=0;j<30;j++){
    if((await page.locator('#step-status').innerText()).startsWith('Walkthrough complete'))break;
    await page.locator('#next').click();
   }
   const result=await page.evaluate(()=>({horizontal:document.documentElement.scrollWidth>innerWidth,mojibake:/[ÃÂ]|â€|âœ|ï¿½/.test(document.body.innerText),complete:document.getElementById('step-status').textContent.startsWith('Walkthrough complete'),title:document.getElementById('scenario-title').textContent}));
   if(result.horizontal||result.mojibake||!result.complete)throw Error(JSON.stringify(result));checks.push({width,...result});
  }
 }
 await page.setViewportSize({width:1920,height:1080});await page.getByRole('tab').first().click();await page.screenshot({path:path.join(out,'myterm-move-qa.png'),fullPage:true});
 await page.setViewportSize({width:800,height:1080});await page.screenshot({path:path.join(out,'myterm-move-qa-narrow.png'),fullPage:true});
 // All page text pairs use these six colors; composited surfaces are opaque.
 function luminance(hex){const c=hex.match(/\w\w/g).map(h=>parseInt(h,16)/255).map(c=>c<=.04045?c/12.92:((c+.055)/1.055)**2.4);return .2126*c[0]+.7152*c[1]+.0722*c[2];}
 const pairs=[['0f172a','f8fafc'],['0f172a','ffffff'],['0f172a','ecfeff'],['64748b','ffffff'],['64748b','f8fafc'],['164e63','ffffff'],['164e63','f8fafc'],['ffffff','0e7490'],['0f172a','f1f5f9']].map(([a,b])=>{const x=luminance(a),y=luminance(b);return {fg:a,bg:b,ratio:(Math.max(x,y)+.05)/(Math.min(x,y)+.05)}});
 if(pairs.some(x=>x.ratio<4.5))throw Error('Contrast failed: '+JSON.stringify(pairs));if(errors.length)throw Error(errors.join('\n'));
 fs.writeFileSync(path.join(out,'myterm-move-visual-qa.json'),JSON.stringify({checks,pairs,errors},null,2));console.log(JSON.stringify({scenarios:checks.length,errors,minimumContrast:Math.min(...pairs.map(p=>p.ratio))}));await browser.close();
})().catch(e=>{console.error(e);process.exitCode=1});
