(() => {
  const adapt=()=>{
    document.querySelectorAll('a[href^="/docs/"]').forEach(link=>{link.href='https://orgloom.com'+link.getAttribute('href');link.target='_blank';link.rel='noopener noreferrer';});
    document.querySelectorAll('[data-bulk-ops]').forEach(el=>{el.title='Canvas tools';});
    document.querySelectorAll('[data-bulk-upload]').forEach(el=>{el.title='Upload: up to 500 records in atomic batches of at most 200, with Salesforce permissions enforced.';});
    document.querySelectorAll('[data-editor-element="insert-form"]').forEach(form=>{
      const sections=form.querySelectorAll('.field-section');const section=sections.length===1?sections[0]:null;
      if(section?.dataset.section==='optional'&&!section.dataset.nativeExpanded){section.dataset.nativeExpanded='true';if(section.classList.contains('collapsed'))section.querySelector('[data-toggle]')?.click();}
    });
    if(window.Orgloom?.canvasState)document.getElementById('native-status').hidden=true;
  };
  new MutationObserver(adapt).observe(document.body,{childList:true,subtree:true});adapt();
})();
