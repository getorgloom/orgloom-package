// Build the next version of the existing managed package from native source.
// The unpackaged UAT project keeps its separate, empty namespace.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const root=path.resolve(__dirname,'..');
const target=path.join(root,'output/managed-package');
const project=JSON.parse(fs.readFileSync(path.join(root,'config/managed-project.json'),'utf8'));
const destination=path.join(target,'force-app');
fs.mkdirSync(destination,{recursive:true});
const inventory={};
function copyTree(source,base){
  for(const entry of fs.readdirSync(source,{withFileTypes:true})){
    const from=path.join(source,entry.name);
    if(entry.isDirectory()){copyTree(from,base);continue;}
    const relative=path.relative(base,from).replaceAll('\\','/');
    const to=path.join(destination,relative);
    if(inventory[relative])throw Error('Duplicate managed component: '+relative);
    fs.mkdirSync(path.dirname(to),{recursive:true});fs.copyFileSync(from,to);
    inventory[relative]=crypto.createHash('sha256').update(fs.readFileSync(from)).digest('hex');
  }
}
// Released metadata cannot be deleted until Salesforce enables 2GP component removal.
copyTree(path.join(root,'compatibility/force-app'),path.join(root,'compatibility/force-app'));
copyTree(path.join(root,'force-app'),path.join(root,'force-app'));
// Fail closed on stale generated components instead of silently packaging them.
function check(dir){for(const e of fs.readdirSync(dir,{withFileTypes:true})){
  const p=path.join(dir,e.name);if(e.isDirectory())check(p);else if(!inventory[path.relative(destination,p).replaceAll('\\','/')])throw Error('Stale generated package file: '+p);
}}
check(destination);
fs.writeFileSync(path.join(target,'sfdx-project.json'),JSON.stringify(project,null,2)+'\n');
fs.writeFileSync(path.join(target,'source-manifest.json'),JSON.stringify({ancestor:project.packageDirectories[0].ancestorId,files:inventory},null,2)+'\n');
console.log(`Prepared ${Object.keys(inventory).length} components/files in ${target}`);
