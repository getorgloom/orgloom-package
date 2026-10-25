// Run only in a disposable subscriber validation org. Follow with package-smoke-recall.apex.
// Separate transactions match the actual app and avoid Salesforce's restrictions
// on querying some related-object providers after uncommitted DML.
String attempt=EncodingUtil.convertToHex(Crypto.generateAesKey(128));
Map<String,Object> payload=new Map<String,Object>{'attemptId'=>attempt,'expectedSfOrgId'=>UserInfo.getOrganizationId(),'records'=>new List<Object>{new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','values'=>new Map<String,Object>{'Name'=>'Package smoke upload'}}},'deletes'=>new List<Object>(),'associations'=>new List<Object>()};
Map<String,Object> response=(Map<String,Object>)JSON.deserializeUntyped(orgloom.OrgLoomNativeController.invoke('uploadPlan',JSON.serialize(payload)));
System.assertEquals(200,response.get('status'),JSON.serialize(response));
List<Object> groups=(List<Object>)((Map<String,Object>)response.get('data')).get('groups');
System.assertEquals(1,groups.size());
response=(Map<String,Object>)JSON.deserializeUntyped(orgloom.OrgLoomNativeController.invoke('uploadGroup',JSON.serialize(new Map<String,Object>{'rootAttemptId'=>attempt,'index'=>0,'payload'=>groups[0]})));
System.assertEquals(200,response.get('status'),JSON.serialize(response));
Map<String,Object> result=(Map<String,Object>)response.get('data');
Id accountId=(Id)(String)((Map<String,Object>)((List<Object>)result.get('results'))[0]).get('id');
System.assertEquals('Package smoke upload',[SELECT Name FROM Account WHERE Id=:accountId].Name);
System.debug('PASS: installed upload planning and execution; run package-smoke-recall.apex next.');
