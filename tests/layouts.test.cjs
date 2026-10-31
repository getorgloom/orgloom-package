const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
function bridge(standalone=false,postMessage){
  const sent=[],timeouts=new Map();let listener;
  const parent={postMessage:(wire,origin)=>{
    assert.equal(typeof wire,'string','Lightning boundary must carry JSON strings');
    if(postMessage)postMessage(wire,origin);
    sent.push({data:JSON.parse(wire),origin});
  }};
  const window={parent,__ORGLOOM_NATIVE_IDENTITY__:{lightningOrigin:'https://org.lightning.force.com'},addEventListener:(_type,fn)=>{listener=fn;}};
  if(standalone)window.parent=window;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../web/layouts.js'),'utf8'),{window,setTimeout:fn=>{const id=timeouts.size+1;timeouts.set(id,fn);return id;},clearTimeout:id=>timeouts.delete(id)});
  return {window,parent,sent,timeouts,receive:(data,origin='https://org.lightning.force.com',source=parent)=>listener({data,origin,source})};
}
test('standalone Visualforce keeps the Apex layout fallback',async()=>{
  const h=bridge(true),base={available:false,recordTypeId:'012000000000000AAA',picklistValues:{}};
  assert.equal(await h.window.OrgLoomNativeLayouts.enrich(base,{objectName:'Account'},{fields:[]}),base);
});

test('JSON handshake and response preserve origin and source checks',async()=>{
  const h=bridge(),base={available:false,recordTypeId:'012000000000000AAA'};
  h.receive('{invalid JSON');
  h.receive(JSON.stringify({type:'orgloom-native-ready'}),'https://evil.invalid');
  const result=h.window.OrgLoomNativeLayouts.enrich(base,{objectName:'Account'},{fields:[]});
  assert.equal(h.sent.filter(m=>m.data.type==='orgloom-native-layout').length,0);
  h.receive(JSON.stringify({type:'orgloom-native-ready'}));
  const id=h.sent.at(-1).data.id;
  const response=JSON.stringify({type:'orgloom-native-layout-result',id,error:'Unavailable'});
  h.receive(response,undefined,{});assert.equal(h.timeouts.size,1);
  h.receive(response);assert.equal(await result,base);assert.equal(h.timeouts.size,0);
});

test('a failed postMessage falls back immediately and can recover after readiness',async()=>{
  let fail=false;
  const h=bridge(false,()=>{if(fail)throw new Error('Security boundary rejected message');});
  const base={available:false,recordTypeId:'012000000000000AAA'};
  fail=true;
  assert.equal(await h.window.OrgLoomNativeLayouts.enrich(base,{objectName:'Account'},{fields:[]}),base);
  assert.equal(h.timeouts.size,0);
  assert.equal(await h.window.OrgLoomNativeLayouts.enrich(base,{objectName:'Contact'},{fields:[]}),base);
  fail=false;h.receive(JSON.stringify({type:'orgloom-native-ready'}));
  const result=h.window.OrgLoomNativeLayouts.enrich(base,{objectName:'Account'},{fields:[]});
  h.receive(JSON.stringify({type:'orgloom-native-layout-result',id:h.sent.at(-1).data.id,error:'No layout'}));
  assert.equal(await result,base);assert.equal(h.timeouts.size,0);
});

test('initial handshake failure does not prevent canvas startup',async()=>{
  const h=bridge(false,()=>{throw new Error('postMessage unavailable');});
  const base={available:false};
  assert.equal(await h.window.OrgLoomNativeLayouts.enrich(base,{objectName:'Account'},{fields:[]}),base);
  assert.equal(h.timeouts.size,0);
});
test('layout messages require exact source, origin and request correlation and filter unreadable fields',async()=>{
  const h=bridge();h.receive({type:'orgloom-native-ready'},'https://evil.invalid');
  const base={available:false,recordTypeId:'012000000000000AAA'};
  assert.equal(h.sent.filter(message=>message.data.type==='orgloom-native-layout').length,0);
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

test('draft layouts wait for a late Lightning handshake and dispatch only once',async()=>{
  const h=bridge(),base={available:false,recordTypeId:'012000000000000AAA'};
  const account=h.window.OrgLoomNativeLayouts.enrich(base,{objectName:'Account'},{fields:[{name:'Name',label:'Account Name',createable:true,updateable:true}]});
  const contact=h.window.OrgLoomNativeLayouts.enrich(base,{objectName:'Contact'},{fields:[{name:'LastName',label:'Last Name',createable:true,updateable:true}]});
  assert.equal(h.sent.filter(message=>message.data.type==='orgloom-native-layout').length,0);
  assert.equal(h.timeouts.size,2);
  h.receive({type:'orgloom-native-ready'},'https://evil.invalid');
  h.receive({type:'orgloom-native-ready'},undefined,{});
  assert.equal(h.sent.filter(message=>message.data.type==='orgloom-native-layout').length,0);
  h.receive({type:'orgloom-native-ready'});
  h.receive({type:'orgloom-native-ready'});
  const requests=h.sent.filter(message=>message.data.type==='orgloom-native-layout');
  assert.equal(requests.length,2);
  for(const {data} of requests){
    assert.equal(data.request.mode,'Create');
    const apiName=data.request.objectApiName==='Account'?'Name':'LastName';
    h.receive({type:'orgloom-native-layout-result',id:data.id,data:{sections:[{heading:data.request.objectApiName+' Information',layoutRows:[{layoutItems:[{layoutComponents:[{componentType:'Field',apiName}]}]}]}]}});
  }
  const results=await Promise.all([account,contact]);
  assert.equal(results[0].sections[0].heading,'Account Information');
  assert.equal(results[1].sections[0].heading,'Contact Information');
  assert.ok(results.every(layout=>layout.available));assert.equal(h.timeouts.size,0);
});

test('an unavailable Lightning bridge eventually falls back and does not dispatch expired requests',async()=>{
  const h=bridge(),base={available:false};
  const result=h.window.OrgLoomNativeLayouts.enrich(base,{objectName:'Account'},{fields:[]});
  [...h.timeouts.values()][0]();assert.equal(await result,base);
  h.receive({type:'orgloom-native-ready'});
  assert.equal(h.sent.filter(message=>message.data.type==='orgloom-native-layout').length,0);
});
test('missing UI API response times out to the safe Apex fallback',async()=>{
  const h=bridge();h.receive({type:'orgloom-native-ready'});
  const base={available:false};const result=h.window.OrgLoomNativeLayouts.enrich(base,{objectName:'Account'},{fields:[]});
  [...h.timeouts.values()][0]();assert.equal(await result,base);
});
