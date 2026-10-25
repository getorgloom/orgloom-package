const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const zlib=require('node:zlib');
const root=path.resolve(__dirname,'..');
function zipEntries(bytes){
  let end=bytes.length-22;
  while(end>=0&&bytes.readUInt32LE(end)!==0x06054b50)end--;
  assert.ok(end>=0,'ZIP end record');
  const entries=new Map();
  let offset=bytes.readUInt32LE(end+16);
  for(let i=0;i<bytes.readUInt16LE(end+10);i++){
    assert.equal(bytes.readUInt32LE(offset),0x02014b50);
    const method=bytes.readUInt16LE(offset+10),length=bytes.readUInt32LE(offset+20);
    const nameLength=bytes.readUInt16LE(offset+28),extraLength=bytes.readUInt16LE(offset+30),commentLength=bytes.readUInt16LE(offset+32);
    const name=bytes.subarray(offset+46,offset+46+nameLength).toString();
    const local=bytes.readUInt32LE(offset+42);
    const start=local+30+bytes.readUInt16LE(local+26)+bytes.readUInt16LE(local+28);
    const compressed=bytes.subarray(start,start+length);
    assert.ok(method===0||method===8);
    entries.set(name,method===8?zlib.inflateRawSync(compressed):compressed);
    offset+=46+nameLength+extraLength+commentLength;
  }
  return entries;
}
test('built Salesforce runtime ships shared JavaScript byte-for-byte and registers the adapter before app startup',()=>{
  const entries=zipEntries(fs.readFileSync(path.join(root,'force-app/main/default/staticresources/OrgLoomNativeAssets.resource')));
  const manifest=require('../vendor/source-manifest.json');
  let checked=0;
  for(const file of Object.keys(manifest.files)){
    const relative=file.replace('packages/canvas/src/public/','');
    if(!relative.startsWith('js/')||!entries.has(relative))continue;
    assert.deepEqual(entries.get(relative),fs.readFileSync(path.join(root,'vendor/upstream',file)),relative+' must not be patched during build');
    checked++;
  }
  assert.ok(checked>50);
  assert.deepEqual(entries.get('native/platform.js'),fs.readFileSync(path.join(root,'web/platform.js')));
  const page=fs.readFileSync(path.join(root,'force-app/main/default/pages/OrgLoomNative.page'),'utf8');
  assert.ok(page.indexOf('native/platform.js')<page.indexOf("'js/app.js'"));
});
