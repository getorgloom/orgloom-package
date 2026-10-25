public with sharing class OrgLoomNativeAdmin {
    public Boolean getAllowed() { try {OrgLoomNativeAccess.requireAdmin();return true;}catch(Exception e){return false;} }
    private static User targetUser(String value) {
        Id id=(Id)value;
        List<User> found=[SELECT Id,Name,IsActive FROM User WHERE Id=:id AND IsActive=true LIMIT 1];
        if(found.isEmpty())throw new OrgLoomNativeAccess.AccessDeniedException('Choose an active Salesforce user.');
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
                data=[SELECT Id,Name,Username FROM User WHERE IsActive=true AND (Name LIKE :term OR Username LIKE :term) ORDER BY Name LIMIT 50];
            } else if(operation=='features') {
                User target=targetUser((String)body.get('userId'));
                Set<String> assigned=OrgLoomFeatureAccess.grantsForUser(target.Id);
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
