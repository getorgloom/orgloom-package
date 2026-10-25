// Run only in a disposable subscriber validation org with the orgloom package installed.
// All generated canvas/files/keys are rolled back; no business records are written.
Savepoint start=Database.setSavepoint();
System.assert(UserInfo.isCurrentUserLicensed('orgloom'),'Installed package license must be recognized.');
Map<String,Object> caps=(Map<String,Object>)JSON.deserializeUntyped(orgloom.OrgLoomNativeController.invoke('capabilities','{}'));
System.assertEquals(200,caps.get('status'),JSON.serialize(caps));
Map<String,Object> snapshot=new Map<String,Object>{'_meta'=>new Map<String,Object>{'app'=>'Org Loom','version'=>1,'savedFrom'=>UserInfo.getOrganizationId()},'schema'=>new Map<String,Object>{'objects'=>new List<Object>()},'loadedRecords'=>new List<Object>(),'drafts'=>new List<Object>{new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','values'=>new Map<String,Object>{'Name'=>'Package smoke private draft'}}},'associations'=>new List<Object>()};
Map<String,Object> response=(Map<String,Object>)JSON.deserializeUntyped(orgloom.OrgLoomNativeController.invoke('canvas:create',JSON.serialize(new Map<String,Object>{'name'=>'Package smoke canvas','payload'=>snapshot})));
System.assertEquals(200,response.get('status'),JSON.serialize(response));
Map<String,Object> created=(Map<String,Object>)response.get('data');
Id version=(Id)(String)created.get('versionId');
String encrypted=[SELECT VersionData FROM ContentVersion WHERE Id=:version].VersionData.toString();
System.assert(!encrypted.contains('Package smoke private draft'),'Stored content must be encrypted.');
Boolean keysHidden=false;
try{Database.countQuery('SELECT COUNT() FROM orgloom__OrgLoomNativeKey__c');}catch(QueryException e){keysHidden=true;}
System.assert(keysHidden,'Subscriber Apex must not be able to query the protected key setting.');
response=(Map<String,Object>)JSON.deserializeUntyped(orgloom.OrgLoomNativeController.invoke('canvas:open',JSON.serialize(new Map<String,Object>{'id'=>created.get('id'),'sessionToken'=>created.get('sessionToken')})));
System.assertEquals(200,response.get('status'),JSON.serialize(response));
System.assert(JSON.serialize(response.get('data')).contains('Package smoke private draft'),'Package must decrypt its saved revision.');
response=(Map<String,Object>)JSON.deserializeUntyped(orgloom.OrgLoomNativeController.invoke('canvas:open',JSON.serialize(new Map<String,Object>{'id'=>created.get('id')})));
System.assertEquals(400,response.get('status'),'A second session must require takeover.');
System.assert(JSON.serialize(response).contains('OCCUPIED_SELF'));
Database.rollback(start);
System.debug('PASS: installed license, protected key boundary, encrypted save/open, same-user lease protection; fixtures rolled back.');
