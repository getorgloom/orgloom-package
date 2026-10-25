(() => {
  'use strict';
  const host=window.OrgLoomNativeRecoveryHost;
  const random=()=>Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('');
  let key=null,writer=random(),sequence=0,context=null,started=false,stopped=false;
  let snapshotContext=null,confirmed='',observed='',changedAt=0,dirtySince=0,retryAt=0,uploadPaused=false,savePaused=false;
  let queue=Promise.resolve(),status,resolveReady;
  const ready=new Promise(resolve=>{resolveReady=resolve;});
  const serialize=fn=>{const result=queue.then(fn);queue=result.catch(()=>{});return result;};
  function notice(message,error=false){
    if(!status){status=document.createElement('div');status.id='native-recovery-status';status.setAttribute('role','status');document.body.append(status);}
    status.textContent=message;status.dataset.error=String(error);
  }
  function fail(error){
    retryAt=Date.now()+30000;
    notice('Refresh recovery unavailable. Save before refreshing. '+error.message,true);
    if(String(error.message).includes('RECOVERY_STALE:')){stopped=true;host.end('This recovery session is no longer current. '+error.message.replace('RECOVERY_STALE: ',''));}
  }
  async function retire(){
    const old=key;
    if(old)await host.request('discard',{key:old,writer});
    if(old)host.setKey(null);key=null;sequence=0;confirmed='';observed='';snapshotContext=null;
  }
  function snapshot(){
    const data=context.snapshot();
    if(!data)return null;
    const payload=data.payload;
    if(!(payload.loadedRecords?.length||payload.drafts?.length||payload.schema?.objects?.length))return null;
    // A JSON copy freezes the request while the user continues editing.
    return JSON.parse(JSON.stringify({canvasId:data.isDraft?null:data.id,versionId:data.isDraft?null:data.versionId,contextId:data.id,payload}));
  }
  async function checkpoint(value,signature){
    const scope=value.contextId+':'+(value.versionId||'');
    if(snapshotContext&&scope!==snapshotContext)await retire();
    if(!key){const next=random();host.setKey(next);key=next;writer=random();sequence=0;}
    snapshotContext=scope;
    const {contextId,...body}=value;
    const result=await host.request('write',{...body,key,writer,sequence:++sequence,sessionToken:host.session(value.canvasId)});
    confirmed=signature;dirtySince=0;
    notice('Recovery checkpoint '+new Date(result.savedAt).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'})+(result.partialView?' · inaccessible content omitted':''));
  }
  async function tick(){
    if(!started||stopped||savePaused||uploadPaused||host.blocked()||context.busy()||Date.now()<retryAt)return;
    if(context.readOnly())return;
    try{
      const value=snapshot();
      if(!value){if(key)await serialize(retire);return;}
      const signature=JSON.stringify(value),now=Date.now();
      if(signature===confirmed)return;
      if(signature!==observed){observed=signature;changedAt=now;if(!dirtySince)dirtySince=now;}
      if(now-changedAt<2000&&now-dirtySince<10000)return;
      await serialize(async()=>{
        if(stopped||savePaused||uploadPaused||host.blocked()||context.busy())return;
        const current=snapshot();
        if(current&&JSON.stringify(current)===signature&&confirmed!==signature)await checkpoint(current,signature);
      });
    }catch(error){fail(error);}
  }
  const api=window.OrgLoomNativeRecovery={
    ready:()=>ready,
    async mount(value){
      context=value;
      const mask=document.createElement('div');mask.id='native-recovery-loading';mask.textContent='Checking for unsaved work…';document.body.append(mask);
      let restored=false;
      try{
        await context.ready;
        key=host.getKey();
        if(key&&!/^[a-f0-9]{64}$/.test(key)){key=null;host.setKey(null);}
        if(key){
          const info=await host.request('peek',{key});
          if(info.available){
            const yes=await context.confirm({title:'Restore unsaved work?',message:'A recovery checkpoint from '+new Date(info.savedAt).toLocaleString()+' is available for this tab. Restore it?\n\nIf this tab was duplicated, continuing here ends editing in the other session. Only changes in the last successful checkpoint can be recovered.',confirmLabel:'Restore',cancelLabel:'Discard'});
            sequence=Number(info.sequence);
            if(yes){
              const data=await host.request('restore',{key,writer,sequence});host.adopt(data);
              await context.restore(data);restored=true;
              const current=snapshot();snapshotContext=current?current.contextId+':'+(current.versionId||''):null;
              confirmed=current?JSON.stringify(current):'';
              context.toast('Restored your last recovery checkpoint. Review your changes before uploading.','info');
              notice('Unsaved work restored');
            }else{
              await host.request('discard',{key,writer,sequence,reviewed:true});host.setKey(null);key=null;
            }
          }else{host.setKey(null);key=null;}
        }
        started=true;
      }catch(error){
        // Do not overwrite a checkpoint when its lookup/restore failed. Keep the
        // pointer so a later refresh can retry after connectivity is restored.
        stopped=true;notice('Recovery could not be restored. '+error.message+' Save any new work before refreshing.',true);
      }finally{mask.remove();resolveReady(restored);}
      setInterval(tick,2000);
      document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='hidden')void tick();});
    },
    async discard(){
      if(!started||stopped)return;
      await serialize(retire);notice('Recovery draft discarded');
    },
    async beforeSave(){savePaused=true;await queue;},
    captureSaved(){
      if(!started||stopped)return;
      // Called by the shared save-state model after applying a confirmed save
      // or open. New edits made after this instant still differ from baseline.
      const value=snapshot(),baseline=value?JSON.stringify(value):'';
      void serialize(async()=>{if(key)await retire();confirmed=baseline;observed=baseline;notice('Canvas saved · recovery starts with your next edit');}).catch(fail);
    },
    async saved(success=true){
      try{if(success&&key)await serialize(retire);}catch(error){notice('Saved, but the old recovery checkpoint could not be removed. '+error.message,true);}
      finally{savePaused=false;}
    },
    async beforeUpload(){
      uploadPaused=true;
      try{await serialize(retire);notice('Recovery paused while upload results are applied');}
      catch(error){uploadPaused=false;throw error;}
    },
    uploadStateApplied(){
      // This shared-runtime callback runs only after upload journal/results have
      // reached canvas state. An unconfirmed attempt stays blocked by the host.
      if(!host.blocked()){uploadPaused=false;retryAt=0;}
    },
  };
})();
