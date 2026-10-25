// Reuses the existing package KEK implementation with isolated native names.
// Kept separate from the canvas snapshot; no original package files are edited.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'..');
const source=process.argv[2];if(!source)throw Error('Pass the existing managed package default directory.');
const target=path.join(root,'force-app/main/default');
const archive=path.join(root,'vendor/key-service');fs.mkdirSync(archive,{recursive:true});
const manifest={};
function copy(relative,out,transform=s=>s){const input=fs.readFileSync(path.join(source,relative),'utf8');fs.mkdirSync(path.dirname(path.join(archive,relative)),{recursive:true});fs.writeFileSync(path.join(archive,relative),input);manifest[relative]=crypto.createHash('sha256').update(input).digest('hex');const dest=path.join(target,out);fs.mkdirSync(path.dirname(dest),{recursive:true});fs.writeFileSync(dest,transform(input));}
const rename=s=>s.replaceAll('OrgloomKekService','OrgLoomNativeKek').replaceAll('Org_Kek_Setting__c','OrgLoomNativeKey__c');
for(const f of ['OrgloomKekService.cls','OrgloomKekService.cls-meta.xml','OrgloomKekServiceTest.cls','OrgloomKekServiceTest.cls-meta.xml'])copy('classes/'+f,'classes/'+f.replace('OrgloomKekService','OrgLoomNativeKek'),rename);
const dir=path.join(source,'objects/Org_Kek_Setting__c');
function walk(d){for(const item of fs.readdirSync(d,{withFileTypes:true})){const f=path.join(d,item.name);if(item.isDirectory())walk(f);else{const r=path.relative(source,f).replaceAll('\\','/');copy(r,r.replaceAll('Org_Kek_Setting__c','OrgLoomNativeKey__c'),rename);}}}walk(dir);
fs.writeFileSync(path.join(archive,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
