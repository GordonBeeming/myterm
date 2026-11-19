'use strict';
const {readFileSync,writeFileSync}=require('node:fs');
const {join}=require('node:path');
const vm=require('node:vm');
const crypto=require('node:crypto');
const assert=require('node:assert/strict');
const html=readFileSync(join(__dirname,'candidate.html'),'utf8');
const context=vm.createContext({structuredClone});
vm.runInContext(html.match(/<script id="model">([\s\S]*?)<\/script>/)[1]+';globalThis.model=MoveModel;',context);
const M=context.model,results=[];
function check(name,fn){fn();results.push({name,passed:true});}
function run(actions,start=M.initial()){return actions.reduce((s,a)=>M.step(s,a),start);}
function blocked(s,action){const after=M.step(s,action);assert.match(after.trace.at(-1).result,/^Blocked:/);return after;}
const setup=['login','reserve','sourceLogin','approve','prepare','confirm'];
check('normal move commits and activates exactly one next location',()=>{const s=run([...setup,'commit','activate']);assert.equal(s.home,'Beta');assert.equal(s.active,'Beta');assert.equal(s.epoch,1);});
check('destination passkey required',()=>{blocked(M.initial(),'reserve');});
check('source passkey required on normal path',()=>{blocked(run(['login','reserve','approve']),'prepare');});
check('endpoint approval required independently of both passkeys',()=>{blocked(run(['login','reserve','sourceLogin']),'prepare');});
check('occupied destination rejected without changing source location',()=>{const s=blocked(run(['login','occupied']),'reserve');assert.equal(s.home,'Live');assert.equal(s.pending,null);});
check('incompatible destination rejected before reservation',()=>{blocked(run(['login','incompatible']),'reserve');});
check('destination must stage before commit',()=>{blocked(run(['login','reserve','sourceLogin','approve']),'commit');});
check('no activation before ordered commit',()=>{blocked(run(setup),'activate');});
check('source-loss path requires explicit fallback selection',()=>{blocked(run(['sourceDown','login','reserve','approve']),'prepare');});
check('source-loss fallback still requires ordering server',()=>{blocked(run(['sourceDown','login','reserve','fallback','approve','prepare','confirm','authorityDown']),'commit');});
check('source-loss path preserves account anchor and advances location epoch',()=>{const s=run(['sourceDown','login','reserve','fallback','approve','prepare','confirm','commit','activate']);assert.equal(s.anchor,M.initial().anchor);assert.equal(s.epoch,1);assert.equal(s.home,'Beta');});
check('missing-content fallback pauses until explicit acknowledgement',()=>{blocked(run(['sourceDown','login','missing','reserve','fallback','approve']),'prepare');});
check('prepared move can abort before commit',()=>{const s=run([...setup,'cancel']);assert.equal(s.home,'Live');assert.equal(s.pending,null);});
check('abort waits for authority; no unsafe local reservation release',()=>{blocked(run([...setup,'authorityDown']),'cancel');});
check('committed move cannot abort',()=>{blocked(run([...setup,'commit']),'cancel');});
check('lost activation acknowledgement retries same commit',()=>{const s=run([...setup,'commit','destinationDown','activate','commit','destinationDown','activate']);assert.equal(s.epoch,1);assert.equal(s.active,'Beta');assert.equal(s.history.length,1);});
check('retry activation does not extend source TTL',()=>{const s=run([...setup,'commit','activate','advance','activate']);assert.equal(s.forwarding[0].until,14);assert.equal(s.forwarding.length,1);});
check('delayed initial activation does not extend source TTL',()=>{const s=run([...setup,'commit','advance','activate']);assert.equal(s.forwarding[0].until,14);});
check('expired uncommitted ticket cannot commit',()=>{blocked(run([...setup,'advance']),'commit');});
check('concurrent stale predecessor cannot commit',()=>{const s=run(setup);s.pending.previous=-1;blocked(s,'commit');});
check('forwarding follows active chain before expiry',()=>{const s=run([...setup,'commit','activate','chain',...setup,'commit','activate','discover']);assert.equal(s.endpointHome,'Self-hosted');assert.equal(s.endpointEpoch,2);});
check('earlier forwarding expiry remains independent of later move',()=>{let s=run([...setup,'commit','activate','chain']);s.day=7;s=run([...setup,'commit','activate'],s);assert.equal(s.forwarding[0].until,14);assert.equal(s.forwarding[1].until,21);});
check('expired forwarding blocks automatic discovery',()=>{blocked(run([...setup,'commit','activate','advance']),'discover');});
check('manual verified discovery works after forwarding expiry',()=>{const s=run([...setup,'commit','activate','advance','manual']);assert.equal(s.endpointHome,'Beta');});
check('final manifest confirmation is separate from export authorization',()=>{blocked(run(['login','reserve','sourceLogin','approve','prepare']),'commit');});
check('returning old source remains fenced after fallback',()=>{blocked(run(['sourceDown','login','reserve','fallback','approve','prepare','confirm','commit','activate','sourceDown']),'sourceWrite');});
check('source stays fenced during authority outage after prepare',()=>{blocked(run([...setup,'authorityDown']),'sourceWrite');});
check('original source remains fenced after starting a later move',()=>{blocked(run([...setup,'commit','activate','chain']),'sourceWrite');});
check('ordered abort resumes writes at original source',()=>{const s=M.step(run([...setup,'cancel']),'sourceWrite');assert.doesNotMatch(s.trace.at(-1).result,/^Blocked:/);});
check('prepared source is fenced while authority is reachable',()=>{blocked(run(setup),'sourceWrite');});
check('moving back to original origin still advances returning endpoint checkpoint',()=>{const s=run([...setup,'commit','activate','chain',...setup,'commit','activate','chain',...setup,'commit','activate','discover']);assert.equal(s.endpointEpoch,3);assert.equal(s.endpointHome,'Live');});
check('acknowledged missing-content fallback can complete',()=>{const s=run(['sourceDown','missing','login','reserve','fallback','approve','acknowledge','prepare','confirm','commit','activate']);assert.equal(s.home,'Beta');assert.equal(s.active,'Beta');});
check('loss acknowledgement cannot override missing security state',()=>{blocked(run(['sourceDown','missing','missingSecurity','login','reserve','fallback','approve','acknowledge']),'prepare');});
check('changed transfer invalidates content-loss acknowledgement and final approval',()=>{const s=run(['sourceDown','missing','login','reserve','fallback','approve','acknowledge','prepare','confirm','missing']);assert.equal(s.pending.lossAcknowledged,false);assert.equal(s.pending.prepared,false);assert.equal(s.approved,false);});
check('ordinary source-online path cannot acknowledge incomplete content',()=>{blocked(run(['missing','login','reserve','sourceLogin','approve']),'acknowledge');});
check('cancelled ticket does not carry content-loss consent to a new reservation',()=>{const s=run(['sourceDown','missing','login','reserve','fallback','approve','acknowledge','cancel','reserve']);assert.equal(s.pending.lossAcknowledged,false);});
check('committed transfer cannot be changed by missing-content toggle',()=>{const s=blocked(run([...setup,'commit']),'missing');assert.equal(s.pending.committed,true);});
check('restaging preserves source fence until ordered abort',()=>{blocked(run([...setup,'missing']),'sourceWrite');});
check('security-state change invalidates content-loss acknowledgement',()=>{const s=run(['sourceDown','missing','login','reserve','fallback','approve','acknowledge','prepare','missingSecurity']);assert.equal(s.pending.lossAcknowledged,false);});
check('all guided scenarios execute without exceptions',()=>{M.scenarios.forEach(s=>run(s.steps));});
check('actions do not mutate preceding state',()=>{const s=run(setup),copy=JSON.stringify(s);M.step(s,'commit');assert.equal(JSON.stringify(s),copy);});

