/* Throwaway protocol model. Security decisions are supplied by a fixture adapter.
   No network, disk, native process or cryptographic implementation lives here. */
const LayoutPrototype = (() => {
  const copy = x => JSON.parse(JSON.stringify(x));
  const canonical = x => x === null || typeof x !== 'object' ? JSON.stringify(x) : Array.isArray(x) ? '['+x.map(canonical).join(',')+']' : '{'+Object.keys(x).sort().map(k=>JSON.stringify(k)+':'+canonical(x[k])).join(',')+'}';
  const limits = {operations:10000, bytes:8*1024*1024, historyDays:30};
  const idOK=x=>typeof x==='string'&&/^[a-z][a-z0-9-]{0,63}$/.test(x)&&!['constructor','prototype','__proto__'].includes(x);
  function valid(o){
    if(!o||typeof o!=='object'||Array.isArray(o)||Object.keys(o).some(k=>!['id','issuer','account','epoch','deps','clock','kind','target','fields','day'].includes(k)))return false;
    if(!idOK(o.issuer)||!idOK(o.account)||!idOK(o.target)||typeof o.id!=='string'||!new RegExp('^'+o.issuer+':[1-9][0-9]{0,8}$').test(o.id))return false;
    if(![o.epoch,o.clock,o.day].every(Number.isSafeInteger)||o.epoch<1||o.clock<1||o.day<0)return false;
    if(!Array.isArray(o.deps)||o.deps.length>10000||!o.deps.every(x=>typeof x==='string'&&/^[a-z][a-z0-9-]{0,63}:[1-9][0-9]{0,8}$/.test(x)))return false;
    const f=o.fields;
    if(!f||typeof f!=='object'||Array.isArray(f)||Object.keys(f).length>6)return false;
    const allowed={create:['type','name','parent','server','incarnation'],set:['name','parent'],delete:['server','incarnation','confirmed']}[o.kind];
    if(!allowed||Object.keys(f).some(k=>!allowed.includes(k))||Object.values(f).some(v=>v!==null&&!['string','boolean'].includes(typeof v)||typeof v==='string'&&v.length>1024))return false;
    if('parent'in f&&f.parent!==null&&!idOK(f.parent))return false;
    if('name'in f&&typeof f.name!=='string')return false;
    if('server'in f&&f.server!==null&&!idOK(f.server))return false;
    if('incarnation'in f&&f.incarnation!==null&&!idOK(f.incarnation))return false;
    if(o.kind==='create'&&(typeof f.name!=='string'||!['account','folder','workspace','pane','content'].includes(f.type)||(f.type==='account'&&o.target!=='account')||(f.type!=='account'&&!idOK(f.parent))||(f.type==='content'&&(!idOK(f.server)||!idOK(f.incarnation)))))return false;
    if(o.kind==='set'&&('parent'in f&&f.parent===null))return false;
    if(o.kind==='delete'&&f.confirmed!==true)return false;
    return canonical(o).length<=65536;
  }
  function initial() {
    return {account:'personal-a', epoch:1, members:['mac','phone','server-a','server-b'], knownIssuers:['mac','phone','server-a','server-b'], ops:[], pending:[], rejected:[], conflictObserved:{}, checkpointedConflicts:[], frozen:[], durable:[], outbox:[], receipts:[], day:0, activeClient:'mac', connectionCounter:1, reconciledNonces:{}, connections:{'server-a':{connected:true,authorized:true,nonce:'server-a-1'},'server-b':{connected:true,authorized:true,nonce:'server-b-1'}},selection:{mac:'term-a',phone:'term-b'}, runtimes:[{id:'term-a',server:'server-a',incarnation:'run-a',live:true,stoppedBy:null},{id:'term-b',server:'server-b',incarnation:'run-b',live:true,stoppedBy:null}], channel:{connected:true,authorized:true,complete:true,rollback:false,nonce:'join-1',account:'personal-a',epoch:1,serverMember:true}, report:{status:'idle',fresh:true}, confirmation:false, note:'Both terminals belong to the same workspace.'};
  }
  function op(s,issuer,kind,target,fields={}) {
    const own=s.ops.filter(o=>o.issuer===issuer), n=own.length+1;
    return {id:issuer+':'+n,issuer,account:s.account,epoch:s.epoch,deps:s.ops.map(o=>o.id).sort(),clock:1+Math.max(0,...s.ops.map(o=>o.clock)),kind,target,fields:copy(fields),day:s.day};
  }
  function ingest(s,o,verified=true) {
    s=copy(s);
    if(!valid(o)){s.note='Rejected malformed or oversized operation before acknowledgment.';return s;}
    if(!verified||!s.knownIssuers.includes(o.issuer)){s.note='Unauthenticated or unknown issuer dropped without retaining a payload.';return s;}
    const used=()=>canonical([s.ops,s.pending,s.rejected]).length;
    const localBuffer=()=>[...s.pending,...s.rejected.map(r=>r.payload)].filter(p=>p.issuer===o.issuer);
    const canBuffer=()=>localBuffer().length<32&&canonical(localBuffer()).length+canonical(o).length+256<=65536&&used()+canonical(o).length+256<=limits.bytes;
    const reject = reason => {if(!s.rejected.some(r=>canonical(r.payload)===canonical(o))&&canBuffer())s.rejected.push({id:o.id,reason,payload:copy(o)});else s.note='Recovery storage full or already recorded: no new acknowledgment; sender retains original.';return s;};
    const old=s.ops.find(p=>p.id===o.id);
    if(old&&canonical(old)===canonical(o))return s;
    if(o.account!==s.account||o.epoch!==s.epoch||!s.members.includes(o.issuer))return reject('Account/current known membership rejected');
    if(s.frozen.includes(o.issuer))return reject('Issuer stream is frozen');
    if(old){s.frozen.push(o.issuer);return reject('Issuer equivocation: freeze this stream');}
    const buffered=s.pending.find(p=>p.id===o.id);
    if(buffered){if(canonical(buffered)!==canonical(o)){s.frozen.push(o.issuer);return reject('Buffered issuer equivocation: freeze this stream');}return s;}
    if(!['create','set','delete'].includes(o.kind)||!o.target||!o.fields||!Array.isArray(o.deps)||new Set(o.deps).size!==o.deps.length)return reject('Invalid operation');
    const deps=o.deps.map(id=>s.ops.find(p=>p.id===id));
    if(deps.some(p=>!p)){
      if(canBuffer()){s.pending.push(copy(o));s.note='Missing dependencies buffered without acknowledgment; fetch and retry.';}
      else s.note='Dependency buffer full: refuse acknowledgment; sender retains original.';
      return s;
    }
    const own=s.ops.filter(p=>p.issuer===o.issuer);
    if(o.id!==o.issuer+':'+(own.length+1)||own.some(p=>!o.deps.includes(p.id)))return reject('Invalid issuer chain');
    if(o.clock!==1+Math.max(0,...deps.map(p=>p.clock)))return reject('Invalid logical clock');
    if(s.ops.length>=limits.operations||used()+canonical(o).length>limits.bytes){s.note='Storage budget: refuse acknowledgment, retain unsent intent';return s;}
    s.ops.push(copy(o));s.ops.sort((a,b)=>a.clock-b.clock||(a.id<b.id?-1:a.id>b.id?1:0));
    s.durable.push(o.id);
    for(const h of project(s).history){const key=conflictKey(h);if(!(key in s.conflictObserved))s.conflictObserved[key]=s.day;}
    let ready=s.pending.find(p=>p.deps.every(id=>s.ops.some(o=>o.id===id)));
    while(ready){s.pending=s.pending.filter(p=>p.id!==ready.id);s=ingest(s,ready);ready=s.pending.find(p=>p.deps.every(id=>s.ops.some(o=>o.id===id)));}
    return s;
  }
  function seed() {
    let s=initial();
    for(const [target,fields] of [['account',{type:'account',name:'Personal'}],['folder',{type:'folder',parent:'account',name:'Work'}],['workspace',{type:'workspace',parent:'folder',name:'Build'}],['pane',{type:'pane',parent:'workspace',name:'Terminal'}],['term-a',{type:'content',parent:'pane',name:'Mac build',server:'server-a',incarnation:'run-a'}],['term-b',{type:'content',parent:'pane',name:'Second Mac',server:'server-b',incarnation:'run-b'}]])s=ingest(s,op(s,'mac','create',target,fields));
    return s;
  }
  function project(s) {
    const entities=Object.create(null), history=[], deleted=Object.create(null), issues=[],deletions=Object.create(null),collisions=Object.create(null);
    for(const o of s.ops){
      if(o.kind==='delete'){deleted[o.target]=o;(deletions[o.target]||= []).push(o);continue;}
      if(o.kind==='create'){
        if(entities[o.target]){issues.push('Duplicate identity '+o.target);(collisions[o.target]||= [s.ops.find(p=>p.id===entities[o.target].created)]).push(o);continue;}
        entities[o.target]={id:o.target,created:o.id,fields:copy(o.fields),writers:Object.fromEntries(Object.keys(o.fields).map(k=>[k,o.id]))};
      }else if(entities[o.target]){
        const e=entities[o.target];
        for(const [k,v]of Object.entries(o.fields)){
          if(['type','server','incarnation'].includes(k)){issues.push('Immutable field '+k);continue;}
          const prior=s.ops.find(p=>p.id===e.writers[k]);
          if(prior&&!o.deps.includes(prior.id)&&canonical(e.fields[k])!==canonical(v))history.push({target:o.target,field:k,value:copy(e.fields[k]),loser:prior.id,winner:o.id,day:o.day});
          e.fields[k]=copy(v);e.writers[k]=o.id;
        }
      }else issues.push('Unknown identity '+o.target);
    }
    // Tombstones win even over a later create; recovery always uses a new identity.
    for(const id of Object.keys(deleted))if(entities[id]){
      entities[id].deleted=true;
      for(const o of s.ops.filter(o=>o.target===id&&o.kind==='set'&&!deleted[id].deps.includes(o.id)))history.push({target:id,field:'deleted item edit',value:copy(o.fields),loser:o.id,winner:deleted[id].id,day:o.day});
    }
    const allowed={folder:'account',workspace:'folder',pane:'workspace',content:'pane'};
    const repaired=Object.create(null);
    for(const e of Object.values(entities)){
      if(e.deleted)continue;
      let current=e,seen=new Set([e.id]),reason='';
      while(current.fields.parent){
        const p=entities[current.fields.parent];
        if(!p||p.deleted){reason='Missing or deleted ancestor';break;}
        if(seen.has(p.id)){reason='Cyclic structure';break;}
        if(allowed[current.fields.type]!==p.fields.type){reason='Invalid parent type';break;}
        seen.add(p.id);current=p;
      }
      if(collisions[e.id])reason='Conflicting creation identity: preserve evidence, block attachment';
      if(reason){repaired[e.id]=reason;issues.push(e.id+': '+reason);}
    }
    return {entities,deleted,deletions,collisions,history,issues,repaired};
  }
  function edit(s,issuer,target,fields){return ingest(s,op(s,issuer,'set',target,fields));}
  function close(s,target,confirmed=false,commit=true){
    const original=copy(s);s=copy(s);
    if(!project(s).entities[target]||project(s).entities[target].deleted){s.note='No live shared item to close.';return s;}
    const p=project(s),targets=new Set([target]);let changed=true;
    while(changed){changed=false;for(const e of Object.values(p.entities))if(!e.deleted&&!targets.has(e.id)&&targets.has(e.fields.parent)){targets.add(e.id);changed=true;}}
    const serverIds=[...targets].map(id=>p.entities[id]?.fields.server).filter(Boolean);
    const liveReports=s.report.fresh&&serverIds.every(id=>s.connections[id]?.connected&&s.connections[id]?.authorized);
    if((!liveReports||s.report.status!=='idle')&&!confirmed){s.confirmation=true;s.note='Confirm closure: a foreground process may still be running.';return s;}
    const operations=[];
    for(const id of targets){const e=p.entities[id];if(!e||e.deleted)continue;const o=op(s,'mac','delete',id,{server:e.fields.server||null,incarnation:e.fields.incarnation||null,confirmed:true});s=ingest(s,o);if(!s.durable.includes(o.id)){original.note='Close could not be persisted; keep the item visible.';return original;}operations.push(o);}
    if(!commit){s=copy(arguments[0]);s.note='Crash before durable transaction: original layout survives.';return s;}
    for(const o of operations)if(o.fields.server)s.outbox.push({operation:o.id,target:o.target,server:o.fields.server,incarnation:o.fields.incarnation,stage:'local',acceptedDay:null});
    s=repairSelection(s);s.confirmation=false;s.note='Close transaction persisted; affected items disappear immediately. Cleanup continues.';return s;
  }
  function reconcile(s){
    s=copy(s);const c=s.channel,p=project(s);
    s.reconciledNonces={};
    if(s.frozen.length||!c.connected||!c.authorized||!c.complete||c.rollback||!c.nonce||c.account!==s.account||c.epoch!==s.epoch||!c.serverMember){s.note='Preserved all processes: authenticated synchronization is incomplete or unauthorized.';return s;}
    for(const r of s.runtimes){
      const connection=s.connections[r.server];
      if(!connection||!connection.connected||!connection.authorized||!connection.nonce||p.collisions[r.id])continue;
      if(!s.members.includes(r.server))continue;
      s.reconciledNonces[r.server]=connection.nonce;
      const e=p.entities[r.id];
      const d=(p.deletions[r.id]||[]).find(d=>d.fields.server===r.server&&d.fields.incarnation===r.incarnation&&d.fields.confirmed&&s.members.includes(d.issuer)&&d.epoch===s.epoch&&e&&e.fields.server===r.server&&e.fields.incarnation===r.incarnation);
      if(!d)continue;
      if(r.live){r.live=false;r.stoppedBy=d.id;}
      if(!s.receipts.some(x=>x.operation===d.id))s.receipts.push({operation:d.id,target:r.id,incarnation:r.incarnation,nonce:connection.nonce});
      const q=s.outbox.find(q=>q.operation===d.id);if(q)q.stage='terminated';
    }
    s.note='Synchronization completed before attachment; only explicitly deleted runtime instances were terminated.';return s;
  }
  function submit(s,available=true){s=copy(s);for(const q of s.outbox)if(q.stage!=='terminated'){if(available){q.stage='queued';q.acceptedDay=s.day;}else if(q.stage==='local')q.stage='unsubmitted';}s.note=available?'Relay accepted encrypted command fixtures. Acceptance is not termination.':'Submission failed; durable local close intent remains retryable.';return s;}
  function advance(s,days=8){s=copy(s);s.day+=days;for(const q of s.outbox)if(q.stage==='queued'&&s.day-q.acceptedDay>=7)q.stage='expired';s.note='Pending queue expired. Durable state and explicit tombstones remain.';return s;}
  const conflictKey=h=>[h.target,h.field,h.loser,h.winner].join('|');
  function compact(s){
    // The model retains source operations to verify replay, while exposing the
    // proposed checkpoint payload. Production compaction must verify equivalence.
    const p=project(s);
    return {account:s.account,epoch:s.epoch,heads:s.ops.map(o=>o.id),entities:p.entities,tombstones:p.deletions,conflicts:p.history.filter(h=>!s.checkpointedConflicts.includes(conflictKey(h))||s.day-(s.conflictObserved[conflictKey(h)]??s.day)<limits.historyDays),retired:s.ops.filter(o=>o.kind==='delete').map(o=>o.target),note:'Source operations retained in this model; no destructive GC is implemented.'};
  }
  function restart(s){const disk=copy(s);disk.confirmation=false;disk.reconciledNonces={};disk.note='Restart replays the durable transaction and outbox. Live processes survive.';return disk;}
  function repairSelection(s){s=copy(s);const entities=project(s).entities,live=Object.values(entities).filter(e=>e.fields.type==='content'&&!e.deleted).map(e=>e.id).sort();const client=s.activeClient;if(!live.includes(s.selection[client]))s.selection[client]=live[0]||null;return s;}
  function merge(s,other){let result=copy(s);for(const o of other.ops)result=ingest(result,o);return repairSelection(result);}
  function canAttach(s,id){const c=s.channel,p=project(s),e=p.entities[id],r=s.runtimes.find(r=>r.id===id),conn=r&&s.connections[r.server];return Boolean(!s.frozen.length&&!p.collisions[id]&&c.connected&&c.authorized&&c.complete&&!c.rollback&&c.serverMember&&c.account===s.account&&c.epoch===s.epoch&&c.nonce&&conn&&conn.connected&&conn.authorized&&conn.nonce&&s.reconciledNonces[r.server]===conn.nonce&&e&&!e.deleted&&r&&r.live&&r.incarnation===e.fields.incarnation&&s.members.includes(r.server));}
  return {copy,canonical,limits,seed,op,ingest,project,edit,close,reconcile,submit,advance,compact,restart,merge,canAttach,conflictKey};
})();
if(typeof module!=='undefined')module.exports=LayoutPrototype;
