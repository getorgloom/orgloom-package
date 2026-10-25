// Validate installer defaults before granting any optional features in a disposable org.
Set<String> names=new Set<String>();
for(PermissionSetAssignment a:[SELECT PermissionSet.Name FROM PermissionSetAssignment WHERE AssigneeId=:UserInfo.getUserId() AND PermissionSet.NamespacePrefix='orgloom'])names.add(a.PermissionSet.Name);
System.assert(names.containsAll(new Set<String>{'OrgLoomNative_Admin'}),'Installer needs app access and explicit administration.');
System.assert(!names.contains('OrgLoomNative_Upload'),'Installation must not auto-grant upload.');
System.assert(UserInfo.isCurrentUserLicensed('orgloom'),'Installed package license must be recognized.');
System.assertEquals(new Set<String>{'OrgLoomNative_Admin'},names,'Installer must not receive any retained legacy permission sets.');
Map<String,Object> response=(Map<String,Object>)JSON.deserializeUntyped(orgloom.OrgLoomNativeController.invoke('capabilities','{}'));
System.assertEquals(200,response.get('status'),JSON.serialize(response));
Map<String,Object> data=(Map<String,Object>)response.get('data');
System.assertEquals(true,data.get('admin'));
Map<String,Object> capabilities=(Map<String,Object>)data.get('capabilities');
for(Object enabled:capabilities.values())System.assertEquals(false,enabled,'Installer features require explicit per-user settings.');
System.debug('PASS: installer receives only native admin access, features disabled, active installed license.');
