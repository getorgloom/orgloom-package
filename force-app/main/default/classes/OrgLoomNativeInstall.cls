// Assign only app entry and administration permissions to the installer.
// Other users and feature grants remain explicit administrator choices.
public without sharing class OrgLoomNativeInstall implements InstallHandler {
    public void onInstall(InstallContext context) {
        if(context.installerId()==null)return;
        assignInstaller(context.installerId());
        OrgLoomNativeRecoveryCleanup.scheduleOnce();
    }
    @TestVisible private static void assignInstaller(Id userId) {
        String ns=OrgLoomNativeAccess.packageNamespace();
        Set<Id> assigned=new Set<Id>();
        for(PermissionSetAssignment a:[SELECT PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId=:userId])assigned.add(a.PermissionSetId);
        List<PermissionSetAssignment> grants=new List<PermissionSetAssignment>();
        for(PermissionSet p:[SELECT Id FROM PermissionSet WHERE NamespacePrefix=:ns AND Name IN ('OrgLoomNative_Admin')]){
            if(!assigned.contains(p.Id))grants.add(new PermissionSetAssignment(AssigneeId=userId,PermissionSetId=p.Id));
        }
        if(!grants.isEmpty())insert grants;
    }
}
