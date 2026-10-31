(() => {
  const adapt=()=>{
    document.querySelectorAll('a[href^="/docs/"]').forEach(link=>{link.href='https://orgloom.com'+link.getAttribute('href');link.target='_blank';link.rel='noopener noreferrer';});
    document.querySelectorAll('[data-bulk-ops]').forEach(el=>{el.title='Canvas tools';});
    const recordsBar=document.getElementById('subbar-records');
    if(recordsBar&&!recordsBar.querySelector('[data-native-fit-canvas]')){
      const button=document.createElement('button');
      button.type='button';button.className='batch-btn';button.dataset.nativeFitCanvas='';
      button.textContent='Fit canvas';button.title='Fit all records in view';
      button.addEventListener('click',()=>window.OrgLoomNativeViewport.fit());
      recordsBar.insertBefore(button,recordsBar.querySelector('.bulk-hint-spacer'));
    }
    document.querySelectorAll('.upload-btn').forEach(el=>{
      for(const node of el.childNodes){
        if(node.nodeType===3&&node.textContent.includes('Upload to Salesforce'))node.textContent=node.textContent.replace('Upload to Salesforce','Upload');
      }
    });
    document.querySelectorAll('[data-bulk-upload]').forEach(el=>{el.title='Upload: up to 500 records in atomic batches of at most 200, with Salesforce permissions enforced.';});
    // Linked fields identify the related card without opening another editor.
    document.querySelectorAll('button[data-open-assoc-field]').forEach(button=>{
      const label=document.createElement('span');
      label.className='assoc-record-link native-assoc-record-label';
      label.id=button.id;
      label.title=button.title;
      label.append(...button.childNodes);
      button.replaceWith(label);
    });
    document.querySelectorAll('[data-editor-element="insert-form"]').forEach(form=>{
      const sections=form.querySelectorAll('.field-section');const section=sections.length===1?sections[0]:null;
      if(section?.dataset.section==='optional'&&!section.dataset.nativeExpanded){section.dataset.nativeExpanded='true';if(section.classList.contains('collapsed'))section.querySelector('[data-toggle]')?.click();}
    });
    if(window.Orgloom?.canvasState)document.getElementById('native-status').hidden=true;
  };
  new MutationObserver(adapt).observe(document.body,{childList:true,subtree:true});adapt();
})();
