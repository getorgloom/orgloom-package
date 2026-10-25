// One-time UNPACKAGED UAT migration, before removing old feature custom permissions.
// Run as the UAT administrator. Only migrates the current user's effective grants;
// fail closed if any other user has legacy direct assignments. Never overwrites a saved toggle.
System.assertEquals(null,OrgLoomNativeAccess.packageNamespace(),'Unpackaged UAT only.');
OrgLoomNativeAccess.requireAdmin();
Id actor=UserInfo.getUserId();
System.assertEquals(0,[SELECT COUNT() FROM PermissionSetAssignment WHERE PermissionSet.Name LIKE 'OrgLoomNative%' AND AssigneeId!=:actor],'Other users require an explicit migration plan.');
Map<String,String> oldPermissions=new Map<String,String>{
    'browse-records'=>'OrgLoomNative_Browse',
    'soql-import'=>'OrgLoomNative_Soql',
    'upload-records'=>'OrgLoomNative_Upload',
    'bulk-edit-records'=>'OrgLoomNative_BulkEdit',
    'save-canvas'=>'OrgLoomNative_Save',
    'open-saved-canvas'=>'OrgLoomNative_Open',
    'share-canvas'=>'OrgLoomNative_Share',
    'receive-canvas'=>'OrgLoomNative_Receive',
    'create-slot-canvas'=>'OrgLoomNative_Requests',
    'recall-upload'=>'OrgLoomNative_Recall',
    'export-canvas'=>'OrgLoomNative_ExportCanvas',
    'export-records'=>'OrgLoomNative_ExportRecords',
    'run-script'=>'OrgLoomNative_Script',
    'auto-fill-records'=>'OrgLoomNative_Autofill',
    'view-activity-history'=>'OrgLoomNative_History'
};
String userKey=String.valueOf(actor);
Set<String> configured=new Set<String>();
for(OrgLoomFeatureAccess__c row:[SELECT Capability__c FROM OrgLoomFeatureAccess__c WHERE UserId__c=:userKey])configured.add(row.Capability__c);
Integer migrated=0;
for(String capability:oldPermissions.keySet()) {
    if(!configured.contains(capability) && FeatureManagement.checkPermission(oldPermissions.get(capability))) {
        OrgLoomFeatureAccess.setGrant(actor,capability,true);migrated++;
    }
}
System.debug('Feature grants migrated: '+migrated);
