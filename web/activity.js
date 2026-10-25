(() => {
  'use strict';
  const el=id=>document.getElementById(`activity-${id}`), rows=el('rows'), status=el('status');
  // Visualforce omits empty HTML attributes; restore empty filter values so
  // the browser does not submit the visible "All ..." label as an action/ID.
  for(const id of ['action','state','user'])el(id).options[0].value='';
  let cursors=[null],page=0,next=null,busy=false,filters={};
  function call(op,body){return new Promise((resolve,reject)=>Visualforce.remoting.Manager.invokeAction(window.__ORGLOOM_ACTIVITY_REMOTE__,op,JSON.stringify(body),(result,event)=>{
    if(!event.status)return reject(new Error('Salesforce could not load activity. Try again.'));
    try{const response=JSON.parse(result);if(response.status!==200)throw new Error(response.data.message);resolve(response.data);}catch(e){reject(e);}
  },{escape:false,buffer:false,timeout:30000}));}
  function buttons(){el('filters').querySelectorAll('input,select,button').forEach(node=>node.disabled=busy);el('prev').disabled=busy||page===0;el('next').disabled=busy||!next;}
  function readFilters(){return {action:el('action').value,status:el('state').value,from:el('from').value,to:el('to').value,userId:el('user').value};}
  function cell(tr,text){const td=document.createElement('td');td.textContent=text??'';tr.append(td);return td;}
  async function load(target=0,reset=false){
    if(busy)return;busy=true;buttons();status.textContent='Loading activity…';
    const requested=reset?readFilters():filters;
    try{
      const data=await call('list',{...requested,...(reset?{}:cursors[target]||{})});
      if(reset){filters=requested;cursors=[null];}page=target;next=data.next;
      if(next)cursors[page+1]=next;
      rows.replaceChildren();
      for(const row of data.rows){
        const tr=document.createElement('tr');cell(tr,new Date(row.when).toLocaleString(undefined,{timeZone:data.timeZone}));cell(tr,row.action);
        const state=cell(tr,({success:'Success',partial:'Partial',failed:'Failed'})[row.status]||row.status);state.className=`status-${row.status}`;
        cell(tr,row.user);const detail=cell(tr,row.detail);
        if(row.reference){const reference=document.createElement('small');reference.textContent=`Reference: ${row.reference}`;detail.append(reference);}rows.append(tr);
      }
      if(!data.rows.length){const tr=document.createElement('tr');cell(tr,'No activity matches these filters.').colSpan=5;rows.append(tr);}
      const action=el('action');if(action.options.length===1)for(const [value,label] of Object.entries(data.actions).sort((a,b)=>a[1].localeCompare(b[1]))){const option=document.createElement('option');option.value=value;option.textContent=label;action.append(option);}
      el('page').textContent=`Page ${page+1}`;status.textContent='';
    }catch(e){status.textContent=e.message;}finally{busy=false;buttons();}
  }
  el('filters').addEventListener('submit',e=>{e.preventDefault();load(0,true);});
  el('refresh').addEventListener('click',()=>load(0,true));el('prev').addEventListener('click',()=>load(page-1));el('next').addEventListener('click',()=>load(page+1));
  el('find').addEventListener('click',async()=>{
    if(busy)return;busy=true;buttons();status.textContent='Finding users…';
    try{const users=await call('users',{search:el('search').value});const select=el('user');select.replaceChildren();const all=document.createElement('option');all.value='';all.textContent='All users';select.append(all);
      for(const user of users){const option=document.createElement('option');option.value=user.Id;option.textContent=`${user.Name} (${user.Username})`;select.append(option);}status.textContent=users.length?'Choose a user, then apply filters.':'No matching users.';
    }catch(e){status.textContent=e.message;}finally{busy=false;buttons();}
  });
  load(0,true);
})();
