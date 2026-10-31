const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {JSDOM}=require('jsdom');
const shared=path.join(__dirname,'../vendor/upstream/packages/canvas/src/public/js');
const noop=()=>{};
for(const native of [false,true])test(`${native?'Native':'Hosted'} toolbar follows canvas roles and updates when switching canvases`,()=>{
  const dom=new JSDOM('<body><div id="subbar-clone-btns"></div><div id="subbar-records"></div></body>',{runScripts:'outside-only'});
  try{
    const w=dom.window;
    if(native)w.eval(fs.readFileSync(path.join(__dirname,'../web/platform.js'),'utf8'));
    w.eval(fs.readFileSync(path.join(shared,'bulk-toolbar.js'),'utf8'));
    const state={bulkRecords:[{id:1}],bulkSelectedIds:new Set(),currentCanvas:null};
    let stagedRole=null;
    const access=()=>w.OrgLoom.bulkToolbar.canvasAccess(state.currentCanvas,stagedRole);
    const toolbar=w.OrgLoom.bulkToolbar.mount({canvasState:state,canEditCanvasStructure:()=>access().canPersistCanvas,
      isRecordModified:()=>false,_aggregateSlotProgress:()=>({total:0}),_slotProgressClass:noop,
      showSaveMenu:noop,promptCanvasSave:noop,showAddRecordsMenu:noop,showBulkOperationsMenu:noop,openUploadModal:noop,
      getGraph:()=>w.document.body,getReadOnlyMode:()=>false,hasCapability:()=>true,isCapabilityReady:()=>true,
      getWorkspacePlan:()=> 'team',_wireCanvasFloatingAdd:noop,getCanvasShareCount:()=>0,openCanvasEmailLinkModal:noop,
      openRecordDiffModal:noop,getCanvasSaveState:()=>({phase:'dirty'}),getCanvasShareRole:()=>stagedRole,saveExistingCanvas:noop});
    for(const role of ['owner','viewer','contributor','editor','owner','viewer']){
      state.currentCanvas={id:'canvas',ownedByMe:role==='owner',recipientRole:role==='owner'?null:role};
      toolbar.renderBulkToolbar();
      const has=selector=>!!w.document.querySelector(selector);
      const editable=role==='owner'||role==='editor';
      assert.equal(has('[data-bulk-save]'),editable,role+' save/export');
      assert.equal(has('[data-bulk-save-primary]'),editable,role+' save');
      assert.equal(has('[data-bulk-add-menu]'),editable,role+' add');
      assert.equal(has('[data-bulk-ops]'),editable,role+' tools');
      for(const selector of ['[data-bulk-share]','[data-bulk-upload]','[data-app-history]'])assert.equal(has(selector),role==='owner',role+' '+selector);
      assert.equal(has('[data-app-canvases]'),native,'Navigation stays available');
    }
    state.currentCanvas=null;stagedRole='viewer';toolbar.renderBulkToolbar();
    assert.equal(w.document.querySelector('[data-bulk-save]'),null,'No action flash during shared load');
  }finally{dom.window.close();}
});

test('shared viewer action entry points cannot open CSV or Recall dialogs',async()=>{
  const dom=new JSDOM('<body></body>',{runScripts:'outside-only'});
  try{
    const w=dom.window;
    for(const file of ['canvas-export-csv.js','upload-history.js'])w.eval(fs.readFileSync(path.join(shared,file),'utf8'));
    let requests=0;
    const deps={csrfFetch:async()=>{requests++;throw Error('Unexpected request');},escapeHtml:String,showBulkToast:noop,refreshCapabilities:async()=>{},hasCapability:()=>true,isCapabilityReady:()=>true};
    const csv=w.OrgLoom.canvasExportCsv.mount({...deps,canvasState:{},canSaveOrExport:()=>false});
    csv.openModal();
    const history=w.OrgLoom.uploadHistory.mount({...deps,canUseHistory:()=>false});
    history.openModal();await history._testConfirmAndRecall('batch');
    assert.equal(w.document.querySelector('.canvas-export-csv-modal').classList.contains('hidden'),true);
    assert.equal(w.document.querySelector('.upload-history-modal'),null);
    assert.equal(requests,0);
  }finally{dom.window.close();}
});
