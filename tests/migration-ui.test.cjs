const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const {JSDOM}=require('jsdom');

test('native adapter renders the real shared migration dialog and retains fulfilled requests through Apply',async()=>{
  const dom=new JSDOM('<!doctype html><body></body>',{runScripts:'outside-only',url:'https://native.example/'});
  const w=dom.window,applied=[];
  try {
    w.SF_ORG_ID='destination';w.__ORGLOOM_NATIVE_IDENTITY__={orgName:'Test org'};
    w.OrgLoom={templates:{mount:()=>({})}};
    w.fetch=async url=>new Response(JSON.stringify(url.includes('/describe')?{
      name:'Account',label:'Account',labelPlural:'Accounts',recordTypes:[],
      fields:[{name:'Name',label:'Name',type:'string',createable:true,updateable:true,filterable:true,required:true}]
    }:{}));
    for(const file of ['vendor/upstream/packages/canvas/src/public/js/migrate-annotate.js','vendor/upstream/packages/canvas/src/public/js/migrate-match.js','web/migration.js'])w.eval(fs.readFileSync(file,'utf8'));
    const file={_meta:{forMigration:true},records:[
      {id:1,objectName:'Account',values:{Name:'Requested <customer> & "team"'},slot:{kind:'whole-record',slotId:1}},
      {id:2,objectName:'Account',values:{},slot:{kind:'whole-record',slotId:2}}
    ],associations:[]};
    const finished=w.OrgLoomNativeMigration.start(file,{},async p=>applied.push(p));
    async function until(predicate){for(let i=0;i<50;i++){if(predicate())return;await new Promise(r=>setImmediate(r));}assert.fail('UI did not settle');}
    await until(()=>w.document.querySelector('.mm-decision-card'));
    assert.equal(w.document.querySelectorAll('.mm-decision-card').length,1);
    assert.match(w.document.querySelector('.mm-record-decisions').textContent,/Requested <customer> & "team"/);
    assert.equal(w.document.querySelector('.mm-record-decisions customer'),null);
    assert.match(w.document.querySelector('.mm-decision-intro').textContent,/1 empty record request/);
    const primary=w.document.querySelector('[data-mm-primary]');
    assert.equal(primary.disabled,false);
    primary.click();assert.match(primary.textContent,/View summary/);
    primary.click();assert.match(primary.textContent,/Apply migration/);
    primary.click();
    assert.equal(await finished,true);
    assert.equal(applied.length,1);assert.equal(applied[0].records.length,1);
    assert.equal(applied[0].records[0].values.Name,'Requested <customer> & "team"');
    assert.equal(applied[0].records[0].slot,undefined);
  } finally {dom.window.close();}
});
