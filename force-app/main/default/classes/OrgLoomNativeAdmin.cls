public with sharing class OrgLoomNativeAdmin {
    public Boolean getAllowed() { try {OrgLoomNativeAccess.requireAdmin();return true;}catch(Exception e){return false;} }
    private class AccessSources {
        Set<Id> permissionSets=new Set<Id>(),profiles=new Set<Id>();
    }
    private static AccessSources accessSources() {
        AccessSources sources=new AccessSources();String ns=OrgLoomNativeAccess.packageNamespace();
        // Use the same custom permission as requireAccess, including custom sets,
        // profile grants and calculated permission-set groups. Never match labels.
        for(SetupEntityAccess grant:[SELECT ParentId,Parent.ProfileId FROM SetupEntityAccess
            WHERE SetupEntityId IN (SELECT Id FROM CustomPermission WHERE DeveloperName='OrgLoomNative_Access' AND NamespacePrefix=:ns)
            AND Parent.Type!='Muting']){
            sources.permissionSets.add(grant.ParentId);
            if(grant.Parent.ProfileId!=null)sources.profiles.add(grant.Parent.ProfileId);
        }
        return sources;
    }
    private static List<User> searchUsers(String term) {
        AccessSources sources=accessSources();
        // Filter before LIMIT so unassigned users cannot crowd eligible users out.
        List<User> assigned=[SELECT Id,Name,Username FROM User WHERE IsActive=true AND (Name LIKE :term OR Username LIKE :term)
            AND Id IN (SELECT AssigneeId FROM PermissionSetAssignment WHERE PermissionSetId IN :sources.permissionSets AND IsActive=true)
            ORDER BY Name,Id LIMIT 50];
        if(sources.profiles.isEmpty())return assigned;
        Set<Id> ids=mergeUserIds(assigned,[SELECT Id FROM User WHERE IsActive=true AND ProfileId IN :sources.profiles AND (Name LIKE :term OR Username LIKE :term) ORDER BY Name,Id LIMIT 50]);
        return [SELECT Id,Name,Username FROM User WHERE Id IN :ids ORDER BY Name,Id LIMIT 50];
    }
    @TestVisible private static Set<Id> mergeUserIds(List<User> assigned,List<User> profileUsers) {
        // Map.keySet() is read-only. Copy it before merging profile-based access.
        Set<Id> ids=new Set<Id>(new Map<Id,User>(assigned).keySet());
        for(User u:profileUsers)ids.add(u.Id);
        return ids;
    }
    private static User targetUser(String value) {
        Id id=(Id)value;
        List<User> found=[SELECT Id,Name,IsActive,ProfileId FROM User WHERE Id=:id AND IsActive=true LIMIT 1];
        AccessSources sources=accessSources();
        if(found.isEmpty()||(!sources.profiles.contains(found[0].ProfileId)&&[SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId=:id AND PermissionSetId IN :sources.permissionSets AND IsActive=true]==0))
            throw new OrgLoomNativeAccess.AccessDeniedException('Choose an active user with Org Loom access.');
        return found[0];
    }
    @RemoteAction public static String invoke(String operation,String payload) {
        try {
            OrgLoomNativeAccess.requireAdmin();
            if(payload==null || payload.length()>10000)throw new OrgLoomNativeAccess.AccessDeniedException('Invalid request.');
            Map<String,Object> body=(Map<String,Object>)JSON.deserializeUntyped(payload);
            Object data;
            if(operation=='users') {
                String term=String.valueOf(body.get('search'));if(term=='null')term='';
                term='%'+term+'%';
                data=searchUsers(term);
            } else if(operation=='features') {
                String userId=(String)body.get('userId');
                Set<String> assigned=new Set<String>();
                if(!String.isBlank(userId))assigned=OrgLoomFeatureAccess.grantsForUser(targetUser(userId).Id);
                Map<String,Boolean> policy=OrgLoomNativeAccess.policies();List<Object> rows=new List<Object>();
                for(OrgLoomNativeFeature__mdt f:OrgLoomNativeAccess.features().values())rows.add(new Map<String,Object>{
                    'id'=>f.Capability__c,'label'=>f.MasterLabel,'assigned'=>assigned.contains(f.Capability__c),
                    'enabled'=>policy.get(f.Capability__c)!=false,'implemented'=>OrgLoomNativeAccess.IMPLEMENTED.contains(f.Capability__c)});
                data=rows;
            } else if(operation=='grant' || operation=='policy') {
                OrgLoomNativeFeature__mdt feature=OrgLoomNativeAccess.features().get((String)body.get('capability'));
                if(feature==null || !(body.get('enabled') instanceof Boolean))throw new OrgLoomNativeAccess.AccessDeniedException('Unknown feature or invalid setting.');
                Boolean enabled=(Boolean)body.get('enabled');
                if(operation=='grant') {
                    User target=targetUser((String)body.get('userId'));
                    OrgLoomFeatureAccess.setGrant(target.Id,feature.Capability__c,enabled);
                } else {
                    // Org-wide policy takes precedence over individual grants.
                    upsert new OrgLoomNativePolicy__c(Capability__c=feature.Capability__c,Enabled__c=enabled) Capability__c;
                }
                data=new Map<String,Object>{'ok'=>true};
            } else throw new OrgLoomNativeAccess.AccessDeniedException('Unsupported admin operation.');
            return JSON.serialize(new Map<String,Object>{'status'=>200,'data'=>data});
        } catch(Exception e) {return JSON.serialize(new Map<String,Object>{'status'=>400,'data'=>new Map<String,Object>{'message'=>e.getMessage()}});}
    }
}
