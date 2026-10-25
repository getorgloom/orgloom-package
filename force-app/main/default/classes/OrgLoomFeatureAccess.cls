// Private configuration is intentionally accessed in system context. No CRUD/FLS on
// this object is granted to app users. Every public method authorizes its caller.
public without sharing class OrgLoomFeatureAccess {
    // Apex statics last for one request only. Key by user for runAs isolation;
    // invalidate on admin writes so revocation takes effect within the request too.
    private static Map<Id,Set<String>> requestGrants=new Map<Id,Set<String>>();
    public static Set<String> currentGrants() {
        OrgLoomNativeAccess.requireAccess();
        return readGrants(UserInfo.getUserId());
    }
    public static Set<String> grantsForUser(Id userId) {
        OrgLoomNativeAccess.requireAdmin();
        return readGrants(userId);
    }
    private static Set<String> readGrants(Id userId) {
        if(requestGrants.containsKey(userId))return new Set<String>(requestGrants.get(userId));
        String key=String.valueOf(userId);
        Set<String> result=new Set<String>();
        for(OrgLoomFeatureAccess__c row:[SELECT Capability__c FROM OrgLoomFeatureAccess__c WHERE UserId__c=:key AND Enabled__c=true])result.add(row.Capability__c);
        requestGrants.put(userId,result);
        return new Set<String>(result);
    }
    public static void setGrant(Id userId,String capability,Boolean enabled) {
        OrgLoomNativeAccess.requireAdmin();
        if(enabled==null || !OrgLoomNativeAccess.features().containsKey(capability))
            throw new OrgLoomNativeAccess.AccessDeniedException('Unknown feature or invalid setting.');
        if(userId==null || [SELECT COUNT() FROM User WHERE Id=:userId AND IsActive=true]!=1)
            throw new OrgLoomNativeAccess.AccessDeniedException('Choose an active Salesforce user.');
        String key=String.valueOf(userId);
        upsert new OrgLoomFeatureAccess__c(GrantKey__c=key+':'+capability,UserId__c=key,Capability__c=capability,Enabled__c=enabled) GrantKey__c;
        requestGrants.remove(userId);
    }
}
