const {chromium}=require('playwright'),fs=require('node:fs'),path=require('node:path');
(async()=>{
 const out=process.argv[2]||'/private/tmp/myterm-layout-qa';fs.mkdirSync(out,{recursive:true});
 const browser=await chromium.launch({headless:true});
 try{
 const page=await browser.newPage(),errors=[],results=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto('file://'+path.resolve(__dirname,'candidate.html'));
 for(const width of [1920,800,390]){
  await page.setViewportSize({width,height:1080});
  const tabs=page.getByRole('tab'),count=await tabs.count();
  for(let i=0;i<count;i++){
   await tabs.nth(i).click();
   if(width===1920&&i===1)await page.screenshot({path:path.join(out,'before-close.png'),fullPage:true});
   for(let j=0;j<15;j++){
    if((await page.locator('#step-status').innerText())==='Walkthrough complete')break;
    await page.locator('#next').click();
   }
   const result=await page.evaluate(()=>{
    const lum=rgb=>{const c=rgb.slice(0,3).map(c=>c/255).map(c=>c<=.04045?c/12.92:((c+.055)/1.055)**2.4);return .2126*c[0]+.7152*c[1]+.0722*c[2];};
    const rgb=s=>(s.match(/[\d.]+/g)||[]).map(Number),bad=[];
    for(const e of document.querySelectorAll('main *')){
     if(!e.getBoundingClientRect().height||![...e.childNodes].some(n=>n.nodeType===3&&n.textContent.trim()))continue;
     const st=getComputedStyle(e),fg=rgb(st.color);let current=e,bg;
     while(current){const color=rgb(getComputedStyle(current).backgroundColor);if(color.length===3||color[3]===1){bg=color;break;}current=current.parentElement;}
     if(!bg)bg=[248,250,252];
     const ratio=(Math.max(lum(fg),lum(bg))+.05)/(Math.min(lum(fg),lum(bg))+.05);
     if(ratio<4.5)bad.push({text:e.textContent.slice(0,50),ratio});
    }
    return {title:document.getElementById('scenario-title').textContent,complete:document.getElementById('step-status').textContent==='Walkthrough complete',horizontal:document.documentElement.scrollWidth>innerWidth,mojibake:/[ÃÂ]|â€|âœ|ï¿½/.test(document.body.innerText),clipped:[...document.querySelectorAll('button,.card')].some(e=>e.scrollWidth>e.clientWidth+2),computedContrastFailures:bad};
   });
   results.push({width,...result});if(!result.complete||result.horizontal||result.mojibake||result.clipped||result.computedContrastFailures.length)throw Error(JSON.stringify(result));
   if(width===1920&&i===1)await page.screenshot({path:path.join(out,'after-close.png'),fullPage:true});
  }
 }
 await page.setViewportSize({width:1920,height:1080});await page.getByRole('tab').nth(3).click();await page.locator('#next').click();await page.locator('#next').click();await page.screenshot({path:path.join(out,'recovered-content.png'),fullPage:true});
 await page.setViewportSize({width:390,height:1080});await page.screenshot({path:path.join(out,'narrow.png'),fullPage:true});
 function lum(hex){const c=hex.match(/\w\w/g).map(h=>parseInt(h,16)/255).map(c=>c<=.04045?c/12.92:((c+.055)/1.055)**2.4);return .2126*c[0]+.7152*c[1]+.0722*c[2];}
 const contrast=[['0f172a','ffffff'],['0f172a','f8fafc'],['0f172a','f1f5f9'],['64748b','ffffff'],['64748b','f8fafc'],['155e75','ffffff'],['155e75','ecfeff'],['164e63','ffffff'],['ffffff','0e7490']].map(([fg,bg])=>({fg,bg,ratio:(Math.max(lum(fg),lum(bg))+.05)/(Math.min(lum(fg),lum(bg))+.05)}));
 if(contrast.some(c=>c.ratio<4.5))throw Error('Contrast failed');if(errors.length)throw Error(errors.join('\n'));
 const report={results,contrast,errors};fs.writeFileSync(path.join(out,'visual-qa.json'),JSON.stringify(report,null,2));console.log(JSON.stringify({views:results.length,errors,minimumContrast:Math.min(...contrast.map(c=>c.ratio))}));
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
