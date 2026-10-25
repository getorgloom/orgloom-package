const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {JSDOM}=require('jsdom');
const root=path.resolve(__dirname,'..');
const shared=path.join(root,'vendor/upstream/packages/canvas/src/public/js');
const noop=()=>{};
function browser(native=true){
  const dom=new JSDOM('<body><button id="tools">Tools</button></body>',{runScripts:'outside-only',url:'https://example.my.salesforce.com'});
  const w=dom.window;
  w.__ORGLOOM_NATIVE_IDENTITY__={lightningOrigin:'https://example.lightning.force.com'};
  if(native)w.eval(fs.readFileSync(path.join(root,'web/platform.js'),'utf8'));
  return {dom,w,platform:w.OrgLoom?.platform};
}
test('native platform builds encoded Lightning links, exports migration files and reports no-email sharing',()=>{
  const {dom,platform}=browser();
  try{
    assert.equal(platform.share.buildUrl('id&other=value'),'https://example.lightning.force.com/lightning/n/OrgLoomNativeCanvas?c__openCanvas=id%26other%3Dvalue');
    let exports=0;platform.migration.start({exportForMigration:()=>exports++});assert.equal(exports,1);
    assert.match(platform.share.notificationMessage({notificationMode:'saved-canvases'}),/No email was sent/);
    assert.equal(platform.share.notificationMessage({emailDeliverFailed:true}),undefined);
    assert.equal(platform.requestSequenceFloor({_meta:{nativeNextSlotId:42}}),42);
  }finally{dom.window.close();}
});

test('managed native sharing uses the namespaced Lightning tab returned by Salesforce',()=>{
  const {dom,w,platform}=browser();
  try{
    w.__ORGLOOM_NATIVE_IDENTITY__.canvasTabName='orgloom__OrgLoomNativeCanvas';
    assert.equal(platform.share.buildUrl('test-id'),'https://example.lightning.force.com/lightning/n/orgloom__OrgLoomNativeCanvas?c__openCanvas=test-id');
  }finally{dom.window.close();}
});
test('native submission reloads contributors and only completes matching whole-record requests for editors',async()=>{
  const {dom,platform}=browser();
  try{
    const records=[{slot:{slotId:1,kind:'whole-record'}},{slot:{slotId:2,kind:'fields'}},{slot:{slotId:3,kind:'whole-record'}}];
    const canvasState={bulkRecords:records,currentCanvas:{versionId:'before'}};
    let reloaded=0,rendered=0;
    const context={fills:[{slotId:'1'},{slotId:2}],response:{versionId:'after'},canvasState,reload:async()=>reloaded++,render:()=>rendered++};
    await platform.afterRequestsSubmitted({...context,role:'contributor'});
    assert.equal(reloaded,1);assert.equal(rendered,0);assert.ok(records[0].slot);assert.equal(canvasState.currentCanvas.versionId,'before');
    await platform.afterRequestsSubmitted({...context,role:'editor'});
    assert.equal(records[0].slot,undefined);assert.ok(records[1].slot);assert.ok(records[2].slot);
    assert.equal(canvasState.currentCanvas.versionId,'after');assert.equal(rendered,1);
  }finally{dom.window.close();}
});
test('native clipboard hooks retain the session-ended guard',()=>{
  const {dom,w,platform}=browser();
  try{
    let mounted;w.OrgLoomNativePaste={mount:ctx=>mounted=ctx};
    const commit=()=>{};platform.clipboard.mount({commit});
    assert.equal(mounted.commit,commit);assert.equal(mounted.loading(),false);assert.equal(platform.canEdit(),true);
    const ended=w.document.createElement('div');ended.id='native-session-ended';w.document.body.append(ended);
    assert.equal(mounted.loading(),true);assert.equal(platform.canEdit(),false);
  }finally{dom.window.close();}
});
for(const native of [false,true])test('shared Tools renders and invokes '+(native?'native export':'hosted migration')+' without rewriting source',()=>{
  const {dom,w,platform}=browser(native);
  try{
    w.eval(fs.readFileSync(path.join(shared,'bulk-ops-menu.js'),'utf8'));
    let invoked=0;
    const state={bulkRecords:[{id:1,objectName:'Account',values:{Name:'Demo'}}],bulkSelectedIds:new Set()};
    const deps=new Proxy({canvasState:state,canEditCanvasStructure:()=>true,_hasCap:()=>true,isCapabilityReady:()=>true,getAiGen:()=>({isEnabled:()=>false,getAccessState:()=>({ready:true,allowed:false})}),beginMigration:()=>{if(platform)platform.migration.start({exportForMigration:()=>invoked++});else invoked++;}}, {get:(target,key)=>key in target?target[key]:noop});
    w.OrgLoom.bulkOpsMenu.mount(deps).showBulkOperationsMenu(w.document.querySelector('#tools'));
    const button=w.document.querySelector('[data-bulk-op="migrate-org"]');
    assert.equal(button.textContent,native?'Export for migration…':'Migrate to another org…');
    assert.match(button.title,native?/Export a migration file/:/saved first/);
    button.click();assert.equal(invoked,1);
  }finally{dom.window.close();}
});
for(const transition of ['none','canvas','records','session'])test('Run script '+transition+' transition while permission is pending',async()=>{
  const {dom,w}=browser();
  try{
    w.eval(fs.readFileSync(path.join(shared,'bulk-script.js'),'utf8'));
    let finish, allowed=true;
    const record={id:1,objectName:'Account',values:{Name:'Before'}};
    const state={bulkRecords:[record],bulkSelectedIds:new Set(),describeCache:{Account:{fields:[{name:'Name',updateable:true,createable:true}]}},bulkAssociations:[]};
    w.OrgLoom.bulkScript.mount({canvasState:state,csrfFetch:()=>new Promise(resolve=>finish=resolve),refreshCapabilities:noop,showBulkToast:noop,renderBulkView:noop,showConfirmDialog:async()=>true,canCommit:()=>allowed});
    w.document.querySelector('#bs-source').value="records[0].values.Name = 'After';";
    w.document.querySelector('#bs-run').click();
    assert.equal(typeof finish,'function');
    if(transition==='canvas')state.currentCanvas={id:'other'};
    if(transition==='records')state.bulkRecords=[];
    if(transition==='session')allowed=false;
    finish({ok:true,json:async()=>({})});
    await new Promise(resolve=>setImmediate(resolve));
    assert.equal(record.values.Name,transition==='none'?'After':'Before');
    if(transition!=='none')assert.match(w.document.querySelector('#bs-output').textContent,/session changed/);
  }finally{dom.window.close();}
});
