(() => {
  'use strict';
  const status=document.getElementById('status'), user=document.getElementById('user'), rows=document.getElementById('features');
  function call(op,body) {return new Promise((resolve,reject)=>Visualforce.remoting.Manager.invokeAction(window.__ORGLOOM_ADMIN_REMOTE__,op,JSON.stringify(body),(result,event)=>{
    if(!event.status)return reject(new Error(event.message||'Salesforce did not confirm the change.'));
    try {const response=JSON.parse(result);if(response.status!==200)throw Error(response.data.message);resolve(response.data);}catch(e){reject(e);}
  },{escape:false,buffer:false,timeout:30000}));}
  function error(e){status.textContent=e.message;}
  let generation=0,busy=false;
  async function refresh() {
    const own=++generation;rows.replaceChildren();if(!user.value)return;
    const features=await call('features',{userId:user.value});if(own!==generation)return;
    features.sort((a,b)=>a.label.localeCompare(b.label));
    for(const f of features){const tr=document.createElement('tr');const label=document.createElement('td');label.textContent=f.label;tr.append(label);
      for(const [operation,key] of [['grant','assigned'],['policy','enabled']]){
        const td=document.createElement('td'),box=document.createElement('input');box.type='checkbox';box.checked=f[key];box.disabled=!f.implemented;box.setAttribute('aria-label',`${f.label}: ${operation==='grant'?'assigned to selected user':'enabled for org'}`);
        box.addEventListener('change',async()=>{
          if(busy){box.checked=!box.checked;return;}busy=true;user.disabled=true;document.getElementById('find').disabled=true;rows.querySelectorAll('input').forEach(el=>el.disabled=true);
          try{await call(operation,{userId:user.value,capability:f.id,enabled:box.checked});status.textContent='Saved. Existing Salesforce permissions still apply.';}catch(e){error(e);}finally{busy=false;user.disabled=false;document.getElementById('find').disabled=false;await refresh().catch(error);}
        });td.append(box);tr.append(td);
      }
      const state=document.createElement('td');state.textContent=f.implemented?'Available':'Not implemented yet';tr.append(state);rows.append(tr);
    }
  }
  async function find(){if(busy)return;status.textContent='Loading users…';const users=await call('users',{search:document.getElementById('search').value});user.replaceChildren();const placeholder=document.createElement('option');placeholder.value='';placeholder.textContent='Select a user';user.append(placeholder);for(const u of users){const option=document.createElement('option');option.value=u.Id;option.textContent=`${u.Name} (${u.Username})`;user.append(option);}status.textContent=users.length?'':'No active users match.';await refresh();}
  document.getElementById('find').addEventListener('click',()=>find().catch(error));user.addEventListener('change',()=>refresh().catch(error));
  document.getElementById('search').addEventListener('keydown',e=>{if(e.key==='Enter'){e.preventDefault();find().catch(error);}});find().catch(error);
})();
