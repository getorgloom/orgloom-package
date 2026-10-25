const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'../force-app/main/default');
async function xml(file){const {JSDOM}=await import('jsdom');return new JSDOM(fs.readFileSync(path.join(root,file),'utf8'),{contentType:'text/xml'}).window.document;}
const values=(doc,selector)=>Array.from(doc.querySelectorAll(selector),n=>n.textContent);
test('two entry roles expose only the intended tabs and never grant feature-data CRUD',async()=>{
  assert.deepEqual(fs.readdirSync(path.join(root,'permissionsets')).sort(),['OrgLoomNativePrototype.permissionset-meta.xml','OrgLoomNative_Admin.permissionset-meta.xml']);
  const canvas=await xml('permissionsets/OrgLoomNativePrototype.permissionset-meta.xml');
  const admin=await xml('permissionsets/OrgLoomNative_Admin.permissionset-meta.xml');
  assert.deepEqual(values(canvas,'label'),['Org Loom Canvas']);
  assert.deepEqual(values(admin,'label'),['Org Loom Admin']);
  assert.deepEqual(values(canvas,'tabSettings tab'),['OrgLoomNativeCanvas']);
  assert.deepEqual(values(canvas,'customPermissions name'),['OrgLoomNative_Access']);
  assert.deepEqual(values(admin,'customPermissions name'),['OrgLoomNative_Access','OrgLoomNative_Admin']);
  assert.deepEqual(values(admin,'tabSettings tab'),['OrgLoomNativeCanvas','OrgLoomNativeAdmin','OrgLoomNativeActivity']);
  for(const selector of ['classAccesses apexClass','pageAccesses apexPage','applicationVisibilities application']) {
    for(const item of values(canvas,selector))assert.ok(values(admin,selector).includes(item));
  }
  for(const doc of [canvas,admin])assert.equal(doc.querySelectorAll('objectPermissions,fieldPermissions,userPermissions').length,0);
  assert.equal(canvas.querySelector('classAccesses apexClass').textContent,'OrgLoomNativeController');
  assert.equal(fs.readdirSync(path.join(root,'customPermissions')).length,2);
});
test('feature grants are private and uniquely keyed per user and feature',async()=>{
  const object=await xml('objects/OrgLoomFeatureAccess__c/OrgLoomFeatureAccess__c.object-meta.xml');
  assert.deepEqual(values(object,'sharingModel'),['Private']);
  const key=await xml('objects/OrgLoomFeatureAccess__c/fields/GrantKey__c.field-meta.xml');
  assert.deepEqual(values(key,'unique'),['true']);
  assert.deepEqual(values(key,'externalId'),['true']);
  const enabled=await xml('objects/OrgLoomFeatureAccess__c/fields/Enabled__c.field-meta.xml');
  assert.deepEqual(values(enabled,'defaultValue'),['false']);
});
