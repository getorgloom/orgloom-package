// Grants Org Loom Admin to the CLI-authenticated test user only.
// Does not grant business object/field access.
Set<String> names=new Set<String>{'OrgLoomNative_Admin'};
String ns=OrgLoomNativeAccess.packageNamespace();
Id currentUser=UserInfo.getUserId();
Set<Id> assigned=new Set<Id>();for(PermissionSetAssignment a:[SELECT PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId=:currentUser])assigned.add(a.PermissionSetId);
List<PermissionSetAssignment> grants=new List<PermissionSetAssignment>();
for(PermissionSet p:[SELECT Id FROM PermissionSet WHERE Name IN :names AND NamespacePrefix=:ns AND IsOwnedByProfile=false])if(!assigned.contains(p.Id))grants.add(new PermissionSetAssignment(PermissionSetId=p.Id,AssigneeId=currentUser));
insert grants;

