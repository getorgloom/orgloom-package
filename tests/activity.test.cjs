const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../web/activity.js'),'utf8');
const tick=()=>new Promise(resolve=>setTimeout(resolve,0));
async function fixture(){
  const {JSDOM}=await import('jsdom');
  const w=new JSDOM(`<form id="activity-filters"><select id="activity-action"><option>All actions</option></select><select id="activity-state"><option>All</option><option value="failed">Failed</option></select><input id="activity-from"><input id="activity-to"><input id="activity-search"><select id="activity-user"><option>All users</option></select><button id="activity-find" type="button"></button><button id="activity-refresh" type="button"></button></form><p id="activity-status"></p><table><tbody id="activity-rows"></tbody></table><button id="activity-prev"></button><span id="activity-page"></span><button id="activity-next"></button>`,{runScripts:'outside-only'}).window;
  const calls=[];w.Visualforce={remoting:{Manager:{invokeAction(remote,op,body,callback){calls.push({op,body:JSON.parse(body),callback});}}}};
  const reply=(index,data)=>calls[index].callback(JSON.stringify({status:200,data}),{status:true});
  w.eval(source);assert.equal(calls[0].body.action,'');assert.equal(calls[0].body.status,'');assert.equal(calls[0].body.userId,'');return {w,calls,reply};
}
const result=(rows=[],next=null)=>({rows,next,timeZone:'America/Phoenix',actions:{upload:'Upload to Salesforce'}});
test('activity safely renders summaries, paginates with filters, and preserves the current page on failure',async()=>{
  const {w,calls,reply}=await fixture();
  try{
    reply(0,result([{when:'2026-10-23T12:00:00Z',action:'Upload',status:'success',user:'<img src=x>',detail:'<script>bad()</script>',reference:'ref'}],{beforeId:'cursor1',beforeAt:'2026-10-23T12:00:00Z'}));await tick();
    assert.equal(w.document.querySelector('#activity-rows img,#activity-rows script'),null);assert.match(w.document.getElementById('activity-rows').textContent,/<script>bad/);
    w.document.getElementById('activity-next').click();assert.equal(calls[1].body.beforeId,'cursor1');reply(1,result());await tick();
    assert.equal(w.document.getElementById('activity-page').textContent,'Page 2');assert.equal(w.document.getElementById('activity-next').disabled,true);
    w.document.getElementById('activity-prev').click();calls[2].callback(null,{status:false});await tick();
    assert.equal(w.document.getElementById('activity-page').textContent,'Page 2');assert.match(w.document.getElementById('activity-status').textContent,/Try again/);
    w.document.getElementById('activity-state').value='failed';w.document.getElementById('activity-refresh').click();assert.equal(calls[3].body.status,'failed');assert.equal(calls[3].body.beforeId,undefined);
    reply(3,result());await tick();assert.equal(w.document.getElementById('activity-page').textContent,'Page 1');
  }finally{w.close();}
});
test('user filter uses server user IDs and cannot inject markup',async()=>{
  const {w,calls,reply}=await fixture();try{
    reply(0,result());await tick();w.document.getElementById('activity-search').value='Example';w.document.getElementById('activity-find').click();
    assert.equal(calls[1].op,'users');assert.equal(calls[1].body.search,'Example');reply(1,[{Id:'005example',Name:'<img src=x>',Username:'example'}]);await tick();
    assert.equal(w.document.querySelector('#activity-user img'),null);w.document.getElementById('activity-user').value='005example';w.document.getElementById('activity-refresh').click();assert.equal(calls[2].body.userId,'005example');
  }finally{w.close();}
});
test('activity is available only in the administrator permission set',()=>{
  const root=path.join(__dirname,'../force-app/main/default');
  const admin=fs.readFileSync(path.join(root,'permissionsets/OrgLoomNative_Admin.permissionset-meta.xml'),'utf8');
  const canvas=fs.readFileSync(path.join(root,'permissionsets/OrgLoomNativePrototype.permissionset-meta.xml'),'utf8');
  assert.match(admin,/<apexClass>OrgLoomNativeActivity<\/apexClass>/);assert.match(admin,/<tab>OrgLoomNativeActivity<\/tab>/);assert.doesNotMatch(canvas,/OrgLoomNativeActivity/);
});
