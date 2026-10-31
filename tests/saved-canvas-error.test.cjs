const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require('jsdom');

test('saved canvas permission errors show the server explanation instead of the native error code',async()=>{
  const dom=new JSDOM('<div id="popup"></div>',{runScripts:'outside-only'});
  try {
    const {window}=dom,pop=window.document.getElementById('popup');
    window.eval(fs.readFileSync(path.join(__dirname,'../vendor/upstream/packages/canvas/src/public/js/canvas-save-load.js'),'utf8'));
    const message='Your administrator must grant access to Open saved canvases.';
    const dependencies=new Proxy({
      canvasState:{currentCanvas:null,bulkRecords:[],selectedObjects:[]},
      csrfFetch:async()=>({ok:false,status:400,json:async()=>({error:'native-request-rejected',message})}),
      escapeHtml:s=>{const el=window.document.createElement('span');el.textContent=s;return el.innerHTML;},
      summarizeCanvasContent:()=>({hasContent:false}),
      _openAnchoredPopup:()=>({pop,cleanup(){}}),
    },{get:(target,key)=>key in target?target[key]:()=>null});
    const api=window.OrgLoom.canvasSaveLoad.mount(dependencies);
    await api.showBrowseSavedMenu(null);
    assert.equal(pop.querySelector('#browse-sf-list').textContent,'Unable to load saved canvases. '+message);
    assert.doesNotMatch(pop.textContent,/native-request-rejected|HTTP 400/);
    assert(pop.querySelector('[data-new-canvas]'),'New canvas action stays available');
  } finally {dom.window.close();}
});
