@IsTest public class OrgLoomAccessFixture {
    public static void grant(User actor,Set<String> grants) {
        String ns=OrgLoomNativeAccess.packageNamespace();
        String base=grants.contains('Admin')?'OrgLoomNative_Admin':'OrgLoomNativePrototype';
        PermissionSet permission=[SELECT Id FROM PermissionSet WHERE Name=:base AND NamespacePrefix=:ns LIMIT 1];
        if([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId=:actor.Id AND PermissionSetId=:permission.Id]==0)
            insert new PermissionSetAssignment(AssigneeId=actor.Id,PermissionSetId=permission.Id);
        // Test-only fixture writes private configuration without granting the actor administration.
        // runAs isolates non-setup fixture DML from user/permission setup DML in tests.
        System.runAs(new User(Id=UserInfo.getUserId())) {
            List<OrgLoomFeatureAccess__c> rows=new List<OrgLoomFeatureAccess__c>();
            for(String capability:grants) {
                if(capability=='Access' || capability=='Admin')continue;
                System.assert(OrgLoomNativeAccess.features().containsKey(capability),'Unknown fixture capability: '+capability);
                rows.add(new OrgLoomFeatureAccess__c(UserId__c=String.valueOf(actor.Id),Capability__c=capability,GrantKey__c=actor.Id+':'+capability,Enabled__c=true));
            }
            if(!rows.isEmpty())upsert rows GrantKey__c;
        }
    }
}
