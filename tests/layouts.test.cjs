const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
function bridge(){
  const sent=[],timeouts=new Map();let listener;
  const parent={postMessage:(data,origin)=>sent.push({data,origin})};
  const window={parent,__ORGLOOM_NATIVE_IDENTITY__:{lightningOrigin:'https://org.lightning.force.com'},addEventListener:(_type,fn)=>{listener=fn;}};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../web/layouts.js'),'utf8'),{window,setTimeout:fn=>{const id=timeouts.size+1;timeouts.set(id,fn);return id;},clearTimeout:id=>timeouts.delete(id)});
  return {window,parent,sent,timeouts,receive:(data,origin='https://org.lightning.force.com',source=parent)=>listener({data,origin,source})};
}
test('standalone Visualforce keeps the Apex layout fallback',async()=>{
  const h=bridge(),base={available:false,recordTypeId:'012000000000000AAA',picklistValues:{}};
  assert.equal(await h.window.OrgLoomNativeLayouts.enrich(base,{objectName:'Account'},{fields:[]}),base);
});
test('layout messages require exact source, origin and request correlation and filter unreadable fields',async()=>{
  const h=bridge();h.receive({type:'orgloom-native-ready'},'https://evil.invalid');
  const base={available:false,recordTypeId:'012000000000000AAA'};
  assert.equal(await h.window.OrgLoomNativeLayouts.enrich(base,{objectName:'Account'},{fields:[]}),base);
  h.receive({type:'orgloom-native-ready'});
  const fields=[{name:'Name',label:'Account name',createable:true,updateable:false}];
  const result=h.window.OrgLoomNativeLayouts.enrich(base,{objectName:'Account',recordId:'001000000000000AAA'},{fields});
  const job=h.sent.at(-1);assert.equal(job.data.request.mode,'Edit');
  const response={type:'orgloom-native-layout-result',id:job.data.id,data:{sections:[{heading:'Details',layoutRows:[{layoutItems:[{layoutComponents:[{componentType:'Field',apiName:'Name'}]},{layoutComponents:[{componentType:'Field',apiName:'Secret__c'}]}]}]}]}};
  h.receive(response,'https://evil.invalid');h.receive(response,undefined,{});h.receive({...response,id:'unknown'});
  assert.equal(h.timeouts.size,1);
  h.receive(response);const layout=await result;
  assert.equal(layout.sections[0].rows[0].length,1);assert.equal(layout.sections[0].rows[0][0].apiName,'Name');
  assert.equal(layout.sections[0].rows[0][0].editableForUpdate,false);assert.equal(h.timeouts.size,0);
});
test('missing UI API response times out to the safe Apex fallback',async()=>{
  const h=bridge();h.receive({type:'orgloom-native-ready'});
  const base={available:false};const result=h.window.OrgLoomNativeLayouts.enrich(base,{objectName:'Account'},{fields:[]});
  [...h.timeouts.values()][0]();assert.equal(await result,base);
});
