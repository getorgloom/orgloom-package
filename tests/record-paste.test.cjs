const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const {parseRecordLink}=require('../web/record-paste.js');
const origin='https://example.lightning.force.com';
const recordId='001000000000001AAA';
const link=origin+'/lightning/r/Account/'+recordId+'/view';
function harness(options={}) {
  const events={},calls=[],toasts=[];
  const state={graphView:'bulk',bulkRecords:[],bulkSelectedIds:new Set(),bulkClipboard:null};
  let canvas={id:'canvas'},duplicates=0;
  const window={__ORGLOOM_NATIVE_IDENTITY__:{lightningOrigin:origin,instanceUrl:'https://example.my.salesforce.com'},getSelection:()=>({isCollapsed:true}),crypto:{randomUUID:()=> 'session-token'},fetch:async(...args)=>{calls.push(args);if(options.fetch)return options.fetch();return {ok:true,json:async()=>({records:[{loadedFromId:recordId,values:{Name:'Saved name'}}]})};}};
  const document={addEventListener:(name,fn)=>events[name]=fn,querySelector:()=>options.modal?{}:null};
  vm.runInNewContext(fs.readFileSync(require.resolve('../web/record-paste.js'),'utf8'),{window,document,URL});
  window.OrgLoomNativePaste.mount({canvasState:state,canEdit:()=>options.canEdit!==false,loading:()=>false,canvas:()=>canvas,render(){},toast:text=>toasts.push(text),copyCards:()=>{state.bulkClipboard={records:[{values:{Name:'Fixture value'}}]};return true;},pasteCards:()=>duplicates++,commit:async(result,opts)=>{if(!opts.canCommit())throw Error('changed');state.bulkRecords.push({id:1,...result.records[0]});return {added:1};}});
  function event(text,editable=false,files=[]) {
    return {prevented:false,target:{closest:()=>editable?{}:null},preventDefault(){this.prevented=true;},clipboardData:{files,getData:()=>text,setData(type,value){this.written={type,value};}}};
  }
  async function paste(text=link,editable=false,files=[]) {const e=event(text,editable,files);await events.paste(e);return e;}
  function copy() {const e=event('');events.copy(e);return e;}
  return {state,calls,toasts,paste,copy,changeCanvas:()=>canvas={id:'new'},duplicates:()=>duplicates};
}
test('record URLs require the connected org and an individual record route',()=>{
  assert.deepEqual(parseRecordLink(' '+link+'?foo=bar ',[origin]),{recordId});
  assert.deepEqual(parseRecordLink('/'+recordId,[origin]),{recordId});
  for(const value of [link.replace('example.','evil.'),link.replace('https://','https://user:pass@'),origin+'/lightning/o/Account/list'])assert.ok(parseRecordLink(value,[origin]).error);
  for(const value of [recordId,'ordinary text',link+'\n'+link])assert.equal(parseRecordLink(value,[origin]),null);
});
test('pasting loads a record and repeated pastes preserve local edits',async()=>{
  const h=harness();assert.equal((await h.paste()).prevented,true);assert.equal(h.state.bulkRecords.length,1);
  h.state.bulkRecords[0].values.Name='Local edit';await h.paste();assert.equal(h.state.bulkRecords.length,1);assert.equal(h.state.bulkRecords[0].values.Name,'Local edit');
});
test('text fields, dialogs, files, unrelated text and schema view retain native behavior',async()=>{
  const h=harness();for(const e of [await h.paste('ordinary text'),await h.paste(link,true),await h.paste(link,false,[{}])])assert.equal(e.prevented,false);
  h.state.graphView='schema';assert.equal((await h.paste()).prevented,false);assert.equal(h.calls.length,0);
  const modal=harness({modal:true});assert.equal((await modal.paste()).prevented,false);assert.equal(modal.calls.length,0);
});
test('permissions and foreign links fail without fetching records',async()=>{
  const h=harness({canEdit:false});await h.paste();assert.equal(h.calls.length,0);assert.match(h.toasts[0],/owner or an editor/);
  const foreign=harness();await foreign.paste(link.replace('example.','other.'));assert.equal(foreign.calls.length,0);assert.match(foreign.toasts[0],/connected/);
});
test('failed reads and canvas changes during loading never insert records',async()=>{
  let finish;const h=harness({fetch:()=>new Promise(resolve=>finish=resolve)});const job=h.paste();h.changeCanvas();finish({ok:true,json:async()=>({records:[{loadedFromId:recordId}]})});await job;assert.equal(h.state.bulkRecords.length,0);assert.match(h.toasts[0],/canvas changed/);
  const denied=harness({fetch:async()=>({ok:false,json:async()=>({message:'Record unavailable.'})})});await denied.paste();assert.equal(denied.state.bulkRecords.length,0);
});
test('copied cards use a session marker without putting Salesforce values in the clipboard',async()=>{
  const h=harness();h.state.bulkSelectedIds.add(1);const copied=h.copy();assert.equal(copied.prevented,true);
  const marker=copied.clipboardData.written.value;assert.ok(!marker.includes('Fixture value'));
  await h.paste(marker);assert.equal(h.duplicates(),1);assert.equal(h.calls.length,0);
  await h.paste(link);assert.equal(h.duplicates(),1);assert.equal(h.state.bulkRecords.length,1);
  const other=harness();await other.paste(marker);assert.equal(other.duplicates(),0);
});
test('a second paste cannot start a concurrent load',async()=>{
  let finish;const h=harness({fetch:()=>new Promise(resolve=>finish=resolve)});const first=h.paste();await h.paste();assert.equal(h.calls.length,1);finish({ok:false,json:async()=>({message:'Unavailable'})});await first;
});
