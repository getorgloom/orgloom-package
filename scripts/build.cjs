const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),yazl=require('yazl');
const root=path.resolve(__dirname,'..'),upstream=path.join(root,'vendor/upstream');
const manifest=require('../vendor/source-manifest.json');
const files=dir=>fs.readdirSync(dir,{withFileTypes:true}).flatMap(e=>e.isDirectory()?files(path.join(dir,e.name)):[path.join(dir,e.name)]);
const pinned=files(upstream);
if(pinned.length!==Object.keys(manifest.files).length)throw Error('Pinned source file count changed.');
for(const file of pinned){const key=path.relative(upstream,file).replaceAll('\\','/');if(crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')!==manifest.files[key])throw Error('Pinned source changed: '+key);}
for(const [relative,hash] of Object.entries(require('../vendor/key-service/manifest.json'))){
  if(crypto.createHash('sha256').update(fs.readFileSync(path.join(root,'vendor/key-service',relative))).digest('hex')!==hash)throw Error('Pinned key service changed: '+relative);
}
const zip=new yazl.ZipFile();
const publicRoot=path.join(upstream,'packages/canvas/src/public');
const excluded=new Set(['mock-data.js','mock-sf.js','sentry-init.js','canvas-capture.js','playground-bridge.js','mcp-relay-client.js','support.js','ai-generate.js','ai-proposals.js','ai-clarifications.js','presence.js']);
for(const file of files(publicRoot))if(!excluded.has(path.basename(file))){
  const relative=path.relative(publicRoot,file).replaceAll('\\','/');
  zip.addFile(file,relative);
}
for(const file of files(path.join(root,'vendor/libraries')))zip.addFile(file,'vendor/'+path.relative(path.join(root,'vendor/libraries'),file).replaceAll('\\','/'));
for(const file of files(path.join(root,'web')))zip.addFile(file,'native/'+path.basename(file));
const template=fs.readFileSync(path.join(upstream,'packages/canvas/src/views/index.ejs'),'utf8');
const scripts=[...template.matchAll(/<script\b[^>]*\bsrc="([^"]+)"[^>]*>/g)].map(m=>m[1].split('?')[0]).filter(p=>p.startsWith('/')&&!excluded.has(path.basename(p)));
scripts.splice(scripts.indexOf('/js/app.js'),0,'/native/excluded-features.js','/native/viewport.js','/native/files.js','/native/layouts.js','/native/migration.js','/native/record-paste.js','/native/recovery.js','/native/platform.js');
const src=p=>`{!URLFOR($Resource.OrgLoomNativeAssets, '${p.replace(/^\//,'')}')}`;
const page=`<apex:page controller="OrgLoomNativeController" showHeader="false" sidebar="false" standardStylesheets="false" applyHtmlTag="false" applyBodyTag="false" docType="html-5.0">
<html lang="en"><head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>
<link rel="stylesheet" href="${src('/css/app.css')}"/><link rel="stylesheet" href="${src('/native/native.css')}"/>
<script>window.__ORGLOOM_NATIVE_IDENTITY__=JSON.parse('{!JSENCODE(identityJson)}');window.__ORGLOOM_NATIVE_REMOTE__='{!$RemoteAction.OrgLoomNativeController.invoke}';</script>
${['/native/native.js',...scripts,'/native/ready.js'].map(p=>`<script src="${src(p)}" defer="defer"></script>`).join('\n')}
</head><body class="canvas-page"><div id="native-notices"></div>
<main class="app-main"><div id="app-root"></div></main><div id="native-status">Opening canvas…</div></body></html></apex:page>`;
fs.writeFileSync(path.join(root,'force-app/main/default/pages/OrgLoomNative.page'),page);
const target=path.join(root,'force-app/main/default/staticresources/OrgLoomNativeAssets.resource');
zip.outputStream.pipe(fs.createWriteStream(target)).on('close',()=>{const size=fs.statSync(target).size;if(size>5*1024*1024)throw Error('Static resource exceeds Salesforce limit');console.log(`Built ${scripts.length} original scripts; static resource ${size} bytes.`);});zip.end();
