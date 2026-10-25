const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function harness(options={}) {
  const calls = [], timers = [], overlays = [];
  const window = {
    __ORGLOOM_NATIVE_IDENTITY__: { orgId:'test-org', userId:'test-user', orgName:'Test org', ...options.identity },
    localStorage:options.storage,
    __ORGLOOM_NATIVE_REMOTE__: 'test.invoke',
    Orgloom: { canvasState: { getCurrentCanvas:()=>({canvasId:'draft-test'}) } },
    OrgLoom: { uiFeedback: { mount:()=>({showConfirmDialog:options.showConfirmDialog||(()=>{throw Error('Unexpected takeover dialog');})}) } },
  };
  let now = 0;
  const clock = class extends Date { static now() { return now; } };
  const context = {
    window, Date:clock, Response, URL, location:{origin:'https://test.invalid'}, navigator:{},
    confirm:options.confirm||(()=>true), setInterval:(fn,ms)=>timers.push({fn,ms}),
    document:{readyState:'complete',createElement:()=>({setAttribute(){},append(){},remove(){this.removed=true;}}),body:{append:el=>overlays.push(el)}},
    Visualforce:{remoting:{Manager:{invokeAction(remote,op,raw,callback){
      const body=JSON.parse(raw);calls.push({op,body});
      if(op==='canvas:open'&&options.occupied&&!body.takeover&&!body.sessionToken){
        callback(JSON.stringify({status:400,data:{message:options.occupied}}),{status:true});return;
      }
      let data={ok:true};
      if(op==='history:preflight')data={nativeReviewToken:'review-'+body.id};
      if(op==='capabilities')data={capabilities:options.capabilities||{}};
      if(op==='uploadPlan')data={groups:options.groups||[body]};
      if(op==='uploadRecovery')data={status:'completed',results:[],retryableTempIds:[]};
      if(op==='uploadGroup'){
        if(options.failGroup===body.index){callback(null,{status:false});return;}
        data={results:[{tempId:body.index+1,id:'record-'+body.index,success:!options.rejectGroup?.includes(body.index)}],deletes:[],canonicalValues:{}};
      }
      if(op==='reads:counts')data={counts:body.probes.map(p=>({...p,count:1}))};
      if(op==='canvas:create'||op==='canvas:open')data={id:body.id||'a00123456789012',sessionToken:'session-token',partialView:options.partialView};
      callback(JSON.stringify({status:200,data}),{status:true});
    }}}},
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../web/native.js'),'utf8'),context);
  return {window,calls,timers,overlays,tick:ms=>{now+=ms;},fetch:(url,method='GET',body)=>window.fetch(url,{method,body:body&&JSON.stringify(body)})};
}

test('own-session takeover waits for Continue here and explains unsaved changes',async()=>{
  let prompt,accept;
  const h=harness({occupied:'OCCUPIED_SELF: You already have this canvas open in another tab or window.',showConfirmDialog:options=>{prompt=options;return new Promise(resolve=>{accept=resolve;});}});
  const opening=h.fetch('/api/canvas/a00123456789012');
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(prompt.confirmLabel,'Continue here');assert.equal(prompt.cancelLabel,'Cancel');
  assert.match(prompt.message,/You already have this canvas open/);
  assert.match(prompt.message,/latest saved version/);assert.match(prompt.message,/unsaved changes won’t transfer/);
  assert.equal(h.calls.length,1);
  accept(true);
  assert.equal((await opening).status,200);
  assert.equal(h.calls.at(-1).body.takeover,true);
  const count=h.calls.length;
  await h.fetch('/api/canvas/a00123456789012');
  assert.equal(h.calls.length,count+1);
  assert.equal(h.calls.at(-1).body.sessionToken,'session-token');
});

test('cancelling either takeover warning never acquires a replacement session',async()=>{
  for(const occupied of ['OCCUPIED_SELF: You already have this canvas open in another tab or window.','OCCUPIED: Alex Morgan currently has this canvas open.']){
    let prompt;
    const h=harness({occupied,showConfirmDialog:async options=>{prompt=options;return false;}});
    const response=await h.fetch('/api/canvas/a00123456789012');
    assert.equal(response.status,400);assert.match((await response.json()).message,/cancelled/);
    assert.equal(h.calls.length,1);assert.equal(h.calls[0].body.takeover,undefined);
    if(occupied.startsWith('OCCUPIED:')){
      assert.equal(prompt.confirmLabel,'Take over');assert.match(prompt.message,/Alex Morgan/);
      assert.match(prompt.message,/Their session will lose editing access/);
    }
  }
});

function guide(window, native=true) {
  const source=fs.readFileSync(path.join(__dirname,'../vendor/upstream/packages/canvas/src/public/js/app.js'),'utf8');
  const context=vm.createContext({window,localStorage:window.localStorage,platform:native?{onboarding:window.OrgLoomNativeOnboarding}:{}});
  vm.runInContext(source.slice(source.indexOf('const _canvasGuideScope ='),source.indexOf('const _autosave =')),context);
  return {
    dismiss:()=>vm.runInContext('_dismissCanvasGuide()',context),
    visible(records){
      context.canvasState={bulkRecords:records};
      context.showingSharedTasks=false;
      const start=source.indexOf('const realCount = canvasState.bulkRecords.filter');
      const end=source.indexOf("emptyPh.style.display =",start);
      return vm.runInContext('(()=>{'+source.slice(start,end)+'return showPh;})()',context);
    },
  };
}

test('native onboarding survives reload after use or dismissal without persisting record data',()=>{
  const values=new Map();
  const storage={getItem:k=>values.get(k)??null,setItem:(k,v)=>values.set(k,v)};
  let w=harness({storage}).window;
  const first=guide(w);
  assert.equal(first.visible([]),true);
  assert.equal(first.visible([{isTypeNode:true}]),true);
  assert.equal(values.size,0);
  assert.equal(first.visible([{id:'record-1',fields:{Name:'Private customer'}}]),false);
  w.localStorage.setItem('recovery',JSON.stringify({Name:'Private customer'}));
  w.sessionStorage.setItem('draft','private');
  w.OrgLoomNativeOnboarding.setFlag('record-data');
  assert.deepEqual([...values.values()],['1']);
  assert.match([...values.keys()][0],/:test-org:test-user:completed$/);
  w=harness({storage}).window;
  assert.equal(guide(w).visible([]),false);
  assert.equal(w.localStorage.getItem('recovery'),null);
  assert.equal(w.sessionStorage.getItem('draft'),null);
  const otherUser=harness({storage,identity:{userId:'other-user'}}).window;
  assert.equal(guide(otherUser).visible([]),true);
  guide(otherUser).dismiss();
  assert.equal(guide(harness({storage,identity:{userId:'other-user'}}).window).visible([]),false);
  assert.equal(guide(harness({storage,identity:{orgId:'other-org'}}).window).visible([]),true);
});

test('blocked preference storage keeps onboarding completion for the current page',()=>{
  const storage={getItem(){throw Error('blocked');},setItem(){throw Error('blocked');}};
  const g=guide(harness({storage}).window);
  assert.equal(g.visible([]),true);
  assert.equal(g.visible([{id:'one'}]),false);
  assert.equal(g.visible([]),false);
});

test('hosted onboarding still completes on upload or dismissal, not simply adding a record',()=>{
  const w=harness().window;
  const g=guide(w,false);
  assert.equal(g.visible([{id:'one'}]),false);
  assert.equal(g.visible([]),true);
  g.dismiss();
  assert.equal(guide(w,false).visible([]),false);
});

test('unsupported methods and off-origin routes never reach remoting',async()=>{
  const h=harness();
  for(const [url,method] of [['/api/canvas/a00123456789012','PATCH'],['https://other.invalid/api/query','POST'],['//other.invalid/api/query','POST']]){
    assert.equal((await h.fetch(url,method)).status,400);
  }
  assert.equal(h.calls.length,0);
});

test('deleting the active saved canvas stops its heartbeat and passes the editing lease',async()=>{
  const h=harness();await h.fetch('/api/canvas','POST',{name:'Draft'});
  await h.fetch('/api/canvas/a00123456789012','DELETE');
  assert.deepEqual(h.calls.at(-1),{op:'canvas:delete',body:{id:'a00123456789012',sessionToken:'session-token'}});
  const count=h.calls.length;await h.timers.find(t=>t.ms===30000).fn();assert.equal(h.calls.length,count);
});

test('partial-view notice explains preservation and clears when the canvas changes',async()=>{
  const h=harness({partialView:true});await h.fetch('/api/canvas/a00123456789012');
  const notice=h.overlays.find(el=>el.id==='native-partial-view');assert.match(notice.textContent,/Hidden content is preserved/);
  h.window.Orgloom.canvasState.getCurrentCanvas=()=>({canvasId:'a00123456789012'});
  h.tick(11000);await h.timers.find(t=>t.ms===5000).fn();assert.equal(notice.removed,undefined);
  h.window.Orgloom.canvasState.getCurrentCanvas=()=>({canvasId:'new-canvas'});
  await h.timers.find(t=>t.ms===5000).fn();assert.equal(notice.removed,true);
});

test('switching to an unsaved canvas releases only the previous session',async()=>{
  const h=harness();
  await h.fetch('/api/canvas','POST',{name:'Draft'});
  h.window.Orgloom.canvasState.getCurrentCanvas=()=>({canvasId:'a00123456789012'});
  h.tick(11000); await h.timers.find(t=>t.ms===5000).fn();
  assert.equal(h.calls.length,1);
  h.window.Orgloom.canvasState.getCurrentCanvas=()=>({canvasId:'draft-new'});
  await h.timers.find(t=>t.ms===5000).fn();
  assert.equal(h.calls.at(-1).op,'canvas:release');
  assert.equal(h.calls.at(-1).body.sessionToken,'session-token');
  await h.timers.find(t=>t.ms===30000).fn();
  assert.equal(h.calls.length,2);
  assert.equal(h.overlays.length,0);
});

test('upload replays still reach server digest validation',async()=>{
  const h=harness();
  await h.fetch('/api/upload','POST',{attemptId:'same-attempt',records:[]});
  await h.fetch('/api/upload','POST',{attemptId:'same-attempt',records:[{tempId:1}]});
  assert.equal(h.calls.filter(c=>c.op==='uploadPlan').length,2);
  assert.equal(h.calls.filter(c=>c.op==='uploadGroup').length,2);
});

test('atomic groups execute sequentially and preserve mixed success results',async()=>{
  const h=harness({groups:[{attemptId:'batch-one'},{attemptId:'batch-two'}],rejectGroup:[1]});
  const response=await h.fetch('/api/upload/graph','POST',{attemptId:'root-attempt',records:[]});
  assert.equal(response.status,200);
  assert.deepEqual((await response.json()).results.map(r=>r.success),[true,false]);
  assert.deepEqual(h.calls.filter(c=>c.op==='uploadGroup').map(c=>[c.body.rootAttemptId,c.body.index]),[['root-attempt',0],['root-attempt',1]]);
});

test('reviewed uploads execute without a second browser confirmation',async()=>{
  const h=harness({confirm:()=>{throw Error('Unexpected additional confirmation');}});
  const response=await h.fetch('/api/upload/graph','POST',{attemptId:'reviewed-attempt',records:[]});
  assert.equal(response.status,200);
  assert.equal((await response.json()).results[0].success,true);
  assert.deepEqual(h.calls.map(c=>c.op),['uploadPlan','uploadGroup']);
});

test('an unconfirmed batch stops subsequent writes and blocks fresh uploads',async()=>{
  const h=harness({groups:[{},{},{}],failGroup:1});
  const response=await h.fetch('/api/upload','POST',{attemptId:'root-attempt',records:[]});
  assert.equal(response.status,409);assert.equal((await response.json()).error,'upload-attempt-incomplete');
  assert.deepEqual(h.calls.filter(c=>c.op==='uploadGroup').map(c=>c.body.index),[0,1]);
  assert.equal((await h.fetch('/api/upload','POST',{attemptId:'new-attempt',records:[]})).status,400);
  assert.equal(h.calls.filter(c=>c.op==='uploadPlan').length,1);
  await h.fetch('/api/upload-attempts/unrelated-attempt');
  assert.equal((await h.fetch('/api/upload','POST',{attemptId:'new-attempt',records:[]})).status,400);
  await h.fetch('/api/upload-attempts/root-attempt');
  // The matching recovery clears the block; a fresh request reaches planning.
  await h.fetch('/api/upload','POST',{attemptId:'new-attempt',records:[]});
  assert.equal(h.calls.filter(c=>c.op==='uploadPlan').length,2);
});

test('relationship probes are split into bounded native transactions without losing results',async()=>{
  const h=harness();
  const probes=Array.from({length:61},(_,i)=>({name:'Contact',field:'AccountId',id:String(i)}));
  const result=await h.fetch('/api/related-counts','POST',{probes});
  assert.equal(result.status,200);
  assert.deepEqual((await result.json()).counts,probes.map(p=>({...p,count:1})));
  assert.deepEqual(h.calls.map(c=>c.body.probes.length),[25,25,11]);
  assert.equal((await h.fetch('/api/related-counts','POST',{probes:Array(201).fill(probes[0])})).status,400);
  assert.equal(h.calls.length,3);
});

test('lookup and graph routes preserve object and relationship parameters',async()=>{
  const h=harness();
  await h.fetch('/api/objects/Contact/lookup?fieldName=AccountId&targetApiName=Account&q=Native%20fixture');
  assert.deepEqual(h.calls[0],{op:'reads:lookup',body:{objectName:'Contact',fieldName:'AccountId',targetApiName:'Account',q:'Native fixture'}});
  await h.fetch('/api/objects/Lead/graph');
  assert.deepEqual(h.calls[1],{op:'reads:graph',body:{objectName:'Lead'}});
});

test('file identity reads use the narrow bulk-edit route without granting general SOQL',async()=>{
  const h=harness({capabilities:{'bulk-edit-records':true}});
  await h.fetch('/api/me');
  await h.fetch('/api/query','POST',{soql:"SELECT Id FROM Account WHERE Id IN ('001000000000001AAA')"});
  assert.equal(h.calls.at(-1).op,'fileLoad');
  await h.fetch('/api/query','POST',{soql:'SELECT Id FROM Account WHERE Name != null'});
  assert.equal(h.calls.at(-1).op,'query');
});

test('export checks always revalidate server-side grants',async()=>{
  const h=harness();
  await h.fetch('/api/capabilities/export-canvas/check','POST');
  assert.deepEqual(h.calls[0],{op:'capabilityCheck',body:{capability:'export-canvas'}});
  await h.fetch('/api/capabilities/export-records/check','POST');
  assert.deepEqual(h.calls[1],{op:'capabilityCheck',body:{capability:'export-records'}});
  assert.equal((await h.fetch('/api/capabilities/admin/check','POST')).status,400);
  assert.equal(h.calls.length,2);
});

test('local tools check their grants and the current editing lease without sending script or record values',async()=>{
  const h=harness();
  await h.fetch('/api/capabilities/run-script/check','POST');
  assert.deepEqual(h.calls.at(-1),{op:'capabilityCheck',body:{capability:'run-script'}});
  await h.fetch('/api/canvas','POST',{name:'Draft'});
  await h.fetch('/api/capabilities/auto-fill-records/check','POST',{source:'must not be sent',records:['private']});
  assert.deepEqual(h.calls.at(-1),{op:'capabilityCheck',body:{capability:'auto-fill-records',canvasId:'a00123456789012',sessionToken:'session-token'}});
});

test('Recall routes bind the reviewed token to its batch and ignore a caller supplied token',async()=>{
  const h=harness(),id='a00123456789012',other='a00123456789013';
  await h.fetch('/api/upload-batches/'+id+'/recall-preflight','POST',{});
  await h.fetch('/api/upload-batches/'+id+'/recall','POST',{nativeReviewToken:'forged',forceRevertSelections:[{sfId:'record',fields:[{fieldName:'Name',expectedCurrent:'Reviewed later value'}]}]});
  assert.equal(h.calls.at(-1).body.nativeReviewToken,'review-'+id);
  assert.equal(h.calls.at(-1).body.forceRevertSelections[0].fields[0].expectedCurrent,'Reviewed later value');
  await h.fetch('/api/upload-batches/'+other+'/recall','POST',{});
  assert.equal(h.calls.at(-1).body.nativeReviewToken,undefined);
  await h.fetch('/api/upload-batches/'+id,'DELETE');
  assert.equal(h.calls.at(-1).op,'history:forget');
});

test('pasted record links recheck the active canvas lease before reading',async()=>{
  const h=harness();await h.fetch('/api/canvas','POST',{name:'Draft'});
  await h.fetch('/api/native/record-link','POST',{recordId:'001000000000001AAA'});
  assert.deepEqual(h.calls.slice(-2).map(call=>call.op),['canvas:heartbeat','loadRecordLink']);
  assert.equal(h.calls.at(-1).body.recordId,'001000000000001AAA');
});
