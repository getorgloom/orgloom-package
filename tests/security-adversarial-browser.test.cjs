'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),http=require('node:http');
const {chromium}=require('playwright');
const root=path.resolve(__dirname,'..'),output=path.join(root,'test-results/security');
const marker='OL_SECURITY_EXECUTED';
const payloads=[
  `console.log('${marker}')`,
  `<img src=x onerror="console.log('${marker}');window.__dataExecuted=true">`,
  `<svg onload="console.log('${marker}');window.__dataExecuted=true"></svg>`,
  `</textarea><img src=x onerror="console.log('${marker}')">`,
  `</script><script>console.log('${marker}');window.__dataExecuted=true</script>`,
  `" autofocus onfocus="console.log('${marker}')" data-attack="`,
  `javascript:console.log('${marker}')`,
  `&#60;img src=x onerror=console.log('${marker}')&#62;`,
  `${'${'}console.log('${marker}')}`,
];

test('packaged canvas treats hostile JSON, CSV, editor and migration values as data',async()=>{
  const logs=[],errors=[],network=[],calls=[];
  const identity={orgId:'00D000000000001AAA',userId:'005000000000001AAA',displayName:'Security fixture',timeZone:'UTC',instanceUrl:'https://fixture.my.salesforce.com',lightningOrigin:'https://fixture.lightning.force.com'};
  const fields=[{name:'Id',type:'id'},{name:'Name',type:'string',nameField:true,createable:true,updateable:true},{name:'Description',type:'textarea',createable:true,updateable:true},{name:'Website',type:'url',createable:true,updateable:true}].map(f=>({label:f.name,nillable:f.name!=='Name',length:32000,...f}));
  const describe={name:'Account',label:'Account',labelPlural:'Accounts',keyPrefix:'001',createable:true,updateable:true,deletable:true,fields,recordTypes:[],childRelationships:[]};
  const caps=Object.fromEntries(['browse-records','soql-import','upload-records','bulk-edit-records','save-canvas','open-saved-canvas','share-canvas','run-script','auto-fill-records','recall-upload','export-canvas','export-records'].map(k=>[k,true]));
  function remote(op,body){
    calls.push({op,body});let data;
    if(op==='capabilities')data={capabilities:caps,edition:'team'};
    else if(op==='objects')data=[describe];
    else if(op==='describe')data=describe;
    else if(op==='capabilityCheck')data={ok:true};
    else if(op==='layout')data={available:false,fields,sections:[],fieldPerms:Object.fromEntries(fields.map(f=>[f.name,{createable:f.createable,updateable:f.updateable}]))};
    else if(op==='canvas:list'||op==='history:list')data=[];
    else if(op==='migrationMatch')data={matches:[],records:[]};
    else if(op==='recovery:write')data={savedAt:new Date().toISOString()};
    else if(op==='recovery:discard')data={ok:true};
    else if(op==='reads:graph')data={nodes:[],edges:[]};
    else if(op==='reads:counts')data={counts:[]};
    else return {status:400,data:{message:'Fixture does not implement '+op}};
    return {status:200,data};
  }
  let origin;
  const server=http.createServer((req,res)=>{
    if(req.url==='/'){
      // Use the generated Visualforce page and its exact script order. Replace
      // only server template expressions and the platform remoting boundary.
      // Deliberately add NO CSP: escaping must stand on its own, without a
      // synthetic policy hiding an injection that Salesforce might allow.
      const source=fs.readFileSync(path.join(root,'force-app/main/default/pages/OrgLoomNative.page'),'utf8');
      const html=source.replace(/<\/?apex:page[^>]*>/g,'').replace(/\{!URLFOR\(\$Resource.OrgLoomNativeAssets, '([^']+)'\)\}/g,'/$1')
        .replace(/<script>window\.__ORGLOOM_NATIVE_IDENTITY__[\s\S]*?<\/script>/,'<script>window.__ORGLOOM_NATIVE_IDENTITY__='+JSON.stringify(identity)+';window.__ORGLOOM_NATIVE_REMOTE__="fixture.invoke";</script>');
      res.setHeader('Content-Type','text/html');res.end(html);return;
    }
    const url=new URL(req.url,origin).pathname;
    const base=url.startsWith('/native/')?path.join(root,'web'):url.startsWith('/vendor/')?path.join(root,'vendor/libraries'):path.join(root,'vendor/upstream/packages/canvas/src/public');
    const relative=url.replace(/^\/(native|vendor)\//,'/');
    const file=path.resolve(base,'.'+relative);
    if(!file.startsWith(base+path.sep)||!fs.existsSync(file)){res.statusCode=404;res.end();return;}
    res.setHeader('Content-Type',file.endsWith('.js')?'application/javascript':file.endsWith('.css')?'text/css':'application/octet-stream');res.end(fs.readFileSync(file));
  });
  await new Promise(r=>server.listen(0,'127.0.0.1',r));origin='http://127.0.0.1:'+server.address().port;
  let browser,page;
  fs.mkdirSync(output,{recursive:true});
  try{
    browser=await chromium.launch({headless:true,...(process.env.SECURITY_BROWSER_EXECUTABLE?{executablePath:process.env.SECURITY_BROWSER_EXECUTABLE}:{})});
    page=await browser.newPage({viewport:{width:1500,height:1000}});
    page.on('console',m=>logs.push(m.text()));page.on('pageerror',e=>errors.push(e.message));
    await page.route('**/*',route=>{if(!route.request().url().startsWith(origin+'/')){network.push(route.request().url());return route.abort();}return route.continue();});
    await page.exposeFunction('securityNativeRemote',remote);
    await page.addInitScript(identity=>{
      for(const name of ['dismissed','completed'])localStorage.setItem('orgloom:native:guide:'+identity.orgId+':'+identity.userId+':'+name,'1');
      window.Visualforce={remoting:{Manager:{invokeAction:(_remote,op,raw,callback)=>window.securityNativeRemote(op,JSON.parse(raw)).then(reply=>callback(JSON.stringify(reply),{status:true}))}}};
    },identity);
    await page.goto(origin);
    await page.getByRole('button',{name:'+ Add records',exact:true}).waitFor();
    const filePayload={_meta:{app:'Org Loom',version:1,exportedFrom:identity.orgId},schema:{objects:[]},records:payloads.map((value,i)=>({id:i+1,objectName:'Account',label:payloads[1],values:{Name:value,Description:value,Website:value},x:(i%3)*350,y:Math.floor(i/3)*240})),associations:[]};
    await page.getByRole('button',{name:'+ Add records',exact:true}).click();
    await page.locator('[data-add-menu="fixture"]').click();
    await page.locator('.import-canvas-modal input[type=file]').setInputFiles({name:'hostile.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify(filePayload))});
    await page.waitForFunction(()=>document.querySelectorAll('.record-card').length===9);
    await page.getByRole('button',{name:'Fit canvas',exact:true}).click();
    await page.screenshot({path:path.join(output,'before-editors.png')});
    for(let i=0;i<payloads.length;i++){
      // Cytoscape's overlay receives the pointer; the HTML label is visual only.
      await page.locator(`.record-card[data-rec-id="${i+1}"] .record-title`).dblclick({force:true,timeout:5000});
      const editor=page.locator('.modal.is-inline').last();
      await editor.locator('.field[data-field="Name"] input').waitFor();
      assert.equal(await editor.locator('.field[data-field="Name"] input').inputValue(),payloads[i]);
      assert.equal(await editor.locator('.field[data-field="Description"] textarea').inputValue(),payloads[i]);
      assert.equal(await page.locator('img[onerror],svg[onload],[data-attack]').count(),0);
      await editor.locator('.modal-close[data-close]').click();
    }
    await page.screenshot({path:path.join(output,'hostile-records.png')});
    await page.evaluate(payload=>{
      for(const record of payload.records)record.values.Missing__c=record.values.Description;
      window.__migrationReview=window.OrgLoomNativeMigration.start(payload,{},async()=>{});
    },filePayload);
    await page.waitForSelector('.mm-decision-card');await page.locator('[data-mm-primary]').click();
    assert.ok((await page.locator('.mm-differences').innerText()).includes(marker));
    assert.equal(await page.locator('img[onerror],svg[onload],[data-attack]').count(),0);
    await page.locator('[data-mm-close]').click();
    await page.getByRole('button',{name:'+ Add records',exact:true}).click();await page.locator('[data-add-menu="fixture"]').click();
    await page.locator('.import-canvas-modal input[type=file]').setInputFiles({name:'malformed.json',mimeType:'application/json',buffer:Buffer.from('{"Name":'+payloads[1])});
    await page.getByText(/Could not load file:/).waitFor();
    await page.locator('.import-canvas-modal .modal-close').click();
    const cell=value=>'"'+value.replaceAll('"','""')+'"';
    await page.getByRole('button',{name:'+ Add records',exact:true}).click();await page.locator('[data-add-menu="csv"]').click();
    await page.locator('#lcsv-file-input').setInputFiles({name:'Account.csv',mimeType:'text/csv',buffer:Buffer.from('Name,Description\r\n'+payloads.map(value=>cell(value)+','+cell(value)).join('\r\n'))});
    await page.locator('#linked-csv-confirm').click();
    await page.waitForFunction(()=>document.querySelectorAll('.record-card').length===18);
    assert.equal(await page.locator('img[onerror],svg[onload],[data-attack]').count(),0);
    assert.equal(await page.evaluate(()=>window.__dataExecuted),undefined);
    assert.ok(!logs.includes(marker));assert.deepEqual(network,[]);assert.deepEqual(errors,[]);
    assert.ok(!calls.some(c=>/^upload/.test(c.op)),'Rendering cannot trigger a Salesforce upload');
    // Positive control: this harness has no CSP, so the console monitor really
    // detects an executable inline script if one ever slips into rendered data.
    await page.evaluate(()=>{const s=document.createElement('script');s.textContent='console.log("OL_SECURITY_MONITOR_CONTROL")';document.body.append(s);});
    assert.ok(logs.includes('OL_SECURITY_MONITOR_CONTROL'));
    fs.writeFileSync(path.join(output,'browser.json'),JSON.stringify({payloads:payloads.length,surfaces:['JSON imports','record cards','record editors','migration decisions','migration field differences','malformed JSON errors','CSV imports'],executedPayloads:0,unexpectedNetwork:network,unhandledErrors:errors,csp:'None added; escaping tested independently of Salesforce CSP',remote:'Mocked Visualforce boundary; production native adapter and generated page script order'},null,2));
  }catch(error){
    fs.writeFileSync(path.join(output,'browser-failure.json'),JSON.stringify({error:error.stack,errors,logs,network,calls,text:page?await page.locator('body').innerText():''},null,2));throw error;
  }finally{await browser?.close();await new Promise(r=>server.close(r));}
});
