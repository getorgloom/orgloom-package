// Compatibility interfaces for the pinned canvas bootstrap. AI/MCP/live-sync implementations
// are not shipped. Contributor saves use the native request endpoint; other
// edits remain local until the user explicitly saves the canvas.
(() => {
  const ns=window.OrgLoom=window.OrgLoom||{}, noop=()=>{}, local=async()=>({ok:true,localOnly:true});
  ns.aiGenerate={mount:()=>({openModal:noop,checkStatus:async()=>false,isEnabled:()=>false,getAccessState:()=>({allowed:false,visible:false})})};
  ns.aiProposals={mount:()=>({getPollCanvasId:()=>null,openProposalsReview:noop,refreshProposals:noop,watchProposalsForCurrentCanvas:noop})};
  ns.presence={mount:({canvasState,csrfFetch})=>({
    beginCanvasLoad:()=>noop,subscribeToCanvas:noop,unsubscribe:noop,pushFocus:noop,publishLayout:noop,publishChanges:noop,
    noteLocalSave:noop,fieldLockFor:()=>null,acquireFieldLock:local,
    async commitRecordFields(record,fields,options){
      options?.beforeCommit?.();
      const current=canvasState.currentCanvas;
      const role=canvasState._renderCanvasShareRole||(current&&!current.ownedByMe?current.recipientRole:null);
      if(role==='viewer')throw Error('This canvas is view only.');
      if(role!=='contributor')return {ok:true,localOnly:true};
      if(!current?.id||record?.slot?.slotId==null)throw Error('This record is no longer an active contributor request.');
      if(!Object.keys(fields||{}).length)return {ok:true,localOnly:true};
      const response=await csrfFetch('/api/canvas/'+encodeURIComponent(current.id)+'/slot-fill',{
        method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},
        body:JSON.stringify({fills:[{slotId:record.slot.slotId,values:fields,
          relationshipFields:options?.relationshipFields||[]}]}),
      });
      const data=await response.json().catch(()=>null);
      if(!response.ok||data?.submitted!==1||!data.versionId){
        throw Error(data?.message||'The request could not be saved. Your changes have not been submitted.');
      }
      // A completed whole-record request becomes a regular draft. Contributors
      // may still edit requested fields, but cannot edit that completed draft.
      if(canvasState.currentCanvas===current){
        current.versionId=data.versionId;
        if(record.slot.kind!=='fields')delete record.slot;
      }
      return data;
    },
    releaseFieldLock:noop,releaseRecordFieldLocks:noop,acknowledgedContributionIds:()=>[],markContributionIdsSaved:noop
  })};
})();
