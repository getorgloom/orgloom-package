const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');

function host(){
  // Exercise the production message handlers without needing a Salesforce wire runtime.
  const source=fs.readFileSync(path.join(__dirname,'../force-app/main/default/lwc/orgLoomNativeHost/orgLoomNativeHost.js'),'utf8')
    .replace(/^import .*;\r?\n/gm,'').replace(/@wire\([^\n]*?\) /g,'')
    .replace('export default class OrgLoomNativeHost','globalThis.Host = class OrgLoomNativeHost');
  const context={LightningElement:class{},window:{requestAnimationFrame:()=>1}};
  vm.runInNewContext(source,context);
  const sent=[],frame={contentWindow:{postMessage:(value,origin)=>{
    assert.equal(typeof value,'string');sent.push({data:JSON.parse(value),origin});
  }}};
  const instance=new context.Host();
  instance.config={visualforceOrigin:'https://org.vf.force.com'};
  instance.template={querySelector:()=>frame};
  return {instance,sent,receive:(data,origin=instance.config.visualforceOrigin,source=frame.contentWindow)=>instance.receive({data,origin,source})};
}

test('Lightning host uses JSON for handshake and proxied layout replies',()=>{
  const h=host();h.receive(JSON.stringify({type:'orgloom-native-hello'}));
  assert.equal(h.sent[0].data.type,'orgloom-native-ready');
  assert.equal(h.sent[0].origin,'https://org.vf.force.com');
  const request={type:'orgloom-native-layout',id:'layout_1',request:{objectApiName:'Account',recordTypeId:'012000000000000AAA',mode:'Edit'}};
  h.receive(JSON.stringify(request));assert.equal(h.instance.jobs.length,1);
  const layout=new Proxy({sections:[{heading:'Account Information'}]},{});
  assert.throws(()=>structuredClone(layout));
  h.instance.completed({stopPropagation(){},detail:{id:'layout_1',data:layout}});
  assert.equal(h.instance.jobs.length,0);
  assert.equal(h.sent[1].data.data.sections[0].heading,'Account Information');
});

test('Lightning host rejects malformed or untrusted serialized messages',()=>{
  const h=host(),hello=JSON.stringify({type:'orgloom-native-hello'});
  h.receive(hello,'https://evil.invalid');h.receive(hello,undefined,{});
  h.receive('{bad JSON');h.receive('null');
  h.receive(JSON.stringify({type:'orgloom-native-layout',id:'layout_1',request:{objectApiName:'Account',recordTypeId:'bad',mode:'Edit'}}));
  assert.equal(h.sent.length,0);assert.equal(h.instance.jobs.length,0);
});
