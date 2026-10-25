(() => {
  'use strict';
  const origin=window.__ORGLOOM_NATIVE_IDENTITY__.lightningOrigin;
  const pending=new Map();let connected=false,sequence=0;
  window.addEventListener('message',event=>{
    if(event.source!==window.parent||event.origin!==origin)return;
    if(event.data?.type==='orgloom-native-ready'){connected=true;return;}
    if(event.data?.type!=='orgloom-native-layout-result')return;
    const job=pending.get(event.data.id);if(!job)return;
    pending.delete(event.data.id);clearTimeout(job.timer);
    if(event.data.error)job.resolve(null);else job.resolve(event.data.data);
  });
  if(window.parent!==window&&origin)window.parent.postMessage({type:'orgloom-native-hello'},origin);
  function requestLayout(request){
    if(!connected)return Promise.resolve(null);
    return new Promise(resolve=>{
      const id='layout_'+(++sequence);
      const timer=setTimeout(()=>{pending.delete(id);resolve(null);},15000);
      pending.set(id,{resolve,timer});
      window.parent.postMessage({type:'orgloom-native-layout',id,request},origin);
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
