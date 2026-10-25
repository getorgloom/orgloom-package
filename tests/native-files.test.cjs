const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const {assertImportSource} = require('../web/files.js');
const org = '00D000000000001AAA';

test('same-org template and saved-canvas formats are accepted without modifying their payloads', () => {
  for (const file of [
    {_meta:{exportedFrom:org},records:[{objectName:'Account',values:{Name:'Sample'}}]},
    {_meta:{savedFrom:org.slice(0,15)},loadedRecords:[],drafts:[{objectName:'Contact',values:{LastName:'Sample'}}]},
  ]) {
    const original = structuredClone(file);
    assert.doesNotThrow(()=>assertImportSource(file,org));
    assert.deepEqual(file,original);
  }
});

test('foreign, conflicting, unidentified and migration imports fail before applying data', () => {
  for (const file of [
    {_meta:{exportedFrom:'00D000000000002AAA'},records:[]},
    {_meta:{savedFrom:org,exportedFrom:'00D000000000002AAA'},drafts:[]},
    {_meta:{},records:[{loadedFromId:'001000000000001AAA'}]},
    {_meta:{savedFrom:org,migration:true},drafts:[]},
  ]) assert.throws(()=>assertImportSource(file,org));
});

test('module adapters preserve normal loads and deny revoked file-import grants before mutation',async()=>{
  const calls=[],toasts=[];
  let permitted=false;
  const window={SF_ORG_ID:org,fetch:async()=>({ok:permitted,json:async()=>({message:'Import grant revoked'})}),OrgLoom:{
    templates:{mount:()=>({
      validateTemplate:()=>calls.push('validate'),validateCanvasPayload:()=>calls.push('validate'),
      applyTemplate:()=>calls.push('apply'),applyCanvasPayload:()=>calls.push('load'),
    })},
    linkedCsv:{mount:()=>({openModal:()=>calls.push('csv')})},
  }};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../web/files.js'),'utf8'),{window});
  const api=window.OrgLoom.templates.mount({});
  const file={_meta:{savedFrom:org},drafts:[]};
  await assert.rejects(api.applyCanvasPayload(file,{importFileName:'sample.json'}),/revoked/);
  assert.deepEqual(calls,[]);
  await api.applyCanvasPayload(file,{canvasIdentity:{id:'saved'}});
  assert.deepEqual(calls,['load']);
  await assert.rejects(api.applyTemplate({_meta:{exportedFrom:'00D000000000002AAA'}},{importFileName:'foreign.json'}),/another Salesforce org/);
  const csv=window.OrgLoom.linkedCsv.mount({showBulkToast:m=>toasts.push(m)});
  await csv.openModal();assert.deepEqual(toasts,['Import grant revoked']);assert.deepEqual(calls,['load']);
  permitted=true;await csv.openModal();await api.applyTemplate(file,{importFileName:'sample.json'});
  assert.deepEqual(calls,['load','csv','apply']);
});
