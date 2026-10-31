const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {JSDOM}=require('jsdom');
const root=path.resolve(__dirname,'..');
const shared=path.join(root,'vendor/upstream/packages/canvas/src/public/js');
const copy=value=>JSON.parse(JSON.stringify(value));
function fixture(){
  const dom=new JSDOM('<body></body>',{runScripts:'outside-only'}),w=dom.window;
  w.eval(fs.readFileSync(path.join(shared,'canvas-save-state.js'),'utf8'));
  const current={id:'canvas',versionId:'v1',ownedByMe:true};
  const state={currentCanvas:current,bulkRecords:[]};
  const payload={loadedRecords:[],drafts:[{tempId:'a',canvasRecordId:'a',objectName:'Account',values:{Name:'Saved'}},{tempId:'b',canvasRecordId:'b',objectName:'Contact',values:{LastName:'Saved'}}],associations:[{from:{kind:'draft',ref:'b'},to:{kind:'draft',ref:'a'},fieldName:'AccountId'}],schema:{objects:[]}};
  const model=w.OrgLoom.canvasSaveState.mount({canvasState:state});model.setPayloadProvider(()=>payload);model.captureSaved();
  return {dom,w,state,payload,model,current};
}
test('request save leaves unrelated record edits dirty, including edits to the target',()=>{
  const f=fixture();try{
    const record=f.payload.drafts[0];record.slot={slotId:1,kind:'fields',fields:['Name']};
    f.payload.associations[0].to={kind:'slot',ref:1};
    record.values.Name='Target local edit';f.payload.drafts[1].values.LastName='Other local edit';
    f.model.captureRequest({...copy(record),values:{Name:'Saved'}});
    assert.equal(f.model.hasUnsavedChanges(),true);
    record.values.Name='Saved';f.payload.drafts[1].values.LastName='Saved';f.model.refresh();
    assert.equal(f.model.hasUnsavedChanges(),false);
  }finally{f.dom.window.close();}
});
test('confirmed removal and standalone creation update only their saved baseline',()=>{
  const f=fixture();try{
    const record=f.payload.drafts[0];record.slot={slotId:1,kind:'fields',fields:['Name']};f.payload.associations[0].to={kind:'slot',ref:1};f.model.captureSaved();
    delete record.slot;f.payload.associations[0].to={kind:'draft',ref:'a'};f.model.captureRequest(copy(record));
    assert.equal(f.model.hasUnsavedChanges(),false);
    const newRecord={tempId:'c',objectName:'Case',values:{},slot:{slotId:2,kind:'whole-record'}},schema={name:'Case',fields:[]};
    f.payload.drafts.push(newRecord);f.payload.schema.objects.push(schema);f.payload.drafts[1].values.LastName='Unsaved';
    f.model.captureRequest(copy(newRecord),copy(schema));assert.equal(f.model.hasUnsavedChanges(),true);
    f.payload.drafts[1].values.LastName='Saved';f.model.refresh();assert.equal(f.model.hasUnsavedChanges(),false);
  }finally{f.dom.window.close();}
});
test('failed request keeps local changes and Retry adopts only the confirmed revision',async()=>{
  const f=fixture();try{
    const record={_canvasRecordId:'a',objectName:'Account'};f.state.bulkRecords.push(record);
    f.payload.drafts[0].slot={slotId:1,kind:'fields',fields:['Name']};f.payload.associations[0].to={kind:'slot',ref:1};
    f.payload.drafts[1].values.LastName='Still local';
    let fail=true,retry,success=0,recovery=0,initialSaves=0;
    const platform={saveRequestChange:async ({record:row})=>{if(fail)throw Error('Network unavailable');return {versionId:'v2',record:copy(row)};},recovery:{requestSaved:async()=>recovery++,saved:async()=>{}}};
    const source=fs.readFileSync(path.join(shared,'app.js'),'utf8');
    const chunk=source.slice(source.indexOf('let _requestSaveQueue ='),source.indexOf('\n\tasync function convertRecordToFieldSlot'));
    const deps={canvasState:f.state,platform,buildCanvasPayload:()=>f.payload,_canvasSaveState:f.model,csrfFetch:()=>{},showBulkToast:()=>success++,showBulkToastWithAction:(_msg,label,action)=>{assert.equal(label,'Retry');retry=action;},saveExistingCanvas:()=>{throw Error('Must not save entire canvas');},promptCanvasSave:async()=>{initialSaves++;return false;}};
    const save=new Function(...Object.keys(deps),chunk+'\nreturn _saveRequestChange;')(...Object.values(deps));
    assert.equal(await save(record),false);assert.equal(f.current.versionId,'v1');assert.equal(success,0);assert.equal(recovery,0);
    assert.equal(f.payload.drafts[0].slot.fields[0],'Name');
    fail=false;await retry();assert.equal(success,1);assert.equal(f.current.versionId,'v2');assert.equal(recovery,1);assert.equal(f.model.hasUnsavedChanges(),true);
    f.state.currentCanvas=null;assert.equal(await save(record),false);assert.equal(initialSaves,1);assert.equal(recovery,1);
  }finally{f.dom.window.close();}
});
test('native adapter sends one record and expected revision; server errors propagate',async()=>{
  const f=fixture();try{
    f.w.eval(fs.readFileSync(path.join(root,'web/platform.js'),'utf8'));
    let sent;const input={canvas:f.current,record:f.payload.drafts[0],schemaObject:{name:'Account'},csrfFetch:async(url,opts)=>{sent={url,body:JSON.parse(opts.body)};return {ok:true,json:async()=>({versionId:'v2'})};}};
    await f.w.OrgLoom.platform.saveRequestChange(input);
    assert.equal(sent.url,'/api/canvas/canvas/request-change');assert.equal(sent.body.expectedVersionId,'v1');assert.equal(sent.body.payload,undefined);assert.equal(sent.body.record.tempId,'a');
    input.csrfFetch=async()=>({ok:false,json:async()=>({message:'Access revoked'})});await assert.rejects(()=>f.w.OrgLoom.platform.saveRequestChange(input),/Access revoked/);
  }finally{f.dom.window.close();}
});
