(() => {
  'use strict';
  const identity=window.__ORGLOOM_NATIVE_IDENTITY__;
  const remote=window.__ORGLOOM_NATIVE_REMOTE__;
  let capabilities={};
  // Retain only two boolean guide preferences in real storage. Never expose the
  // storage handle to the canvas, which must keep record/recovery data in memory.
  let preferenceStorage,recoveryStorage;
  try { preferenceStorage=window.localStorage; } catch (_) { /* storage blocked */ }
  try { recoveryStorage=window.sessionStorage; } catch (_) { /* storage blocked */ }
  const recoveryKey='orgloom:native:recovery:'+identity.orgId+':'+identity.userId;
  const guideScope=identity.orgId && identity.userId
    ? 'orgloom:native:guide:'+encodeURIComponent(identity.orgId)+':'+encodeURIComponent(identity.userId)+':' : null;
  const guideFlags=new Set(['dismissed','completed']);
  window.OrgLoomNativeOnboarding={
    completeOnFirstRecord:true,
    getFlag(name){
      if(!guideScope || !guideFlags.has(name))return false;
      try{return preferenceStorage?.getItem(guideScope+name)==='1';}catch(_){return false;}
    },
    setFlag(name){
      if(!guideScope || !guideFlags.has(name))return;
      try{preferenceStorage?.setItem(guideScope+name,'1');}catch(_){/* shared runtime flag remains */}
    },
  };
  // Do not use persistent browser storage for live records.
  for(const name of ['localStorage','sessionStorage']) {
    const map=new Map();
    Object.defineProperty(window,name,{value:{get length(){return map.size},key:i=>[...map.keys()][i]??null,getItem:k=>map.get(String(k))??null,setItem:(k,v)=>map.set(String(k),String(v)),removeItem:k=>map.delete(String(k)),clear:()=>map.clear()},configurable:false});
  }
  Object.assign(window,{SF_ORG_ID:identity.orgId,SF_USER_ID:identity.userId,SF_USER_NAME:identity.displayName,SF_USER_TIME_ZONE:identity.timeZone,SF_INSTANCE_URL:identity.instanceUrl,
    ORGLOOM_ACCOUNT_ID:'salesforce-native',ORGLOOM_SF_CONNECTED:true,ORGLOOM_HAS_DOCS:false,ORGLOOM_CANVAS_PATH:location.pathname,ORGLOOM_MOCK:false,ORGLOOM_MCP_ACTIVE:false,ORGLOOM_SENTRY_DSN:null,ORGLOOM_ENV:'native-prototype'});
  let uploading=false,uncertain=false,uncertainAttempt=null;
  const sessions=new Map(),versions=new Map(),recallReviews=new Map();let activeCanvas=null,sessionEnded=false,activatedAt=0,heartbeatPending=false;
  // Resume this tab's canvas lease after refresh without treating a duplicated
  // tab as the same editor. A Web Lock protects the copied sessionStorage key.
  // Only canvas IDs and canvas-scoped lease tokens are retained, never payloads
  // or Salesforce credentials. The server still validates the user and token.
  const leaseKey='orgloom:native:canvas-session:'+identity.orgId+':'+identity.userId+':'+remote;
  let leaseCache=null;
  const randomLeaseId=()=>Array.from(crypto.getRandomValues(new Uint8Array(32)),b=>b.toString(16).padStart(2,'0')).join('');
  function holdLeaseCache(id){
    return new Promise(resolve=>{
      navigator.locks.request(leaseKey+':'+id,{ifAvailable:true},lock=>{
        if(!lock){resolve(false);return;}
        resolve(true);return new Promise(()=>{}); // Released automatically when this document closes.
      }).catch(()=>resolve(false));
    });
  }
  function rememberLease(id,token){
    if(!leaseCache)return;
    const value={id:leaseCache};
    if(id&&token){value.canvasId=id;value.token=token;}
    try{recoveryStorage.setItem(leaseKey,JSON.stringify(value));}catch{/* In-memory access still works. */}
  }
  const leaseReady=(async()=>{
    if(!recoveryStorage||!navigator.locks?.request)return;
    try{
      let stored;
      try{stored=JSON.parse(recoveryStorage.getItem(leaseKey)||'null');}catch{/* Ignore malformed metadata. */}
      if(!/^[a-f0-9]{64}$/.test(stored?.id||''))stored={id:randomLeaseId()};
      if(!await holdLeaseCache(stored.id)){
        // A duplicated tab inherits sessionStorage, but may not inherit authority.
        stored={id:randomLeaseId()};
        if(!await holdLeaseCache(stored.id))return;
      }
      leaseCache=stored.id;
      if(/^[a-zA-Z0-9]{15,18}$/.test(stored.canvasId||'')&&/^[a-f0-9]{64}$/.test(stored.token||'')){
        sessions.set(stored.canvasId,stored.token);
        rememberLease(stored.canvasId,stored.token);
      }else rememberLease();
    }catch{/* No safe tab identity available: retain the normal takeover checks. */}
  })();
  let partialNotice=null,partialCanvas=null,partialOpenedAt=0;
  function showPartialView(partial,id){
    partialNotice?.remove();partialNotice=null;
    partialCanvas=partial?id:null;partialOpenedAt=Date.now();
    if(!partial)return;
    partialNotice=document.createElement('div');partialNotice.id='native-partial-view';partialNotice.setAttribute('role','status');
    partialNotice.textContent='You’re seeing the records and fields your Salesforce access permits. Hidden content is preserved when you save. Cards with hidden content or connections may remain in the saved canvas if you remove them here.';
    (document.querySelector?.('#native-notices')||document.body).append(partialNotice);
  }
  function call(operation,body) {
    return new Promise((resolve,reject)=>{
      Visualforce.remoting.Manager.invokeAction(remote,operation,JSON.stringify(body),(result,event)=>{
        if(!event.status){reject(new Error('Salesforce did not confirm the request. '+(event.message||'')));return;}
        try{resolve(JSON.parse(result));}catch{reject(new Error('Invalid Salesforce response.'));}
      },{escape:false,buffer:false,timeout:120000});
    });
  }
  window.OrgLoomNativeRecoveryHost={
    getKey(){try{return recoveryStorage?.getItem(recoveryKey)||null;}catch{return null;}},
    setKey(key){
      if(key!=null&&!/^[a-f0-9]{64}$/.test(key))throw Error('Invalid recovery identifier.');
      if(!recoveryStorage)throw Error('Browser session storage is unavailable. Save your canvas before refreshing.');
      if(key==null)recoveryStorage.removeItem(recoveryKey);else recoveryStorage.setItem(recoveryKey,key);
    },
    async request(op,body){await leaseReady;const reply=await call('recovery:'+op,body);if(reply.status!==200)throw Error(reply.data?.message||'Recovery request failed.');return reply.data;},
    async openSaved(id){
      const reply=await canvasCall('open',{id});
      if(reply.status!==200)throw Error(reply.data?.message||'The saved canvas could not be opened.');
      return reply.data;
    },
    session(id){return sessions.get(id);},
    blocked(){return sessionEnded||uploading||uncertain;},
    end:message=>endSession(message),
    adopt(data){
      if(data.id&&data.sessionToken){activeCanvas=data.id;activatedAt=Date.now();sessions.set(data.id,data.sessionToken);versions.set(data.id,data.versionId);rememberLease(data.id,data.sessionToken);}
      showPartialView(data.partialView===true,data.id);
    },
  };
  const response=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{'Content-Type':'application/json'}});
  function endSession(message) {
    if(sessionEnded)return;sessionEnded=true;
    rememberLease();
    const blocker=document.createElement('div');blocker.id='native-session-ended';blocker.setAttribute('role','alertdialog');blocker.setAttribute('aria-modal','true');
    const heading=document.createElement('h2');heading.textContent='Canvas session ended';
    const text=document.createElement('p');text.textContent=message.replace('SESSION_ENDED: ','')+' Your unsaved work remains in this tab, but this session cannot save or upload.';
    const reload=document.createElement('button');reload.textContent='Reload app';reload.onclick=()=>{if(confirm('Reload and discard unsaved changes in this tab?'))location.reload();};
    blocker.append(heading,text,reload);
    for(const element of Array.from(document.body.children||[]))element.inert=true;
    document.body.append(blocker);reload.focus?.();
  }
  async function canvasCall(op,body){
    await leaseReady;
    if(sessionEnded)throw Error('This canvas session has ended.');
    const saving=['save','create','fill','delete','request'].includes(op);
    if(saving)await window.OrgLoomNativeRecovery?.beforeSave?.();
    const id=body.id;if(id&&sessions.has(id))body.sessionToken=sessions.get(id);
    if(op==='fill')body.expectedVersionId=versions.get(id);
    let result;
    try{result=await call('canvas:'+op,body);}
    catch(error){if(saving)await window.OrgLoomNativeRecovery?.saved?.(false);throw error;}
    const occupiedMessage=result.data?.message;
    if(op==='open'&&result.status!==200&&/^OCCUPIED(?:_SELF)?: /.test(occupiedMessage||'')){
      const ownSession=occupiedMessage.startsWith('OCCUPIED_SELF: ');
      const escapeHtml=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
      const dialog=window.OrgLoom.uiFeedback.mount({escapeHtml,getGraph:()=>document.querySelector('.graph-overlay')});
      const accepted=await dialog.showConfirmDialog({
        title:ownSession?'Canvas open in another session':'Canvas already open',
        message:ownSession
          ? 'You already have this canvas open in another tab or window.\n\nContinue here using the latest saved version? The other session will lose editing access, and its unsaved changes won’t transfer.'
          : occupiedMessage.replace('OCCUPIED: ','')+'\n\nTake over using the latest saved version? Their session will lose editing access, and their unsaved changes won’t transfer.',
        confirmLabel:ownSession?'Continue here':'Take over',
        cancelLabel:'Cancel',
      });
      if(!accepted)throw Error('Canvas takeover cancelled.');
      result=await call('canvas:open',{...body,takeover:true});
    }
    if(result.status===200&&result.data?.versionId)versions.set(result.data.id||id,result.data.versionId);
    if(result.status===200&&(op==='open'||op==='create'))showPartialView(result.data?.partialView===true,result.data?.id);
    if(result.status===200&&op==='delete'){
      sessions.delete(id);versions.delete(id);if(activeCanvas===id){activeCanvas=null;rememberLease();}
    }
    if(result.status===200&&result.data?.sessionToken){
      if(activeCanvas&&activeCanvas!==result.data.id)release(activeCanvas);
      activeCanvas=result.data.id;activatedAt=Date.now();sessions.set(activeCanvas,result.data.sessionToken);
      rememberLease(activeCanvas,result.data.sessionToken);
    }
    // Request saves leave other edits dirty. The caller rebases recovery after
    // adopting the new revision; do not retire its checkpoint as a full save.
    if(saving&&(op!=='request'||result.status!==200))await window.OrgLoomNativeRecovery?.saved?.(result.status===200);
    if(result.status!==200&&result.data?.message?.includes('SESSION_ENDED:'))endSession(result.data.message.replace('SESSION_ENDED: ',''));
    return result;
  }
  function release(id){
    const sessionToken=sessions.get(id);sessions.delete(id);
    if(activeCanvas===id){activeCanvas=null;rememberLease();}
    if(sessionToken)call('canvas:release',{id,sessionToken}).catch(()=>{}); // Expiry handles transport failure.
  }
  // The pinned frontend owns canvas replacement. Release after it has applied a
  // successful response, or after a failed load leaves the previous canvas active.
  setInterval(()=>{
    if(activeCanvas&&Date.now()-activatedAt>10000&&window.Orgloom?.canvasState?.getCurrentCanvas&&window.Orgloom.canvasState.getCurrentCanvas()?.canvasId!==activeCanvas)release(activeCanvas);
    if(partialCanvas&&Date.now()-partialOpenedAt>10000&&window.Orgloom?.canvasState?.getCurrentCanvas&&window.Orgloom.canvasState.getCurrentCanvas()?.canvasId!==partialCanvas)showPartialView(false);
  },5000);
  async function heartbeat(){
    if(!activeCanvas||sessionEnded||heartbeatPending)return;
    const id=activeCanvas;heartbeatPending=true;
    try{const result=await call('canvas:heartbeat',{id,sessionToken:sessions.get(id)});if(activeCanvas===id&&result.status!==200)endSession(result.data?.message||'Access to this canvas is no longer available.');}
    catch{if(activeCanvas===id)endSession('Salesforce could not confirm that your session is still active.');}
    finally{heartbeatPending=false;}
  }
  // Faster takeover detection while visible; retain the background lease cadence.
  // These checks never save a canvas or create recovery checkpoints.
  const checkVisibleSession=()=>{if(!document.hidden)return heartbeat();};
  setInterval(checkVisibleSession,5000);
  setInterval(()=>{if(document.hidden)return heartbeat();},30000);
  document.addEventListener?.('visibilitychange',checkVisibleSession);
  window.addEventListener?.('focus',checkVisibleSession);
  async function route(path,method,body) {
    const url=new URL(path,location.origin),p=url.pathname;
    if(p==='/api/me'||p==='/api/me/capabilities'){
      const reply=await call('capabilities',{});if(reply.status!==200)return reply;
      capabilities=reply.data.capabilities;
      if(p==='/api/me/capabilities')return reply;
      return {account:{id:identity.userId,displayName:identity.displayName},workspace:{id:identity.orgId,plan:'team'},connection:{id:'native',sfOrgId:identity.orgId,sfUserId:identity.userId,instanceUrl:identity.instanceUrl},capabilities};
    }
    if(p==='/api/workspaces')return [];
    if(p==='/api/upload-batches'&&method==='GET')return call('history:list',Object.fromEntries(url.searchParams));
    const history=/^\/api\/upload-batches\/([A-Za-z0-9]{15,18})(?:\/(recall-preflight|recall))?$/.exec(p);
    if(history){
      const id=history[1];
      if(method==='DELETE'&&!history[2])return call('history:forget',{id});
      if(method==='POST'&&history[2]==='recall-preflight'){const result=await call('history:preflight',{id});if(result.status===200)recallReviews.set(id,result.data.nativeReviewToken);return result;}
      if(method==='POST'&&history[2]==='recall')return call('history:recall',{...body,id,nativeReviewToken:recallReviews.get(id)});
    }
    if(p==='/api/audit-event')return {ok:true,persisted:false};
    if(p==='/api/canvas'&&['GET','POST'].includes(method))return canvasCall(method==='POST'?'create':'list',body);
    if(p==='/api/sf/users/search'&&method==='GET')return call('shareUsers',Object.fromEntries(url.searchParams));
    if(p==='/api/migrate/match'&&method==='POST')return call('migrationMatch',body);
    const requestChange=/^\/api\/canvas\/([A-Za-z0-9]{15,18})\/request-change$/.exec(p);
    if(requestChange&&method==='POST')return canvasCall('request',{...body,id:requestChange[1]});
    const sharing=/^\/api\/canvas\/([A-Za-z0-9]{15,18})\/(share-links|direct-share|slot-fill|direct-shares\/([A-Za-z0-9]{15,18}))$/.exec(p);
    if(sharing){
      const id=sharing[1];
      if(sharing[2]==='share-links'&&method==='GET')return canvasCall('shares',{id});
      if(sharing[2]==='direct-share'&&method==='POST')return canvasCall('grant',{...body,id});
      if(sharing[3]&&['PATCH','DELETE'].includes(method))return canvasCall('grant',{...body,id,recipientSfUserId:sharing[3],role:method==='DELETE'?'none':body.role});
      if(sharing[2]==='slot-fill'&&method==='POST')return canvasCall('fill',{...body,id});
    }
    const saved=/^\/api\/canvas\/([A-Za-z0-9]{15,18})$/.exec(p);
    if(saved&&['GET','PUT','DELETE'].includes(method))return canvasCall(method==='PUT'?'save':method==='DELETE'?'delete':'open',{...body,id:saved[1]});
    if(p==='/api/native/record-link'&&method==='POST'){
      if(sessionEnded)throw Error('This canvas session has ended.');
      if(activeCanvas){const check=await call('canvas:heartbeat',{id:activeCanvas,sessionToken:sessions.get(activeCanvas)});if(check.status!==200){endSession(check.data?.message||'Canvas access ended.');return check;}}
      return call('loadRecordLink',{recordId:body.recordId});
    }
    if(p==='/api/objects')return call('objects',{});
    if(p==='/api/browse'&&method==='POST')return call('browse',body);
    if(p==='/api/query'&&method==='POST'){
      const selected=/^\s*SELECT\s+Id\s+FROM\s+\w+\s+WHERE\s+Id\s+IN\s*\(/i.test(body.soql||'');
      return call(selected&&capabilities['browse-records']?'browseLoad':selected&&capabilities['bulk-edit-records']?'fileLoad':'query',body);
    }
    const featureCheck=/^\/api\/capabilities\/(export-canvas|export-records|bulk-edit-records|run-script|auto-fill-records)\/check$/.exec(p);
    if(featureCheck&&method==='POST'){
      const params={capability:featureCheck[1]};
      if(['run-script','auto-fill-records'].includes(params.capability)){
        if(sessionEnded)throw Error('This canvas session has ended.');
        if(activeCanvas){params.canvasId=activeCanvas;params.sessionToken=sessions.get(activeCanvas);}
      }
      return call('capabilityCheck',params);
    }
    const related=/^\/api\/objects\/(\w+)\/(related-count|by-ref|by-ref-search|search|lookup)$/.exec(p);
    if(related)return call('reads:'+related[2],{...Object.fromEntries(url.searchParams),objectName:related[1]});
    if(p==='/api/records/refresh'&&method==='POST')return call('reads:refresh',body);
    const m=/^\/api\/objects\/(\w+)\/(describe|layout|graph|validation-rules|records\/([A-Za-z0-9]+))$/.exec(p);
    if(m) {
      if(m[3])return call('record',{objectName:m[1],recordId:m[3]});
      if(m[2]==='describe')return call('describe',{objectName:m[1]});
      if(m[2]==='layout'){
        const params={...Object.fromEntries(url.searchParams),objectName:m[1]};
        const base=await call('layout',params);if(base.status!==200||!window.OrgLoomNativeLayouts)return base;
        const describe=await call('describe',{objectName:m[1]});if(describe.status!==200)return describe;
        base.data=await window.OrgLoomNativeLayouts.enrich(base.data,params,describe.data);return base;
      }
      if(m[2]==='graph')return call('reads:graph',{objectName:m[1]});
      return {unavailable:true,reason:'Salesforce validates writes; rule metadata is not exposed in this MVP.'};
    }
    if(p==='/api/upload/access-check')return {ok:true};
    if(p==='/api/records/access')return call('access',body);
    if(p==='/api/related-counts'&&method==='POST'){
      const counts=[];
      if(!Array.isArray(body.probes)||body.probes.length>200)throw Error('At most 200 relationship probes per batch.');
      // Each remoting transaction has its own Apex query budget. Keep chunks
      // sequential to avoid saturating the org with background prefetch calls.
      for(let i=0;i<body.probes.length;i+=25){
        const result=await call('reads:counts',{probes:body.probes.slice(i,i+25)});
        if(result.status!==200)return result;
        counts.push(...result.data.counts);
      }
      return {counts};
    }
    if(p.startsWith('/api/upload-attempts/')){
      // The reused upload UI calls this endpoint when the user selects recovery.
      // Seal the old plan before declaring any missing batch safe to retry.
      const attemptId=decodeURIComponent(p.split('/').pop());
      const result=await call('uploadRecovery',{attemptId});
      if(attemptId===uncertainAttempt&&result.status===200&&result.data?.status==='completed'){uncertain=false;uncertainAttempt=null;}
      return result;
    }
    if(['/api/upload','/api/upload/graph'].includes(p)&&method==='POST') {
      if(uploading||uncertain)throw Error('Upload is blocked. An earlier result is unconfirmed; inspect Salesforce before making further changes.');
      if(sessionEnded)throw Error('This canvas session has ended.');
      if(body.canvasId)body.nativeSessionToken=sessions.get(body.canvasId);
      if(body.deletes?.length){
        const records=window.Orgloom?.canvasState?.snapshot?.()?.payload?.loadedRecords||[];
        for(const deletion of body.deletes){const record=records.find(r=>r.loadedFromId===deletion.sfId);if(record?.values?.LastModifiedDate)deletion.loadedValues={LastModifiedDate:record.values.LastModifiedDate};}
      }
      uploading=true;
      try {
        const plan=await call('uploadPlan',body);
        if(plan.status!==200)return plan;
        const groups=plan.data?.groups;
        if(!Array.isArray(groups)||!groups.length)throw Error('Salesforce did not return an upload plan.');
        // Retire pre-upload recovery before the first business write. The shared
        // completion hook resumes checkpoints after results reach canvas state.
        await window.OrgLoomNativeRecovery?.beforeUpload?.();
        // The shared upload review already supplies the user's explicit confirmation.
        const combined={status:'completed',results:[],deletes:[],canonicalValues:{},instanceUrl:identity.instanceUrl};
        for(let index=0;index<groups.length;index++){
          let result;
          try {result=await call('uploadGroup',{rootAttemptId:body.attemptId,index,payload:groups[index]});}
          catch {uncertain=true;uncertainAttempt=body.attemptId;return {status:409,data:{error:'upload-attempt-incomplete',message:'Salesforce did not confirm a batch. Earlier batches may have committed. Recover this attempt before uploading again.'}};}
          if(result.status!==200||!Array.isArray(result.data?.results)){
            uncertain=true;uncertainAttempt=body.attemptId;return {status:409,data:{error:'upload-attempt-incomplete',message:result.data?.message||'The upload stopped. Recover confirmed results before uploading again.'}};
          }
          combined.results.push(...result.data.results);combined.deletes.push(...(result.data.deletes||[]));
          Object.assign(combined.canonicalValues,result.data.canonicalValues||{});
        }
        return combined;
      }finally{uploading=false;}
    }
    throw Error('This operation is not enabled in Org Loom yet.');
  }
  window.fetch=async(input,init={})=>{
    try {
      const path=typeof input==='string'?input:input?.url;
      if(typeof path!=='string'||!path.startsWith('/api/')||path.startsWith('//'))throw Error('External requests are disabled.');
      const result=await route(path,(init.method||'GET').toUpperCase(),init.body?JSON.parse(init.body):{});
      return result?.status&&Object.hasOwn(result,'data')?response(result.data,result.status):response(result);
    }catch(e){return response({error:'native-mvp',message:e.message},400);}
  };
  window.WebSocket=window.EventSource=function(){throw Error('Live collaboration is not enabled.');};
  navigator.sendBeacon=()=>false;
})();
