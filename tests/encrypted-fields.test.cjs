const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {JSDOM}=require('jsdom');
const shared=path.join(__dirname,'../vendor/upstream/packages/canvas/src/public/js');
const noop=()=>{};
function fixture(){
  const dom=new JSDOM('<body></body>',{runScripts:'outside-only',url:'https://native.example.test'});
  const w=dom.window;w.SF_ORG_ID='00D000000000001AAA';
  for(const file of ['encrypted-fields.js','value-compare.js','import-shared.js','templates.js','canvas-export-csv.js'])w.eval(fs.readFileSync(path.join(shared,file),'utf8'));
  const state={selectedObjects:[],hiddenObjects:new Set(),bulkAssociations:[],describeCache:{Account:{fields:[{name:'Name',type:'string'},{name:'Secret__c',type:'encryptedstring'}]}},bulkSelectedIds:new Set(),bulkRecords:[
    {id:1,objectName:'Account',loadedFromId:'001000000000001AAA',values:{Name:'Ordinary',Secret__c:'SECRET_CURRENT'},loadedValues:{Name:'Before',Secret__c:'SECRET_OLD'}},
    {id:2,objectName:'Account',values:{Name:'Draft'}}
  ]};
  const api=w.OrgLoom.encryptedFields;
  api.setProposal(state.bulkRecords[0],'Secret__c','SECRET_REPLACE');api.setProposal(state.bulkRecords[1],'Secret__c','SECRET_DRAFT');
  const deps={canvasState:state,csrfFetch:async()=>({ok:true,json:async()=>({})}),showBulkToast:noop,escapeHtml:String,ensureDescribe:noop,addToSelection:noop,setGraphView:noop,renderAll:noop,showReplaceOrMergeDialog:noop,pingAuditEvent:noop,getCanvasRecordCap:()=>500,realRecordCount:()=>2,runSlotPreflight:noop,clearEmptyStarterCard:noop,getSlotIdSeq:()=>1,setSlotIdSeq:noop,refreshCapabilities:noop};
  return {dom,w,state,api,deps};
}
test('native JSON, saved/recovery payload and CSV never serialize encrypted values',()=>{
  const h=fixture();try{
    const templates=h.w.OrgLoom.templates.mount(h.deps);
    for(const data of [templates.buildTemplate(),templates.buildCanvasPayload()]){
      assert.doesNotMatch(JSON.stringify(data),/SECRET_/);
      assert.match(JSON.stringify(data),/Ordinary/);
      assert.match(JSON.stringify(data),/encryptedFieldIntents/);
    }
    const csv=h.w.OrgLoom.canvasExportCsv.mount(h.deps)._test.exportRows(h.state.bulkRecords);
    assert.doesNotMatch(JSON.stringify(csv),/SECRET_|Secret__c/);
    assert.equal(h.api.proposal(h.state.bulkRecords[0],'Secret__c'),'SECRET_REPLACE','Saving must retain the current tab proposal');
  }finally{h.dom.window.close();}
});
test('native uploads use explicit replacement or clear, never loaded encrypted values',()=>{
  const h=fixture();try{
    const record=h.state.bulkRecords[0];
    assert.equal(h.api.uploadValues(record,h.state,record.values).Secret__c,'SECRET_REPLACE');
    h.api.setProposal(record,'Secret__c',null);
    assert.equal(h.api.uploadValues(record,h.state,record.values).Secret__c,null);
    h.api.dismissIntent(record,'Secret__c');
    assert.equal(Object.hasOwn(h.api.uploadValues(record,h.state,record.values),'Secret__c'),false);
    record.encryptedFieldIntents=['Secret__c'];
    assert.equal(Object.hasOwn(h.api.uploadValues(record,h.state,record.values),'Secret__c'),false,'Restored intents must not replay an encrypted value');
  }finally{h.dom.window.close();}
});
test('native encrypted editor matches hosted owner-only actions and read-only permissions',()=>{
  const h=fixture();try{
    for(const file of ['datetime.js','insert-modal.js'])h.w.eval(fs.readFileSync(path.join(shared,file),'utf8'));
    const editor=h.w.OrgLoom.insertModal._test;
    assert.equal(editor.canChangeEncryptedField(null,false),true);
    assert.equal(editor.canChangeEncryptedField(null,true),false);
    for(const role of ['viewer','contributor','editor'])assert.equal(editor.canChangeEncryptedField(role,false),false);
    assert.equal(editor.encryptedActionForField(true,false,false,undefined,false,undefined),'unchanged');
    assert.equal(editor.encryptedControlValue(false,'replacement'),'replacement');
    assert.equal(editor.encryptedControlValue(true,'replacement'),null);
    assert.equal(editor.encryptedControlValue(false,''),undefined);
  }finally{h.dom.window.close();}
});
