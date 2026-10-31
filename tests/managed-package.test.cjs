const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path'),{execFileSync}=require('node:child_process');
const root=path.resolve(__dirname,'..');
test('managed build isolates required released metadata from current native source',()=>{
  execFileSync(process.execPath,[path.join(root,'scripts/prepare-package.cjs')],{cwd:root});
  const output=path.join(root,'output/managed-package');
  const project=JSON.parse(fs.readFileSync(path.join(output,'sfdx-project.json'),'utf8'));
  assert.equal(project.namespace,'orgloom');
  assert.equal(project.packageAliases.Orgloom,'0Hoao0000003RYLCA2');
  const release=JSON.parse(fs.readFileSync(path.join(root,'config/released-package.json'),'utf8'));
  assert.equal(release.released,true);
  assert.equal(project.packageDirectories[0].ancestorId,release.subscriberPackageVersionId);
  assert.equal(project.packageDirectories[0].postInstallScript,'OrgLoomNativeInstall');
  const base=path.join(output,'force-app/main/default');
  const native=path.join(root,'force-app/main/default');
  assert.deepEqual(fs.readdirSync(path.join(native,'permissionsets')).sort(),['OrgLoomNativePrototype.permissionset-meta.xml','OrgLoomNative_Admin.permissionset-meta.xml']);
  assert.equal(fs.existsSync(path.join(base,'permissionsets/Orgloom_Audit_Smoke_Test.permissionset-meta.xml')),false,'Unreleased smoke-test permission set stays excluded');
  const retained=['Audit_Event__c','Canvas_Contribution__c','Orgloom_Canvas__c','Org_Kek_Setting__c'];
  const compatibility=path.join(root,'compatibility/force-app/main/default');
  assert.deepEqual(fs.readdirSync(compatibility).sort(),['classes','customPermissions','externalClientApps','extlClntAppOauthSettings','objects','permissionsets','tabs','triggers']);
  assert.ok(fs.existsSync(path.join(base,'tabs/OrgLoomNativePrototype.tab-meta.xml')),'Released fallback tab retained for managed compatibility');
  assert.equal(fs.existsSync(path.join(native,'tabs/OrgLoomNativePrototype.tab-meta.xml')),false);
  assert.deepEqual(fs.readdirSync(path.join(compatibility,'objects')).sort(),[...retained,'OrgLoomNativeFeature__mdt'].sort());
  assert.ok(fs.existsSync(path.join(base,'objects/OrgLoomNativeFeature__mdt/fields/Permission__c.field-meta.xml')));
  for(const name of retained)assert.ok(fs.existsSync(path.join(base,'objects',name)),name);
  for(const name of ['OrgloomKekRest','OrgloomKekService','OrgloomPostInstall','AuditEventGuardTest']) {
    assert.ok(fs.existsSync(path.join(base,'classes',name+'.cls')),name);
    assert.equal(fs.existsSync(path.join(native,'classes',name+'.cls')),false,name+' is compatibility only');
  }
  assert.ok(fs.existsSync(path.join(base,'triggers/AuditEventGuard.trigger')));
  for(const directory of ['externalClientApps','extlClntAppOauthSettings']) {
    assert.equal(fs.existsSync(path.join(root,'force-app/main/default',directory)),false,'Native runtime has no ECA input');
    assert.equal(fs.readdirSync(path.join(base,directory)).length,1,'Only the required released ECA metadata remains');
  }
  assert.ok(fs.existsSync(path.join(base,'objects/OrgLoomNativeKey__c')));
  assert.ok(fs.existsSync(path.join(base,'classes/OrgLoomNativeKek.cls')));
  assert.equal(fs.existsSync(path.join(root,'vendor/legacy-package')),false);
});
