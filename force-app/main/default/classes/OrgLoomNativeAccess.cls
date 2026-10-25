public with sharing class OrgLoomNativeAccess {
    public class AccessDeniedException extends Exception {}
    public static String packageNamespace() {
        String name=OrgLoomNativeAccess.class.getName();
        return name.contains('.')?name.substringBefore('.'):null;
    }
    public static String qualifiedName(String name) {
        String ns=packageNamespace();return ns==null?name:ns+'__'+name;
    }
    // Implementation availability is code-owned; neither metadata nor grants enable unfinished features.
    public static final Set<String> IMPLEMENTED = new Set<String>{'browse-records','soql-import','upload-records','bulk-edit-records','save-canvas','open-saved-canvas','export-canvas','export-records','share-canvas','receive-canvas','create-slot-canvas','view-activity-history','recall-upload','run-script','auto-fill-records'};
    public static Map<String,OrgLoomNativeFeature__mdt> features() {
        Map<String,OrgLoomNativeFeature__mdt> result=new Map<String,OrgLoomNativeFeature__mdt>();
        for(OrgLoomNativeFeature__mdt f:OrgLoomNativeFeature__mdt.getAll().values()) result.put(f.Capability__c,f);
        return result;
    }
    public static Boolean isAdmin() { return FeatureManagement.checkPermission('OrgLoomNative_Admin'); }
    @TestVisible private static Boolean licenseForTest;
    private static Boolean licensed() {
        if(Test.isRunningTest() && licenseForTest!=null)return licenseForTest;
        String ns=packageNamespace();
        if(ns==null)return true;
        try {return UserInfo.isCurrentUserLicensed(ns);}
        catch(System.TypeException e) {
            // 2GP runs tests in a namespaced build org before the package exists.
            // Installed-org tests still use the real service; runtime never bypasses it.
            if(Test.isRunningTest() && e.getMessage()=='Managed Package corresponding to namespace prefix not found')return true;
            throw e;
        }
    }
    public static void requireAccess() {
        if(!FeatureManagement.checkPermission('OrgLoomNative_Access')) throw new AccessDeniedException('Your Salesforce administrator must grant Org Loom access.');
        if(!licensed())throw new AccessDeniedException('Your administrator must assign an active Org Loom package license.');
    }
    public static void requireAdmin() {
        requireAccess();
        if(!isAdmin())throw new AccessDeniedException('Org Loom administrator access is required.');
    }
    public static Map<String,Boolean> policies() {
        Map<String,Boolean> result=new Map<String,Boolean>();
        for(OrgLoomNativePolicy__c p:[SELECT Capability__c,Enabled__c FROM OrgLoomNativePolicy__c])result.put(p.Capability__c,p.Enabled__c);
        return result;
    }
    public static Map<String,Boolean> capabilities() {
        requireAccess();
        Map<String,Boolean> result=new Map<String,Boolean>(),policy=policies();
        Set<String> grants=OrgLoomFeatureAccess.currentGrants();
        for(OrgLoomNativeFeature__mdt f:features().values())result.put(f.Capability__c,
            IMPLEMENTED.contains(f.Capability__c) && policy.get(f.Capability__c)!=false && grants.contains(f.Capability__c));
        return result;
    }
    public static void requireCapability(String capability) {
        requireAccess();
        OrgLoomNativeFeature__mdt f=features().get(capability);
        if(f==null || !IMPLEMENTED.contains(capability))throw new AccessDeniedException('This feature is not implemented in Org Loom yet.');
        if(policies().get(capability)==false)throw new AccessDeniedException('Your administrator has disabled this feature for the org.');
        if(!OrgLoomFeatureAccess.currentGrants().contains(capability))throw new AccessDeniedException('Your administrator must grant access to '+f.MasterLabel+'.');
    }
}