// This fixture signs a bounded fixed-field body. It is not a production wire parser.
const keys=Object.fromEntries(['destination','destination2','authority','endpoint','attacker'].map(n=>[n,crypto.generateKeyPairSync('ed25519')]));
const canonical=value=>{assert(value&&typeof value==='object'&&!Array.isArray(value),'flat body required');assert(Object.values(value).every(v=>typeof v==='string'||(typeof v==='number'&&Number.isSafeInteger(v))),'only flat string/integer fields supported');return JSON.stringify(value,Object.keys(value).sort());};
const digest=value=>crypto.createHash('sha256').update(canonical(value)).digest('hex');
const sign=(body,who)=>({body,signature:crypto.sign(null,Buffer.from(canonical(body)),keys[who].privateKey).toString('base64')});
const verify=(message,who)=>crypto.verify(null,Buffer.from(canonical(message.body)),keys[who].publicKey,Buffer.from(message.signature,'base64'));
const fingerprint=who=>crypto.createHash('sha256').update(keys[who].publicKey.export({type:'spki',format:'der'})).digest('hex');
const destinations=new Map([['https://beta.example','destination'],['https://self.example','destination2']]);
const ticket={purpose:'myterm-move-ticket-prototype-v0',id:crypto.randomUUID(),anchor:'account-anchor',previous:'checkpoint-42',source:'https://live.example',destination:'https://beta.example',relayKey:fingerprint('destination'),destinationAccount:'empty-account-9',transferKey:'destination-hpke-public-key-fixture',features:'required-features-hash',expires:100};
const signedTicket=sign(ticket,'destination');
const exportGrant=sign({purpose:'myterm-move-export-prototype-v0',issuer:fingerprint('endpoint'),ticket:digest(ticket),previous:ticket.previous,nonce:crypto.randomUUID(),expires:100},'endpoint');
function validateExport(grant,t,now){
 assert(verify(grant,'endpoint'),'export signature invalid');
 assert.equal(grant.body.purpose,'myterm-move-export-prototype-v0','wrong export purpose');
 assert.equal(grant.body.issuer,fingerprint('endpoint'),'wrong export issuer');
 assert.equal(grant.body.ticket,digest(t.body),'wrong export ticket');
 assert.equal(grant.body.previous,t.body.previous,'wrong export predecessor');
 assert(now<=grant.body.expires,'export expired');
}
check('phase-one export grant signs exact ticket and predecessor',()=>validateExport(exportGrant,signedTicket,50));
check('phase-one export grant cannot be substituted onto another ticket',()=>{assert.throws(()=>validateExport(exportGrant,sign({...ticket,id:'another-ticket'},'destination'),50),/wrong export ticket/);});
check('phase-one export grant has an independently checked expiry',()=>{assert.throws(()=>validateExport(exportGrant,signedTicket,101),/export expired/);});
const intent={purpose:'myterm-move-approval-prototype-v0',issuer:fingerprint('endpoint'),ticket:digest(ticket),manifest:'ciphertext-manifest-hash',anchor:ticket.anchor,previous:ticket.previous};
const approval=sign(intent,'endpoint');
const prepared=sign({purpose:'myterm-move-prepared-prototype-v0',ticket:digest(ticket),manifest:intent.manifest},'destination');
const fields=Object.keys(ticket).sort();
function validateTicket(t,expected,now){
 assert.deepEqual(Object.keys(t.body).sort(),fields);
 const signer=destinations.get(t.body.destination);assert(signer,'unknown destination');
 assert.equal(t.body.relayKey,fingerprint(signer),'destination key binding mismatch');
 assert(verify(t,signer),'destination signature invalid');
 assert.equal(t.body.anchor,expected.anchor);assert.equal(t.body.previous,expected.previous);
 assert.equal(t.body.source,expected.source);assert.equal(t.body.destination,expected.destination);
 assert.equal(t.body.relayKey,expected.relayKey);assert.equal(t.body.destinationAccount,expected.destinationAccount);
 assert.equal(t.body.transferKey,expected.transferKey);assert.equal(t.body.features,expected.features);
 assert.equal(t.body.purpose,ticket.purpose);assert(now<=t.body.expires,'ticket expired');
}
function validateBundle(t,a,p,expected=ticket,now=50){
 validateTicket(t,expected,now);assert(verify(a,'endpoint'),'endpoint signature invalid');assert(verify(p,destinations.get(t.body.destination)),'prepared signature invalid');
 assert.equal(a.body.issuer,fingerprint('endpoint'),'unrecognized endpoint issuer');
 assert.equal(a.body.purpose,intent.purpose);assert.equal(a.body.ticket,digest(t.body));
 assert.equal(a.body.anchor,t.body.anchor);assert.equal(a.body.previous,t.body.previous);
 assert.equal(p.body.purpose,'myterm-move-prepared-prototype-v0');
 assert.equal(p.body.ticket,digest(t.body));assert.equal(p.body.manifest,a.body.manifest);
}
check('real Ed25519 signatures verify bound ticket, approval and prepared receipt',()=>validateBundle(signedTicket,approval,prepared));
for(const field of fields){
 check('ticket tampering rejected: '+field,()=>{const altered=structuredClone(signedTicket);altered.body[field]=typeof altered.body[field]==='number'?101:'substituted';assert.throws(()=>validateTicket(altered,ticket,50));});
}
check('unknown ticket fields rejected',()=>{assert.throws(()=>validateTicket(sign({...ticket,admin:true},'destination'),ticket,50));});
check('attacker signature cannot replace destination identity',()=>{assert.throws(()=>validateTicket(sign(ticket,'attacker'),ticket,50));});
check('valid destination signature cannot substitute account context',()=>{assert.throws(()=>validateTicket(sign({...ticket,anchor:'other-account'},'destination'),ticket,50),/other-account/);});
check('ticket expiry checked separately from cryptographic validity',()=>{assert.throws(()=>validateTicket(signedTicket,ticket,101));});
check('approval from different ticket rejected',()=>{assert.throws(()=>validateBundle(signedTicket,sign({...intent,ticket:'different-ticket'},'endpoint'),prepared));});
check('prepared manifest substitution rejected',()=>{assert.throws(()=>validateBundle(signedTicket,approval,sign({...prepared.body,manifest:'other'},'destination')));});
const journal={anchor:'account-anchor',head:'checkpoint-42',home:'https://live.example',features:'required-features-hash',epoch:0,commits:new Map(),members:new Set([fingerprint('endpoint')])};
function commit(t,a,p,now=50){
 const expected={...t.body,anchor:journal.anchor,features:journal.features};
 // Verify signatures/bindings before journal lookup. A committed retry remains
 // retrievable after ticket expiry, while a new commit checks current time below.
 validateBundle(t,a,p,expected,Number.MIN_SAFE_INTEGER);
 assert(journal.members.has(a.body.issuer),'issuer is not a current member');
 const request=digest(t.body),old=journal.commits.get(request);
 if(old){assert.equal(old.body.approval,digest(a.body),'same ticket reused with a different approval');assert.equal(old.body.prepared,digest(p.body),'same ticket reused with a different prepared transfer');return old;}
 assert(now<=t.body.expires,'ticket expired before authority commit');
 assert.equal(t.body.previous,journal.head,'stale or conflicting predecessor');
 assert.equal(t.body.source,journal.home,'incorrect source location');
 const receipt=sign({purpose:'myterm-location-commit-prototype-v0',anchor:t.body.anchor,previous:journal.head,ticket:request,approval:digest(a.body),prepared:digest(p.body),destination:t.body.destination,relayKey:t.body.relayKey,destinationAccount:t.body.destinationAccount,epoch:journal.epoch+1},'authority');
 journal.head=digest(receipt.body);journal.home=t.body.destination;journal.epoch++;journal.commits.set(request,receipt);return receipt;
}
let receipt;
check('authority signs commit binding ticket, approval and prepared receipt',()=>{receipt=commit(signedTicket,approval,prepared);assert(verify(receipt,'authority'));assert.equal(receipt.body.ticket,digest(ticket));});
check('same request replay returns same signed commit without advancing epoch',()=>{assert.equal(commit(signedTicket,approval,prepared),receipt);assert.equal(journal.epoch,1);});
check('committed retry survives original ticket expiry',()=>{assert.equal(commit(signedTicket,approval,prepared,101),receipt);});
check('same ticket cannot silently retry a different transfer manifest',()=>{const a=sign({...intent,manifest:'changed-manifest'},'endpoint');const p=sign({...prepared.body,manifest:'changed-manifest'},'destination');assert.throws(()=>commit(signedTicket,a,p));assert.equal(journal.epoch,1);});
check('second valid competing destination cannot use consumed predecessor',()=>{const t=sign({...ticket,id:crypto.randomUUID(),destination:'https://self.example',relayKey:fingerprint('destination2')},'destination2');const a=sign({...intent,ticket:digest(t.body)},'endpoint');const p=sign({...prepared.body,ticket:digest(t.body)},'destination2');assert.throws(()=>commit(t,a,p),/stale or conflicting predecessor/);assert.equal(journal.epoch,1);});
function nextBundle(overrides={}){const t=sign({...ticket,id:crypto.randomUUID(),source:journal.home,previous:journal.head,...overrides},'destination');const a=sign({...intent,anchor:t.body.anchor,previous:t.body.previous,ticket:digest(t.body)},'endpoint');const p=sign({...prepared.body,ticket:digest(t.body)},'destination');return [t,a,p];}
check('authority checks clock independently of signed ticket validity',()=>{assert.throws(()=>commit(...nextBundle(),101),/ticket expired before authority commit/);});
check('authority rejects a fully signed bundle for another account',()=>{assert.throws(()=>commit(...nextBundle({anchor:'other-account'})),/other-account/);});
check('authority rejects a fully signed bundle naming wrong source',()=>{assert.throws(()=>commit(...nextBundle({source:'https://wrong.example'})),/incorrect source location/);});
check('destination ticket pins its actual signer key',()=>{assert.throws(()=>validateTicket(sign({...ticket,relayKey:fingerprint('attacker')},'destination'),ticket,50),/destination key binding mismatch/);});
check('approval issuer is explicit and checked',()=>{assert.throws(()=>validateBundle(signedTicket,sign({...intent,issuer:fingerprint('attacker')},'endpoint'),prepared),/unrecognized endpoint issuer/);});
check('authority rechecks current fixture membership',()=>{journal.members.clear();assert.throws(()=>commit(...nextBundle()),/issuer is not a current member/);journal.members.add(fingerprint('endpoint'));});
check('nested values cannot silently lose signed fields',()=>{assert.throws(()=>canonical({outer:{hidden:'value'}}),/only flat/);});
check('commit content tampering fails actual authority signature',()=>{assert.equal(verify({...receipt,body:{...receipt.body,destination:'https://attacker.example'}},'authority'),false);});
check('wrong authority signature rejected',()=>{assert.equal(verify(sign(receipt.body,'attacker'),'authority'),false);});
const activation=sign({purpose:'myterm-move-active-prototype-v0',commit:digest(receipt.body),anchor:journal.anchor,destination:journal.home},'destination');
function discover(commitMessage,activeMessage,checkpoint={head:'checkpoint-42',epoch:0}){
 assert(verify(commitMessage,'authority'),'untrusted location authority');
 assert.equal(commitMessage.body.anchor,journal.anchor,'account mismatch');
 assert.equal(commitMessage.body.previous,checkpoint.head,'nonextending history');
 assert.equal(commitMessage.body.epoch,checkpoint.epoch+1,'stale location epoch');
 const signer=destinations.get(commitMessage.body.destination);assert(signer,'unknown relay');assert.equal(commitMessage.body.relayKey,fingerprint(signer),'committed destination key mismatch');
 assert(verify(activeMessage,signer),'untrusted activation');
 assert.equal(activeMessage.body.purpose,'myterm-move-active-prototype-v0');
 assert.equal(activeMessage.body.commit,digest(commitMessage.body),'wrong activated commit');
 assert.equal(activeMessage.body.anchor,commitMessage.body.anchor);
 assert.equal(activeMessage.body.destination,commitMessage.body.destination);
 return commitMessage.body.destination;
}
check('returning endpoint verifies actual authority and destination activation signatures',()=>{assert.equal(discover(receipt,activation),'https://beta.example');});
check('forwarding cannot substitute an unknown authority',()=>{assert.throws(()=>discover(sign(receipt.body,'attacker'),activation),/untrusted location authority/);});
check('forwarding cannot replay a stale checkpoint extension',()=>{assert.throws(()=>discover(receipt,activation,{head:journal.head,epoch:1}),/nonextending history/);});
check('forwarding cannot substitute activation from another commit',()=>{assert.throws(()=>discover(receipt,sign({...activation.body,commit:'other'},'destination')),/wrong activated commit/);});
check('discovery rejects committed relay-key substitution',()=>{assert.throws(()=>discover(sign({...receipt.body,relayKey:fingerprint('attacker')},'authority'),activation),/committed destination key mismatch/);});
check('forwarding cannot fake destination activation',()=>{assert.throws(()=>discover(receipt,sign(activation.body,'attacker')),/untrusted activation/);});
const report={runAt:new Date().toISOString(),runtime:process.version,platform:process.platform,arch:process.arch,passed:results.length,total:results.length,checks:results,sourceHash:crypto.createHash('sha256').update(html).digest('hex'),harnessHash:crypto.createHash('sha256').update(readFileSync(__filename)).digest('hex'),limits:['In-memory reference model; no crash persistence or real distributed relay transaction','Real Ed25519 signatures only; passkey assertions, transfer encryption and native transports are fixtures; membership is a fixed-key set','No real terminal process, endpoint membership integration or complete wire-parser validation','Missing-content fallback accepted with explicit acknowledgement; security-state gate is a fixture, not credential reconciliation; no production security claim']};
if(process.argv[2])writeFileSync(process.argv[2],JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({passed:report.passed,total:report.total,runtime:report.runtime,platform:report.platform,arch:report.arch}));
