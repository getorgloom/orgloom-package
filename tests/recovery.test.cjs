const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {JSDOM}=require('jsdom');
const source=fs.readFileSync(path.join(__dirname,'../web/recovery.js'),'utf8');
const payload=name=>({_meta:{savedFrom:'org'},schema:{objects:[]},loadedRecords:[],drafts:[{tempId:'draft',objectName:'Account',values:{Name:name}}],associations:[]});
function server(){
  const rows=new Map(),calls=[];let failWrite=false,failPeek=false,stale=false,failRestore=false;
  return {rows,calls,set stale(v){stale=v;},set failRestore(v){failRestore=v;},set failWrite(v){failWrite=v;},set failPeek(v){failPeek=v;},async request(op,b){
    calls.push({op,body:structuredClone(b)});const r=rows.get(b.key);
    if(op==='peek'){if(failPeek)throw Error('Offline');return {available:!!r&&!r.cleared&&!stale,stale,canvasId:r?.canvasId,sequence:r?.sequence,savedAt:0};}
    if(op==='write'){
      if(failWrite)throw Error(typeof failWrite==='string'?failWrite:'Quota temporarily unavailable');
      if(r&&(r.writer!==b.writer||r.cleared))throw Error('RECOVERY_STALE: another tab');
      rows.set(b.key,{...structuredClone(b),savedAt:0});return {savedAt:0};
    }
    if(op==='restore'){if(failRestore||!r||r.sequence!==b.sequence)throw Error('RECOVERY_STALE: newer changes');r.writer=b.writer;return {payload:structuredClone(r.payload),savedAt:0};}
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
  w.OrgLoomNativeRecoveryHost={getKey:()=>stored,setKey:v=>{if(options.blockStorage)throw Error('Browser storage blocked');assert.ok(v===null||/^[a-f0-9]{64}$/.test(v));stored=v;},request:(...a)=>s.request(...a),openSaved:options.openSaved,blocked:()=>blocked,session:()=>undefined,adopt:()=>{},end:m=>ends.push(m)};
  w.eval(source);const api=w.OrgLoomNativeRecovery;
  const mounted=api.mount({ready:options.ready||Promise.resolve(),snapshot:()=>snapshot,busy:()=>busy,readOnly:()=>readonly,restore:async(d,opts)=>{restores.push({...d,saved:opts?.saved});snapshot={id:d.id||'draft-1',versionId:d.versionId,isDraft:!d.id,payload:d.payload};},confirm:options.confirm||(()=>Promise.resolve(true)),toast:()=>{}});
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

test('oversize recovery recommends JSON export because manual save shares the same limit',async()=>{
  const s=server(),a=browser(s);await a.mounted;await a.checkpoint();const key=a.key;
  s.failWrite='Canvas exceeds the 1 MB save and recovery limit.';a.edit('Large edited canvas');await a.checkpoint();
  assert.match(a.w.document.body.textContent,/Export this canvas as JSON before refreshing/);
  assert.doesNotMatch(a.w.document.body.textContent,/Save before refreshing/);
  assert.equal(s.rows.get(key).payload.drafts[0].values.Name,'Unsaved');a.dom.window.close();
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

test('request autosave rebases recovery to the new revision while preserving other local edits',async()=>{
  const s=server(),a=browser(s);await a.mounted;
  a.snapshot={id:'saved-canvas',versionId:'v1',isDraft:false,payload:payload('Other unsaved edit')};
  await a.checkpoint();const previous=a.key;
  await a.api.beforeSave();
  a.snapshot={id:'saved-canvas',versionId:'v2',isDraft:false,payload:payload('Other unsaved edit')};
  await a.api.requestSaved();
  assert.equal(s.rows.get(previous).cleared,true);assert.notEqual(a.key,previous);
  assert.equal(s.rows.get(a.key).versionId,'v2');assert.equal(s.rows.get(a.key).payload.drafts[0].values.Name,'Other unsaved edit');
  a.edit('Next edit');await a.checkpoint();assert.equal(s.rows.get(a.key).payload.drafts[0].values.Name,'Next edit');
  a.dom.window.close();
});

for(const race of [false,true])test(`takeover ${race?'during the restore prompt':'before reload'} opens the saved canvas instead of restoring stale work`,async()=>{
  const s=server(),a=browser(s);await a.mounted;
  a.snapshot={id:'saved-canvas',versionId:'v1',isDraft:false,payload:payload('Old unsaved work')};await a.checkpoint();
  let confirms=0,opens=0;s.stale=!race;s.failRestore=race;
  const b=browser(s,a.key,{confirm:async()=>{confirms++;return true;},openSaved:async id=>{
    assert.equal(id,'saved-canvas');opens++;return {id,versionId:'v2',payload:payload('Latest saved work')};
  }});
  await b.mounted;assert.equal(await b.api.ready(),true);assert.equal(opens,1);assert.equal(confirms,race?1:0);
  assert.equal(b.restores.length,1);assert.equal(b.restores[0].saved,true);assert.equal(b.restores[0].payload.drafts[0].values.Name,'Latest saved work');
  assert.equal(b.key,null);assert.match(b.w.document.body.textContent,/latest saved canvas/);
  const writes=s.calls.filter(c=>c.op==='write').length;await b.checkpoint();assert.equal(s.calls.filter(c=>c.op==='write').length,writes,'Opening a saved canvas must not mark it dirty');
  b.edit('New change');await b.checkpoint();assert.equal(s.rows.get(b.key).versionId,'v2');
  a.dom.window.close();b.dom.window.close();
});

test('failed latest-canvas open offers Retry and preserves the checkpoint reference',async()=>{
  const s=server(),a=browser(s);await a.mounted;a.snapshot={id:'saved-canvas',versionId:'v1',isDraft:false,payload:payload('Old')};await a.checkpoint();s.stale=true;
  let offline=true;const b=browser(s,a.key,{openSaved:async id=>{if(offline)throw Error('Offline');return {id,versionId:'v2',payload:payload('Saved')};}});
  await b.mounted;assert.equal(b.key,a.key);assert.equal(b.restores.length,0);
  const retry=b.w.document.querySelector('#native-recovery-status button');assert.equal(retry.textContent,'Retry');
  offline=false;await retry.onclick();assert.equal(b.restores[0].saved,true);assert.equal(b.key,null);
  a.dom.window.close();b.dom.window.close();
});

test('declining takeover leaves the other session untouched without a false restored message',async()=>{
  const s=server(),a=browser(s);await a.mounted;a.snapshot={id:'saved-canvas',versionId:'v1',isDraft:false,payload:payload('Old')};await a.checkpoint();s.stale=true;
  const b=browser(s,a.key,{openSaved:async()=>{throw Error('Canvas takeover cancelled.');}});await b.mounted;
  assert.equal(b.restores.length,0);assert.equal(b.key,null);assert.match(b.w.document.body.textContent,/remains open in the other session/);
  a.dom.window.close();b.dom.window.close();
});

test('shared canvas restore callback marks latest saved content clean and recovered edits dirty',async()=>{
  const app=fs.readFileSync(path.join(__dirname,'../vendor/upstream/packages/canvas/src/public/js/app.js'),'utf8');
  const start=app.indexOf('restore: async (data, options = {}) => {'),end=app.indexOf('\n\t\tconfirm:',start);
  assert.ok(start>=0&&end>start);
  const state={};let clean=0,dirty=0,applied;
  const deps={canvasState:state,applyCanvasPayload:async(value,options)=>{applied={value,options};},_canvasSaveState:{captureSaved:()=>clean++,markRestored:()=>dirty++},renderShareRecipientBanner:()=>{},renderBulkView:()=>{},renderBulkToolbar:()=>{}};
  const restore=new Function(...Object.keys(deps),'let _canvasShareCanvasId,_canvasShareRole; return ({'+app.slice(start,end)+'}).restore;')(...Object.values(deps));
  const data={id:'saved-canvas',versionId:'v2',title:'Shared canvas',ownedByMe:false,recipientRole:'editor',payload:payload('Latest')};
  await restore(data,{saved:true});assert.equal(clean,1);assert.equal(dirty,0);assert.equal(state.currentCanvas.id,'saved-canvas');assert.equal(state._renderCanvasShareRole,'editor');assert.equal(applied.value.drafts[0].values.Name,'Latest');
  await restore(data);assert.equal(clean,1);assert.equal(dirty,1);
});
