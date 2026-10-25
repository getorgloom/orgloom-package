@IsTest private class OrgLoomNativeAccessTest {
    private static User user(String suffix) {
        User u=new User(ProfileId=[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' LIMIT 1].Id,
            Username='native-access-'+suffix+'-'+System.now().getTime()+'@example.invalid',Email='native@example.invalid',Alias='natest',LastName='Native '+suffix,
            TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;return u;
    }
    private static void grant(User u,Set<String> names) {
        OrgLoomAccessFixture.grant(u,names);
    }
    private static Map<String,Object> admin(String op,Map<String,Object> body) {return (Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeAdmin.invoke(op,JSON.serialize(body)));}
    @IsTest static void missingLicenseBlocksEvenAdministrators() {
        User u=user('unlicensed');grant(u,new Set<String>{'Admin'});
        System.runAs(u) {
            OrgLoomNativeAccess.licenseForTest=false;
            try{OrgLoomNativeAccess.requireAccess();System.assert(false);}catch(OrgLoomNativeAccess.AccessDeniedException e){System.assert(e.getMessage().contains('package license'));}
            System.assertEquals(false,new OrgLoomNativeAdmin().getAllowed());
            System.assertEquals(400,admin('features',new Map<String,Object>{'userId'=>u.Id}).get('status'));
        }
    }
    @IsTest static void directCallsCannotBypassFeatureGrants() {
        User u=user('restricted');grant(u,new Set<String>{'Access'});
        System.runAs(u) {
            System.assertEquals(false,OrgLoomNativeAccess.capabilities().get('soql-import'));
            System.assertEquals(false,OrgLoomNativeAccess.isAdmin());
            System.assertEquals(false,OrgLoomFeatureAccess__c.SObjectType.getDescribe().isCreateable());
            try{OrgLoomFeatureAccess.setGrant(u.Id,'soql-import',true);System.assert(false);}catch(OrgLoomNativeAccess.AccessDeniedException e){}
            try{OrgLoomFeatureAccess.grantsForUser(u.Id);System.assert(false);}catch(OrgLoomNativeAccess.AccessDeniedException e){}
            System.assertEquals(400,((Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke('query','{"soql":"SELECT Id FROM Account LIMIT 1"}'))).get('status'));
            System.assertEquals(400,((Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke('upload','{}'))).get('status'));
            System.assertEquals(400,admin('grant',new Map<String,Object>{'userId'=>u.Id,'capability'=>'upload-records','enabled'=>true}).get('status'));
        }
    }
    @IsTest static void orgSwitchOverridesUserGrantAndMissingGrantsStayBlocked() {
        User u=user('granted');grant(u,new Set<String>{'Access','soql-import','share-canvas'});
        System.runAs(u) {
            System.assertEquals(true,OrgLoomNativeAccess.capabilities().get('soql-import'));
            System.assertEquals(true,OrgLoomNativeAccess.capabilities().get('share-canvas'));
            System.assertEquals(false,OrgLoomNativeAccess.capabilities().get('auto-fill-records'));
            insert new OrgLoomNativePolicy__c(Capability__c='soql-import',Enabled__c=false);
            System.assertEquals(false,OrgLoomNativeAccess.capabilities().get('soql-import'));
            try{OrgLoomNativeAccess.requireCapability('soql-import');System.assert(false);}catch(OrgLoomNativeAccess.AccessDeniedException e){System.assert(e.getMessage().contains('disabled'));}
        }
    }
    @IsTest static void localToolsRequireSeparateGrantsAndRespectPolicy() {
        User u=user('tools');grant(u,new Set<String>{'Access','run-script','auto-fill-records'});
        System.runAs(u) {
            for(String capability:new List<String>{'run-script','auto-fill-records'}) {
                System.assertEquals(true,OrgLoomNativeAccess.capabilities().get(capability));
                System.assertEquals(200,((Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke('capabilityCheck',JSON.serialize(new Map<String,Object>{'capability'=>capability})))).get('status'));
            }
            insert new OrgLoomNativePolicy__c(Capability__c='run-script',Enabled__c=false);
            System.assertEquals(false,OrgLoomNativeAccess.capabilities().get('run-script'));
            System.assertEquals(400,((Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke('capabilityCheck','{"capability":"run-script"}'))).get('status'));
            System.assertEquals(true,OrgLoomNativeAccess.capabilities().get('auto-fill-records'));
        }
    }
    @IsTest static void adminCanOnlyGrantEnumeratedFeatures() {
        User administrator=user('admin'),recipient=user('recipient');
        grant(recipient,new Set<String>{'Access'});
        grant(administrator,new Set<String>{'Admin'});
        System.runAs(administrator) {
            System.assertEquals(true,new OrgLoomNativeAdmin().getAllowed());
            System.assertEquals(false,OrgLoomNativeController.available(OrgLoomFeatureAccess__c.SObjectType.getDescribe()),'Grant records cannot be edited through the canvas');
            System.assertEquals(200,admin('users',new Map<String,Object>{'search'=>'Native'}).get('status'));
            System.assertEquals(200,admin('features',new Map<String,Object>{'userId'=>recipient.Id}).get('status'));
            System.assertEquals(400,admin('grant',new Map<String,Object>{'userId'=>recipient.Id,'capability'=>'Admin','enabled'=>true}).get('status'));
            System.assertEquals(200,admin('grant',new Map<String,Object>{'userId'=>recipient.Id,'capability'=>'soql-import','enabled'=>true}).get('status'));
            String recipientId=String.valueOf(recipient.Id);
            System.assertEquals(1,[SELECT COUNT() FROM OrgLoomFeatureAccess__c WHERE UserId__c=:recipientId AND Capability__c='soql-import' AND Enabled__c=true]);
            System.runAs(recipient){System.assertEquals(true,OrgLoomNativeAccess.capabilities().get('soql-import'));}
            System.assertEquals(200,admin('grant',new Map<String,Object>{'userId'=>recipient.Id,'capability'=>'soql-import','enabled'=>false}).get('status'));
            System.runAs(recipient){System.assertEquals(false,OrgLoomNativeAccess.capabilities().get('soql-import'));}
            System.assertEquals(false,OrgLoomNativeAccess.capabilities().get('soql-import'),'Admin does not implicitly grant features');
            System.assertEquals(0,[SELECT COUNT() FROM OrgLoomFeatureAccess__c WHERE UserId__c=:recipientId AND Capability__c='soql-import' AND Enabled__c=true]);
        }
    }
    @IsTest static void noAppAccessAndOrgPolicyAdmin() {
        User u=user('none'),administrator=user('policyadmin');grant(administrator,new Set<String>{'Admin'});
        System.runAs(u){System.assertEquals(false,new OrgLoomNativeAdmin().getAllowed());try{OrgLoomNativeAccess.requireAccess();System.assert(false);}catch(OrgLoomNativeAccess.AccessDeniedException e){System.assert(e.getMessage().contains('grant'));}}
        System.runAs(administrator){System.assertEquals(200,admin('policy',new Map<String,Object>{'capability'=>'upload-records','enabled'=>false}).get('status'));System.assertEquals(false,OrgLoomNativeAccess.policies().get('upload-records'));}
    }
}
