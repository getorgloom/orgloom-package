const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'../force-app/main/default'),ns='http://soap.sforce.com/2006/04/metadata';
const write=(p,s)=>{const f=path.join(root,p);fs.mkdirSync(path.dirname(f),{recursive:true});fs.writeFileSync(f,`<?xml version="1.0" encoding="UTF-8"?>\n${s}\n`);};
function object(name,label,fields){write(`objects/${name}/${name}.object-meta.xml`,`<CustomObject xmlns="${ns}"><deploymentStatus>Deployed</deploymentStatus><label>${label}</label><nameField><label>Number</label><type>AutoNumber</type><displayFormat>N-{000000}</displayFormat></nameField><pluralLabel>${label}s</pluralLabel><sharingModel>Private</sharingModel></CustomObject>`);for(const [field,xml] of Object.entries(fields))write(`objects/${name}/fields/${field}.field-meta.xml`,`<CustomField xmlns="${ns}"><fullName>${field}</fullName><label>${field.replace('__c','')}</label>${xml}</CustomField>`);}
object('OrgLoomNativeAttempt__c','Org Loom Upload Attempt',{
  Key__c:'<length>120</length><required>true</required><type>Text</type><unique>true</unique><externalId>true</externalId>',
  Digest__c:'<length>64</length><required>true</required><type>Text</type>',
  Results__c:'<length>131072</length><visibleLines>4</visibleLines><type>LongTextArea</type>'
});
object('OrgLoomNativeCanvas__c','Org Loom Canvas',{
  Title__c:'<length>120</length><required>true</required><type>Text</type>',
  FileId__c:'<length>18</length><type>Text</type>',
  VersionId__c:'<length>18</length><type>Text</type>',
  Revision__c:'<defaultValue>0</defaultValue><precision>12</precision><scale>0</scale><type>Number</type>',
  SessionHash__c:'<length>64</length><type>Text</type>',
  Holder__c:'<deleteConstraint>SetNull</deleteConstraint><referenceTo>User</referenceTo><relationshipName>NativeCanvasSessions</relationshipName><type>Lookup</type>',
  Expires__c:'<type>DateTime</type>'
});
object('OrgLoomNativeGrant__c','Org Loom Canvas Grant',{
  Key__c:'<length>80</length><required>true</required><type>Text</type><unique>true</unique><externalId>true</externalId>',
  Canvas__c:'<deleteConstraint>Cascade</deleteConstraint><referenceTo>OrgLoomNativeCanvas__c</referenceTo><relationshipName>CanvasGrants</relationshipName><type>Lookup</type>',
  Recipient__c:'<deleteConstraint>SetNull</deleteConstraint><referenceTo>User</referenceTo><relationshipName>NativeCanvasGrants</relationshipName><type>Lookup</type>',
  Role__c:'<length>20</length><required>true</required><type>Text</type>'
});
