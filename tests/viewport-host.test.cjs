const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');

function setup(){
  const source=fs.readFileSync(path.join(__dirname,'../force-app/main/default/lwc/orgLoomNativeHost/orgLoomNativeHost.js'),'utf8')
    .replace(/^import .*;\r?\n/gm,'').replace(/@wire\([^\n]*?\) /g,'')
    .replace('export default class OrgLoomNativeHost','globalThis.Host = class OrgLoomNativeHost');
  const callbacks=new Map(),listeners=new Set();let next=0,top=160;
  const viewport={height:800,offsetTop:0,addEventListener:(_,f)=>listeners.add(f),removeEventListener:(_,f)=>listeners.delete(f)};
  const window={innerHeight:800,visualViewport:viewport,addEventListener:(n,f)=>listeners.add(f),removeEventListener:(n,f)=>listeners.delete(f),
    requestAnimationFrame:f=>{callbacks.set(++next,f);return next;},cancelAnimationFrame:id=>callbacks.delete(id)};
  const context={LightningElement:class{},window,document:{documentElement:{},scrollingElement:{}}};vm.runInNewContext(source,context);
  const host=new context.Host();host.template={querySelector:()=>({getBoundingClientRect:()=>({top})})};
  const flush=()=>{const jobs=[...callbacks.values()];callbacks.clear();jobs.forEach(f=>f());};
  return {host,window,viewport,callbacks,listeners,flush,setTop:v=>top=v};
}
test('canvas fits the remaining viewport at different Lightning header and window sizes',()=>{
  const h=setup();h.host.renderedCallback();h.flush();assert.equal(h.host.viewportStyle,'height:640px');
  h.setTop(205.5);h.viewport.height=600;h.host.resizeListener();h.flush();assert.equal(h.host.viewportStyle,'height:394px');
  h.viewport.height=300;h.host.resizeListener();h.flush();assert.equal(h.host.viewportHeight,94);
  h.viewport.offsetTop=15;h.host.resizeListener();h.flush();assert.equal(h.host.viewportHeight,109);
  h.window.visualViewport=null;h.window.innerHeight=900;h.host.resizeListener();h.flush();assert.equal(h.host.viewportHeight,694);
  h.setTop(950);h.host.resizeListener();h.flush();assert.equal(h.host.viewportHeight,0);
});
test('resize work is coalesced and removed when navigating away',()=>{
  const h=setup();h.host.connectedCallback();h.host.renderedCallback();h.host.resizeListener();assert.equal(h.callbacks.size,1);
  h.host.disconnectedCallback();assert.equal(h.callbacks.size,0);assert.equal(h.listeners.size,0);
  h.host.template.querySelector=()=>null;h.host.renderedCallback();h.flush();assert.equal(h.host.viewportHeight,undefined);
});

test('Lightning padding and scrolling do not extend the canvas beyond its workspace',()=>{
  const h=setup();
  const parent={parentElement:null,scrollTop:0,clientTop:0,clientHeight:600,getBoundingClientRect:()=>({top:100})};
  h.host.hostElement={parentElement:parent};
  h.window.getComputedStyle=()=>({overflowY:'auto',paddingBottom:'12px',marginBottom:'0px',borderBottomWidth:'0px'});
  h.setTop(112);h.host.renderedCallback();h.flush();assert.equal(h.host.viewportHeight,576);
  parent.scrollTop=40;h.setTop(72);h.host.resizeListener();h.flush();assert.equal(h.host.viewportHeight,576);
});
