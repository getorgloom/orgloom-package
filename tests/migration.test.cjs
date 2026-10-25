const {test}=require('node:test'),assert=require('node:assert/strict');
const {stage,destinationPayload,isMigration}=require('../web/migration.js');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const context={window:{}};vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../vendor/upstream/packages/canvas/src/public/js/migrate-annotate.js'),'utf8'),context);
const engine=context.window.Orgloom.migrateAnnotate;
const account={name:'Account',fields:[{name:'Name',type:'string',createable:true,updateable:true,required:true},{name:'ParentId',type:'reference',createable:true,updateable:true},{name:'CreatedDate',type:'datetime',createable:false,updateable:false}]};
test('migration staging strips source identities and grants without mutating file or active canvas',()=>{
  const file={_meta:{forMigration:true},records:[{id:1,objectName:'Account',loadedFromId:'source',_uploadAttempt:{token:'stale'},values:{Id:'source',Name:'Source',ParentId:'source-parent',OwnerId:'source-user',CustomerId:'external-key'},slot:{kind:'fields',fields:['Name']}}],associations:[]};
  const original=JSON.stringify(file),state=stage(file,{Account:account});
  assert.equal(isMigration(file),true);assert.equal(JSON.stringify(file),original);
  assert.deepEqual(state.bulkRecords[0].values,{Name:'Source',CustomerId:'external-key'});assert.equal(state.bulkRecords[0].loadedFromId,undefined);
  assert.equal(state.bulkRecords[0].slot,undefined);assert.equal(state.bulkRecords[0]._uploadAttempt,undefined);
});
test('shared planner maps destination IDs and rebuilds child references from edges',()=>{
  const file={_meta:{forMigration:true},records:[{id:1,objectName:'Account',values:{Name:'Parent'}},{id:2,objectName:'Account',values:{Name:'Child',ParentId:'source'}}],associations:[{fromId:2,toId:1,fieldName:'ParentId'}]};
  const state=stage(file,{Account:account});state.bulkRecords[0]._migrateMatchedId='001000000000001AAA';state.bulkRecords[0].loadedFromId='001000000000001AAA';
  const annotations=engine.annotateRecords(state.bulkRecords,state.describeCache);
  engine.applyMigrationPlan(state.bulkRecords,state.bulkAssociations,Object.fromEntries(state.bulkRecords.map((r,i)=>[r.id,annotations[i]])),{'Account::001000000000001AAA':{Id:'001000000000001AAA',Name:'Old',CreatedDate:'2020-01-01'}},state.describeCache);
  const result=destinationPayload(state,'destination-org');
  assert.equal(result.records[1].values.ParentId,'001000000000001AAA');assert.equal(result.records[0].loadedFromId,'001000000000001AAA');
  assert.equal(result.records[0].values.CreatedDate,undefined);assert.equal(result.records[0].originalValues.Name,'Old');assert.equal(isMigration(result),false);
});
test('delete migration cannot apply until a destination match is selected',()=>{
  const state=stage({_meta:{forMigration:true},records:[{id:1,objectName:'Account',pendingDelete:true,loadedFromId:'source',values:{Name:'Delete me',Id:'source'}}],associations:[]},{Account:account});
  assert.throws(()=>engine.applyMigrationPlan(state.bulkRecords,[],{},{},state.describeCache),/destination record/);
});

test('foreign normal exports trigger reconciliation even without the migration marker',()=>{
  assert.equal(isMigration({_meta:{exportedFrom:'source-org'},records:[]},'destination-org'),true);
  assert.equal(isMigration({_meta:{exportedFrom:'same-org'},records:[]},'same-org'),false);
});

test('completed whole-record requests and their links survive migration; empty requests are counted',()=>{
  const file={_meta:{forMigration:true},records:[
    {id:1,objectName:'Account',values:{Name:'Requested parent'},slot:{kind:'whole-record',origin:'standalone',slotId:1}},
    {id:2,objectName:'Account',values:{Name:'Child'},slot:{kind:'fields',fields:['Name']}},
    {id:3,objectName:'Account',values:{Name:''},slot:{kind:'whole-record',slotId:3}},
    {id:4,objectName:'Account',loadedFromId:'source',values:{},slot:{kind:'whole-record',slotId:4}},
    {id:5,objectName:'Account',values:{Active__c:false},slot:{slotId:5}},
    {id:6,objectName:'Account',isPending:true,values:{Name:'Pending'}},
  ],associations:[{fromId:2,toId:1,fieldName:'ParentId'},{fromId:2,toId:3,fieldName:'Other__c'}]};
  const original=JSON.stringify(file),state=stage(file,{Account:account});
  assert.deepEqual(state.bulkRecords.map(r=>r.id),[1,2,4,5]);
  assert.equal(state.omittedRequests,1);
  assert.deepEqual(state.bulkAssociations,[file.associations[0]]);
  assert.equal(state.bulkRecords[0].values.Name,'Requested parent');
  assert.ok(state.bulkRecords.every(r=>!r.slot&&!r.loadedFromId));
  assert.equal(JSON.stringify(file),original);
});
