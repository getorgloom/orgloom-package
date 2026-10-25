const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {JSDOM}=require('jsdom');
const root=path.resolve(__dirname,'..');

test('takeover confirmation stays above the active canvas loading mask and remains dismissible',async()=>{
  const dom=new JSDOM('<html><head></head><body class="canvas-page"><div class="canvas-replacement-loading">Loading canvas…</div></body></html>',{runScripts:'outside-only'});
  const w=dom.window;
  try{
    for(const file of ['vendor/upstream/packages/canvas/src/public/css/app.css','web/native.css']){
      const style=w.document.createElement('style');style.textContent=fs.readFileSync(path.join(root,file),'utf8');w.document.head.append(style);
    }
    w.eval(fs.readFileSync(path.join(root,'vendor/upstream/packages/canvas/src/public/js/ui-feedback.js'),'utf8'));
    const dialogs=w.OrgLoom.uiFeedback.mount({escapeHtml:value=>String(value),getGraph:()=>null});
    for(const accept of [false,true]){
      const pending=dialogs.showConfirmDialog({title:'Canvas open in another session',message:'Continue here?',confirmLabel:'Continue here',cancelLabel:'Cancel'});
      const modal=w.document.querySelector('.app-confirm-modal');
      const mask=w.document.querySelector('.canvas-replacement-loading');
      assert.ok(Number(w.getComputedStyle(modal).zIndex)>Number(w.getComputedStyle(mask).zIndex),'takeover must be above the loading overlay');
      assert.equal(w.getComputedStyle(modal).position,'fixed');
      await new Promise(resolve=>w.setTimeout(resolve,1));
      modal.querySelector(accept?'[data-cf-confirm]':'[data-cf-cancel]').click();
      assert.equal(await pending,accept);
      assert.equal(w.document.querySelector('.app-confirm-modal'),null);
    }
  }finally{w.close();}
});
