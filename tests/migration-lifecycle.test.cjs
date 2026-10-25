const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
function migrationHarness(commit){
  const applied=[],requests=[];
  const window={SF_ORG_ID:'destination',__ORGLOOM_NATIVE_IDENTITY__:{orgName:'Destination test org'},OrgLoom:{templates:{mount:()=>({})}},Orgloom:{}};
  const context={window,Response,URL,Blob,document:{querySelector:()=>null},setTimeout};
  vm.runInNewContext(fs.readFileSync('vendor/upstream/packages/canvas/src/public/js/migrate-annotate.js','utf8'),context);
  window.fetch=async(url)=>{
    requests.push(url);
    return new Response(JSON.stringify(url.includes('/describe')?{name:'Account',fields:[{name:'Name',type:'string',createable:true,updateable:true}],recordTypes:[]}:{}));
  };
  window.OrgLoom.migrateMatch={mount:deps=>({open:({onClose})=>{
    Promise.resolve().then(async()=>{if(commit)await deps.onCommitPlan();onClose();}).catch(error=>{throw error;});
  }})};
  vm.runInNewContext(fs.readFileSync('web/migration.js','utf8'),context);
  return {window,applied,requests,apply:async p=>applied.push(p)};
}
test('cancelled migration never invokes the canvas replacement seam',async()=>{
  const h=migrationHarness(false),file={_meta:{forMigration:true,exportedFrom:'source'},records:[{id:1,objectName:'Account',values:{Name:'Migrating',Id:'source-id'}}],associations:[]};
  const original=JSON.stringify(file);
  assert.equal(await h.window.OrgLoomNativeMigration.start(file,{},h.apply),false);
  assert.equal(h.applied.length,0);assert.equal(JSON.stringify(file),original);
});
test('migration applies destination data only after explicit commit and fresh capability check',async()=>{
  const h=migrationHarness(true),file={_meta:{forMigration:true,exportedFrom:'source'},records:[{id:1,objectName:'Account',values:{Name:'Migrating',Id:'source-id'}}],associations:[]};
  assert.equal(await h.window.OrgLoomNativeMigration.start(file,{},h.apply),true);
  assert.equal(h.applied.length,1);assert.equal(h.applied[0]._meta.exportedFrom,'destination');assert.equal(h.applied[0].records[0].values.Id,undefined);
  assert.equal(h.requests.filter(url=>url==='/api/capabilities/bulk-edit-records/check').length,2);
});
