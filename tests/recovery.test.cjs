const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {JSDOM}=require('jsdom');
const source=fs.readFileSync(path.join(__dirname,'../web/recovery.js'),'utf8');
const payload=name=>({_meta:{savedFrom:'org'},schema:{objects:[]},loadedRecords:[],drafts:[{tempId:'draft',objectName:'Account',values:{Name:name}}],associations:[]});
function server(){
  const rows=new Map(),calls=[];let failWrite=false,failPeek=false;
  return {rows,calls,set failWrite(v){failWrite=v;},set failPeek(v){failPeek=v;},async request(op,b){
    calls.push({op,body:structuredClone(b)});const r=rows.get(b.key);
    if(op==='peek'){if(failPeek)throw Error('Offline');return {available:!!r&&!r.cleared,sequence:r?.sequence,savedAt:0};}
    if(op==='write'){
      if(failWrite)throw Error('Quota temporarily unavailable');
      if(r&&(r.writer!==b.writer||r.cleared))throw Error('RECOVERY_STALE: another tab');
      rows.set(b.key,{...structuredClone(b),savedAt:0});return {savedAt:0};
    }
    if(op==='restore'){if(!r||r.sequence!==b.sequence)throw Error('RECOVERY_STALE: newer changes');r.writer=b.writer;return {payload:structuredClone(r.payload),savedAt:0};}
    if(op==='discard'){
      if(r&&r.writer!==b.writer&&!b.reviewed)throw Error('RECOVERY_STALE: another tab');
      rows.set(b.key,{...r,cleared:true});return {ok:true};
    }
    throw Error('Unexpected operation '+op);
  }};
}
function browser(s,initialKey=null,options={}){
  const dom=new JSDOM('<body></body>',{runScripts:'outside-only',url:'https://test.invalid'}),w=dom.window;
  let now=10000,stored=initialKey,blocked=false,busy=false,readonly=false,restores=[],ends=[],snapshot={id:'draft-1',isDraft:true,payload:payload('Unsaved')};
  const timers=[];w.setInterval=fn=>timers.push(fn);w.Date.now=()=>now;
  w.OrgLoomNativeRecoveryHost={getKey:()=>stored,setKey:v=>{if(options.blockStorage)throw Error('Browser storage blocked');assert.ok(v===null||/^[a-f0-9]{64}$/.test(v));stored=v;},request:(...a)=>s.request(...a),blocked:()=>blocked,session:()=>undefined,adopt:()=>{},end:m=>ends.push(m)};
  w.eval(source);const api=w.OrgLoomNativeRecovery;
  const mounted=api.mount({ready:options.ready||Promise.resolve(),snapshot:()=>snapshot,busy:()=>busy,readOnly:()=>readonly,restore:async d=>{restores.push(d);snapshot={id:'draft-1',isDraft:true,payload:d.payload};},confirm:options.confirm||(()=>Promise.resolve(true)),toast:()=>{}});
  return {dom,w,api,mounted,restores,ends,get key(){return stored;},set blocked(v){blocked=v;},set busy(v){busy=v;},set readonly(v){readonly=v;},set snapshot(v){snapshot=v;},edit(name){snapshot.payload=payload(name);},async tick(ms=2500){now+=ms;await timers[0]();},async checkpoint(){await this.tick();await this.tick();}};
}
test('unsaved records debounce to one checkpoint, retain only an identifier, and restore after refresh',async()=>{
  const s=server(),a=browser(s);await a.mounted;
  await a.tick();assert.equal(s.calls.length,0);
  await a.tick();const key=a.key;assert.match(key,/^[a-f0-9]{64}$/);assert.equal(s.rows.size,1);
  a.edit('Updated');await a.checkpoint();assert.equal(s.rows.size,1);assert.equal(s.rows.get(key).payload.drafts[0].values.Name,'Updated');
  const b=browser(s,key);await b.mounted;assert.equal(await b.api.ready(),true);assert.equal(b.restores[0].payload.drafts[0].values.Name,'Updated');
  assert.equal(b.w.sessionStorage.length,0);assert.equal(b.w.localStorage.length,0);
  a.edit('Stale');await a.checkpoint();assert.equal(a.ends.length,1);assert.equal(s.rows.get(key).payload.drafts[0].values.Name,'Updated');
  a.dom.window.close();b.dom.window.close();
});
test('a failed replacement preserves the last confirmed snapshot and retries after backoff',async()=>{
  const s=server(),a=browser(s);await a.mounted;await a.checkpoint();const key=a.key;
  s.failWrite=true;a.edit('Newer');await a.checkpoint();assert.equal(s.rows.get(key).payload.drafts[0].values.Name,'Unsaved');assert.match(a.w.document.body.textContent,/Save before refreshing/);
  const calls=s.calls.length;await a.tick();assert.equal(s.calls.length,calls);
  s.failWrite=false;await a.tick(31000);assert.equal(s.rows.get(key).payload.drafts[0].values.Name,'Newer');a.dom.window.close();
});
test('discard retires an in-flight checkpoint and does not recreate it on an empty canvas',async()=>{
  const s=server(),a=browser(s);await a.mounted;await a.checkpoint();const key=a.key;
  await a.api.discard();a.snapshot=null;await a.tick();assert.equal(a.key,null);assert.equal(s.rows.get(key).cleared,true);a.dom.window.close();
});
test('boot waits for schema and the restore decision before checkpointing',async()=>{
  const s=server(),a=browser(s);await a.mounted;await a.checkpoint();
  let decide;const b=browser(s,a.key,{confirm:()=>new Promise(r=>{decide=r;})});
  await new Promise(r=>setImmediate(r));assert.ok(decide);assert.equal(s.calls.at(-1).op,'peek');
  decide(false);await b.mounted;assert.equal(await b.api.ready(),false);assert.equal(b.key,null);assert.equal(s.calls.at(-1).body.reviewed,true);
  a.dom.window.close();b.dom.window.close();
});
test('failed lookup keeps the pointer and never overwrites existing recovery',async()=>{
  const s=server(),a=browser(s);await a.mounted;await a.checkpoint();s.failPeek=true;
  const b=browser(s,a.key);await b.mounted;await b.checkpoint();assert.equal(b.key,a.key);assert.equal(s.calls.filter(c=>c.op==='write').length,1);assert.match(b.w.document.body.textContent,/could not be restored/);a.dom.window.close();b.dom.window.close();
});
test('saving and uploading cannot race checkpoint writes; new edits resume after applied results',async()=>{
  const s=server(),a=browser(s);await a.mounted;await a.checkpoint();let key=a.key;
  await a.api.beforeSave();a.edit('Saving');await a.checkpoint();assert.equal(s.rows.get(key).payload.drafts[0].values.Name,'Unsaved');
  await a.api.saved();a.api.captureSaved();await new Promise(r=>setImmediate(r));await a.checkpoint();assert.equal(a.key,null);
  a.edit('Edit after save');await a.checkpoint();key=a.key;assert.ok(key);
  a.blocked=true;await a.api.beforeUpload();assert.equal(a.key,null);assert.equal(s.rows.get(key).cleared,true);
  a.blocked=false;a.edit('Uploaded result');await a.checkpoint();assert.equal(a.key,null);
  a.api.uploadStateApplied();await a.checkpoint();assert.ok(a.key);assert.equal(s.rows.get(a.key).payload.drafts[0].values.Name,'Uploaded result');a.dom.window.close();
});
test('read-only and migration/loading states do not create checkpoints',async()=>{
  const s=server(),a=browser(s);await a.mounted;a.readonly=true;await a.checkpoint();assert.equal(s.calls.length,0);a.readonly=false;a.busy=true;await a.checkpoint();assert.equal(s.calls.length,0);a.dom.window.close();
});
test('blocked session storage never writes an unreachable snapshot or blocks an upload',async()=>{
  const s=server(),a=browser(s,null,{blockStorage:true});await a.mounted;await a.checkpoint();assert.equal(s.calls.length,0);assert.equal(a.key,null);
  await a.api.beforeUpload();assert.equal(s.calls.length,0);a.dom.window.close();
});
