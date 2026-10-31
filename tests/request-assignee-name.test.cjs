const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {JSDOM}=require('jsdom');
const shared=path.join(__dirname,'../vendor/upstream/packages/canvas/src/public/js');
const id='005000000000002AAA',noop=()=>{};
const flush=()=>new Promise(resolve=>setImmediate(resolve));
function fixture(initial,response){
  const dom=new JSDOM('<body></body>',{runScripts:'outside-only'}),w=dom.window,calls=[];
  for(const file of ['canvas-share.js','canvas-card-menu.js'])w.eval(fs.readFileSync(path.join(shared,file),'utf8'));
  const deps={canvasState:{},csrfFetch:async url=>{calls.push(url);return response;},escapeHtml:String,showBulkToast:noop,showConfirmDialog:noop,_hasCap:()=>true,getWorkspacePlan:()=> 'team',refreshCapabilities:noop,_invalidateShareCountForCanvas:noop};
  const share=w.OrgLoom.canvasShare.mount(deps);
  const menu=w.OrgLoom.canvasCardMenu.mount({...deps,renderBulkView:noop,recordOrdinal:noop,canEditCanvasStructure:()=>true,_canAuthorSlots:()=>true,openInsertModal:noop,convertRecordToFieldSlot:noop,configureExistingSlot:noop,convertSlotBackToRecord:noop,refreshRecordFromSf:noop,deleteRecord:noop,markPendingDelete:noop,unmarkPendingDelete:noop,attachSfUserPicker:share.attachSfUserPicker,_fillSlotWithSfRecord:noop});
  menu.showSlotConfigurationPicker({kind:'fields',objectName:'Account',fields:[{name:'Name',label:'Name',type:'string'}],initial:{fields:['Name'],assigneeSfUserId:id,...initial}});
  return {dom,w,calls,name:()=>w.document.querySelector('.sf-user-picker-selected-name')?.textContent};
}
for(const assigneeName of [undefined,'Assigned teammate'])test('missing/placeholder assignee name resolves to the actual user: '+assigneeName,async()=>{
  const h=fixture({assigneeName},{ok:true,json:async()=>({Id:id,Name:'Demo Share Access',Email:'demo@example.test'})});
  try{await flush();assert.equal(h.name(),'Demo Share Access');assert.deepEqual(h.calls,['/api/objects/User/records/'+id]);}finally{h.dom.window.close();}
});
test('a saved actual name needs no lookup',async()=>{
  const h=fixture({assigneeName:'Demo Share Access'},null);
  try{await flush();assert.equal(h.name(),'Demo Share Access');assert.equal(h.calls.length,0);}finally{h.dom.window.close();}
});
test('failed lookup never presents a placeholder as a selected teammate',async()=>{
  const h=fixture({},{ok:false,json:async()=>({message:'Unavailable'})});
  try{await flush();assert.equal(h.name(),undefined);assert.match(h.w.document.body.textContent,/Could not load the assigned user/);}finally{h.dom.window.close();}
});
test('a late lookup cannot undo a change to Any contributor',async()=>{
  let complete;const response={ok:true,json:()=>new Promise(resolve=>{complete=resolve;})};
  const h=fixture({},response);
  try{await flush();const any=h.w.document.querySelector('[name="slot-assignment-mode"][value="any"]');any.checked=true;any.dispatchEvent(new h.w.Event('change'));complete({Id:id,Name:'Old assignee'});await flush();assert.equal(h.name(),undefined);}finally{h.dom.window.close();}
});
