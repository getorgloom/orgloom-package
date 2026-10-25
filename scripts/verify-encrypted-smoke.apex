// Inspect only the uniquely named canvas created by the browser smoke test.
Map<String,Object> listing=(Map<String,Object>)OrgLoomNativeCanvases.handle('list',new Map<String,Object>());
Map<String,Object> canvas;
for(Object raw:(List<Object>)listing.get('items')){Map<String,Object> item=(Map<String,Object>)raw;if(item.get('title')=='Native encryption smoke test 2026-10-22')canvas=item;}
System.assertNotEquals(null,canvas);
Id versionId=(Id)(String)canvas.get('versionId');
ContentVersion v=[SELECT VersionData FROM ContentVersion WHERE Id=:versionId];
System.assert(!v.VersionData.toString().contains('Native encrypted save smoke test'));
Map<String,Object> envelope=(Map<String,Object>)JSON.deserializeUntyped(v.VersionData.toString());
System.assertEquals('orgloom-native-encrypted',envelope.get('format'));
System.assert(envelope.containsKey('wrappedKey')&&envelope.containsKey('mac')&&envelope.containsKey('ciphertext'));
System.debug('NATIVE_ENCRYPTED_SMOKE_VERIFIED');
