// Native-only metadata. Business object/field permissions are never granted here.
const fs = require('node:fs');
const path = require('node:path');
const features = require('../config/features.json');
const root = path.resolve(__dirname, '../force-app/main/default');
const ns = 'http://soap.sforce.com/2006/04/metadata';
function write(name, content) {
  const target = path.join(root, name);
  fs.mkdirSync(path.dirname(target), {recursive: true});
  fs.writeFileSync(target, '<?xml version="1.0" encoding="UTF-8"?>\n' + content + '\n');
}
// Custom permissions identify the two entry roles; feature grants are private data.
for (const [permission,label] of [['Access','Use Org Loom'],['Admin','Administer Org Loom']]) {
  write(`customPermissions/OrgLoomNative_${permission}.customPermission-meta.xml`, `<CustomPermission xmlns="${ns}"><description>${label}. Does not grant Salesforce data access.</description><label>${label}</label></CustomPermission>`);
}
for (const admin of [false,true]) {
  const name=admin?'OrgLoomNative_Admin':'OrgLoomNativePrototype';
  const classes=['OrgLoomNativeController',...(admin?['OrgLoomNativeAdmin','OrgLoomNativeActivity']:[])];
  const pages=['OrgLoomNative','OrgLoomNativeLaunch',...(admin?['OrgLoomNativeAdmin','OrgLoomNativeActivity']:[])];
  const tabs=['OrgLoomNativeCanvas',...(admin?['OrgLoomNativeAdmin','OrgLoomNativeActivity']:[])];
  write(`permissionsets/${name}.permissionset-meta.xml`, `<PermissionSet xmlns="${ns}">
<applicationVisibilities><application>OrgLoom</application><visible>true</visible></applicationVisibilities>
${classes.map(c=>`<classAccesses><apexClass>${c}</apexClass><enabled>true</enabled></classAccesses>`).join('')}
${['Access',...(admin?['Admin']:[])].map(c=>`<customPermissions><enabled>true</enabled><name>OrgLoomNative_${c}</name></customPermissions>`).join('')}
<description>Org Loom ${admin?'administration and canvas':'canvas'} access. Feature access is managed in Org Loom administration. Does not grant business object or field permissions.</description>
<label>Org Loom ${admin?'Admin':'Canvas'}</label>
${pages.map(p=>`<pageAccesses><apexPage>${p}</apexPage><enabled>true</enabled></pageAccesses>`).join('')}
${tabs.map(t=>`<tabSettings><tab>${t}</tab><visibility>Visible</visibility></tabSettings>`).join('')}
</PermissionSet>`);
}
// Remove only the superseded generated components, not arbitrary metadata.
for(const f of features) {
  fs.rmSync(path.join(root,`permissionsets/OrgLoomNative_${f.permission}.permissionset-meta.xml`),{force:true});
  fs.rmSync(path.join(root,`customPermissions/OrgLoomNative_${f.permission}.customPermission-meta.xml`),{force:true});
}
fs.rmSync(path.join(root,'permissionsets/OrgLoomNative_Access.permissionset-meta.xml'),{force:true});
write('objects/OrgLoomFeatureAccess__c/OrgLoomFeatureAccess__c.object-meta.xml', `<CustomObject xmlns="${ns}"><deploymentStatus>Deployed</deploymentStatus><enableReports>false</enableReports><enableSearch>false</enableSearch><label>Org Loom Feature Access</label><nameField><label>Grant Number</label><type>AutoNumber</type><displayFormat>GRANT-{000000}</displayFormat></nameField><pluralLabel>Org Loom Feature Access</pluralLabel><sharingModel>Private</sharingModel></CustomObject>`);
for(const [name,label,length,unique] of [['GrantKey','Grant Key',100,true],['UserId','Salesforce User',18,false],['Capability','Capability',80,false]]) {
  write(`objects/OrgLoomFeatureAccess__c/fields/${name}__c.field-meta.xml`, `<CustomField xmlns="${ns}"><fullName>${name}__c</fullName><externalId>${unique}</externalId><label>${label}</label><length>${length}</length><required>true</required><type>Text</type><unique>${unique}</unique></CustomField>`);
}
write('objects/OrgLoomFeatureAccess__c/fields/Enabled__c.field-meta.xml', `<CustomField xmlns="${ns}"><fullName>Enabled__c</fullName><defaultValue>false</defaultValue><label>Enabled</label><type>Checkbox</type></CustomField>`);
write('objects/OrgLoomNativePolicy__c/OrgLoomNativePolicy__c.object-meta.xml', `<CustomObject xmlns="${ns}"><deploymentStatus>Deployed</deploymentStatus><label>Org Loom Feature Policy</label><nameField><label>Policy Number</label><type>AutoNumber</type><displayFormat>POL-{00000}</displayFormat></nameField><pluralLabel>Org Loom Feature Policies</pluralLabel><sharingModel>Read</sharingModel></CustomObject>`);
write('objects/OrgLoomNativePolicy__c/fields/Capability__c.field-meta.xml', `<CustomField xmlns="${ns}"><fullName>Capability__c</fullName><label>Capability</label><length>80</length><required>true</required><type>Text</type><unique>true</unique><externalId>true</externalId></CustomField>`);
write('objects/OrgLoomNativePolicy__c/fields/Enabled__c.field-meta.xml', `<CustomField xmlns="${ns}"><fullName>Enabled__c</fullName><defaultValue>true</defaultValue><label>Enabled for org</label><type>Checkbox</type></CustomField>`);
// Definitions are deployable configuration; user grants live in private OrgLoomFeatureAccess__c records.
write('objects/OrgLoomNativeFeature__mdt/OrgLoomNativeFeature__mdt.object-meta.xml', `<CustomObject xmlns="${ns}"><label>Org Loom Feature</label><pluralLabel>Org Loom Features</pluralLabel><visibility>Public</visibility></CustomObject>`);
for (const [name,label,length] of [['Capability','Capability',80]]) {
  write(`objects/OrgLoomNativeFeature__mdt/fields/${name}__c.field-meta.xml`, `<CustomField xmlns="${ns}"><fullName>${name}__c</fullName><fieldManageability>DeveloperControlled</fieldManageability><label>${label}</label><length>${length}</length><type>Text</type></CustomField>`);
}
for(const f of features) write(`customMetadata/OrgLoomNativeFeature.${f.permission}.md-meta.xml`, `<CustomMetadata xmlns="${ns}" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema"><label>${f.label}</label><protected>false</protected><values><field>Capability__c</field><value xsi:type="xsd:string">${f.id}</value></values></CustomMetadata>`);
console.log(`Generated ${features.length} feature definitions and two base permission sets.`);

fs.rmSync(path.join(root,'objects/OrgLoomNativeFeature__mdt/fields/Permission__c.field-meta.xml'),{force:true});
