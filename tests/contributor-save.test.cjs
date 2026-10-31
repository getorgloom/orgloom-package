const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');

function fixture(role='contributor',reply={submitted:1,versionId:'saved-version'}){
  const window={OrgLoom:{}};
  vm.runInNewContext(fs.readFileSync('web/excluded-features.js','utf8'),{window});
  const canvasState={currentCanvas:{id:'canvas-id',ownedByMe:role==='owner',recipientRole:role,versionId:'before'}};
  const calls=[];
  const api=window.OrgLoom.presence.mount({canvasState,csrfFetch:async(url,options)=>{
    calls.push({url,...options,body:JSON.parse(options.body)});
    if(reply instanceof Error)throw reply;
    return {ok:!reply.message,json:async()=>reply};
  }});
  return {api,canvasState,calls};
}

test('contributor Save changes persists only changed request fields and completes whole request after acknowledgement',async()=>{
  const {api,canvasState,calls}=fixture();
  const record={slot:{slotId:2,kind:'record'},values:{Secret__c:'must not send'}};
  await api.commitRecordFields(record,{Name:'Requested draft',Parent__c:null},{relationshipFields:['Parent__c']});
  assert.equal(calls.length,1);
  assert.equal(calls[0].url,'/api/canvas/canvas-id/slot-fill');
  assert.equal(calls[0].method,'POST');
  assert.deepEqual(calls[0].body,{fills:[{slotId:2,values:{Name:'Requested draft',Parent__c:null},relationshipFields:['Parent__c']}]});
  assert.equal(record.slot,undefined);
  assert.equal(canvasState.currentCanvas.versionId,'saved-version');
  await assert.rejects(api.commitRecordFields(record,{Name:'Cannot edit completed request'}),/no longer an active/);
  assert.equal(calls.length,1);
});

test('field requests remain available for later contributions',async()=>{
  const {api,calls}=fixture();
  const record={slot:{slotId:1,kind:'fields',fields:['Public__c']}};
  await api.commitRecordFields(record,{Public__c:'First'});
  await api.commitRecordFields(record,{Public__c:'Second'});
  assert.equal(calls.length,2);
  assert.equal(record.slot.slotId,1);
});

for(const reply of [{message:'Only requested fields can be submitted.'},{submitted:0,versionId:'unchanged'},{submitted:1},new Error('Network unavailable')]){
  test('failed or unconfirmed contribution preserves request and version: '+JSON.stringify(reply),async()=>{
    const {api,canvasState}=fixture('contributor',reply);
    const record={slot:{slotId:2,kind:'record'}};
    await assert.rejects(api.commitRecordFields(record,{Name:'Keep my edit'}));
    assert.equal(record.slot.slotId,2);
    assert.equal(canvasState.currentCanvas.versionId,'before');
  });
}

test('viewer cannot commit; owner and editor keep the explicit canvas-save workflow',async()=>{
  for(const role of ['viewer','owner','editor']){
    const {api,calls}=fixture(role);
    if(role==='viewer')await assert.rejects(api.commitRecordFields({}, {Name:'Denied'}),/view only/);
    else assert.equal((await api.commitRecordFields({}, {Name:'Local edit'})).localOnly,true);
    assert.equal(calls.length,0);
  }
});
