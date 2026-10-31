(() => {
  'use strict';
  const origin=window.__ORGLOOM_NATIVE_IDENTITY__.lightningOrigin;
  const pending=new Map();let connected=false,sequence=0,sendFailed=false;
  function send(message){
    // JSON strings cross Lightning's security boundary without object proxies.
    try{window.parent.postMessage(JSON.stringify(message),origin);return true;}
    catch{
      connected=false;sendFailed=true;
      for(const job of pending.values()){clearTimeout(job.timer);job.resolve(null);}
      pending.clear();return false;
    }
  }
  function dispatch(id,job){
    if(job.sent)return;
    job.sent=true;
    send({type:'orgloom-native-layout',id,request:job.request});
  }
  window.addEventListener('message',event=>{
    if(event.source!==window.parent||event.origin!==origin)return;
    let message=event.data;
    if(typeof message==='string'){try{message=JSON.parse(message);}catch{return;}}
    if(message?.type==='orgloom-native-ready'){
      connected=true;sendFailed=false;
      for(const [id,job] of pending)dispatch(id,job);
      return;
    }
    if(message?.type!=='orgloom-native-layout-result')return;
    const job=pending.get(message.id);if(!job)return;
    pending.delete(message.id);clearTimeout(job.timer);
    if(message.error)job.resolve(null);else job.resolve(message.data);
  });
  if(window.parent!==window&&origin)send({type:'orgloom-native-hello'});
  function requestLayout(request){
    if(window.parent===window||!origin||sendFailed)return Promise.resolve(null);
    return new Promise(resolve=>{
      const id='layout_'+(++sequence);
      const timer=setTimeout(()=>{pending.delete(id);resolve(null);},15000);
      const job={resolve,timer,request,sent:false};
      pending.set(id,job);
      if(connected)dispatch(id,job);
      // The initial hello can precede the Lightning host's listener. Keep the
      // request queued until readiness, and retry the handshake for this request.
      else send({type:'orgloom-native-hello'});
    });
  }
  function normalize(layout,fields){
    const byName=new Map(fields.map(f=>[f.name,f]));
    return (layout?.sections||[]).map(section=>({heading:section.heading,columns:section.columns||2,collapsible:section.collapsible,
      rows:(section.layoutRows||[]).map(row=>(row.layoutItems||[]).map(item=>{
        const names=(item.layoutComponents||[]).filter(c=>c.componentType==='Field'&&byName.has(c.apiName)).map(c=>c.apiName);
        if(!names.length)return null;
        const field=byName.get(names[0]);
        return {apiName:names[0],...(names.length>1?{apiNames:names}:{}),label:item.label||field.label,required:!!item.required||field.required,
          editableForNew:item.editableForNew!==false&&field.createable,editableForUpdate:item.editableForUpdate!==false&&field.updateable};
      }).filter(Boolean)).filter(row=>row.length)})).filter(section=>section.rows.length);
  }
  window.OrgLoomNativeLayouts={async enrich(base,params,describe){
    const layout=await requestLayout({objectApiName:params.objectName,recordTypeId:base.recordTypeId,mode:params.mode==='view'?'View':params.recordId?'Edit':'Create'});
    if(!layout)return base;
    const fields=describe.fields||[],sections=normalize(layout,fields);
    return {...base,available:sections.length>0,sections,columns:layout.columns||2,
      fieldPerms:Object.fromEntries(fields.map(f=>[f.name,{createable:f.createable,updateable:f.updateable}]))};
  }};
})();
