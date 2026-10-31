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
    @IsTest static void recallDenialsIdentifyTheFeatureAndScope() {
        User u=user('recallmessages');grant(u,new Set<String>{'Access'});
        System.runAs(u) {
            insert new List<OrgLoomNativePolicy__c>{
                new OrgLoomNativePolicy__c(Capability__c='recall-upload',Enabled__c=true),
                new OrgLoomNativePolicy__c(Capability__c='view-activity-history',Enabled__c=false)
            };
            Map<String,Object> history=(Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke('history:list','{}'));
            System.assertEquals(400,history.get('status'));
            System.assertEquals('Your administrator has disabled View activity history for the org.',((Map<String,Object>)history.get('data')).get('message'));
            Map<String,Object> recall=(Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke('history:preflight','{}'));
            System.assertEquals(400,recall.get('status'));
            System.assertEquals('Your administrator must grant access to Recall uploads.',((Map<String,Object>)recall.get('data')).get('message'));
        }
    }
    private static void assertExportChecks(Integer expected) {
        for(String capability:new List<String>{'export-canvas','export-records'})
            System.assertEquals(expected,((Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke('capabilityCheck',JSON.serialize(new Map<String,Object>{'capability'=>capability})))).get('status'),capability);
    }
    @IsTest static void oneExportGrantControlsBothFormatsAndLegacyClients() {
        User administrator=user('exportadmin'),recipient=user('exportuser');
        grant(administrator,new Set<String>{'Admin'});grant(recipient,new Set<String>{'Access'});
        System.runAs(administrator) {
            List<Object> rows=(List<Object>)admin('features',new Map<String,Object>{'userId'=>recipient.Id}).get('data');
            Integer exports=0;
            for(Object raw:rows){Map<String,Object> row=(Map<String,Object>)raw;
                System.assertNotEquals('export-records',row.get('id'),'The retired permission must not appear in Manage.');
                if(row.get('id')=='export-canvas'){exports++;System.assertEquals('Export Canvases (CSV/JSON)',row.get('label'));}
            }
            System.assertEquals(1,exports);
            System.assertEquals(400,admin('grant',new Map<String,Object>{'userId'=>recipient.Id,'capability'=>'export-records','enabled'=>true}).get('status'));
            // Old package grants may remain in stored configuration, but cannot bypass the combined switch.
            insert new OrgLoomFeatureAccess__c(UserId__c=String.valueOf(recipient.Id),Capability__c='export-records',GrantKey__c=recipient.Id+':export-records',Enabled__c=true);
            System.runAs(recipient){assertExportChecks(400);}
            OrgLoomFeatureAccess.setGrant(recipient.Id,'export-canvas',true);
            System.runAs(recipient){assertExportChecks(200);System.assertEquals(true,OrgLoomNativeAccess.capabilities().get('export-canvas'));}
            OrgLoomFeatureAccess.setGrant(recipient.Id,'export-canvas',false);
            System.runAs(recipient){assertExportChecks(400);}
            OrgLoomFeatureAccess.setGrant(recipient.Id,'export-canvas',true);
            insert new OrgLoomNativePolicy__c(Capability__c='export-canvas',Enabled__c=false);
            System.runAs(recipient){assertExportChecks(400);System.assertEquals(false,OrgLoomNativeAccess.capabilities().get('export-canvas'));}
        }
    }
    private static void assertRequestAccess(Boolean allowed) {
        System.assertEquals(allowed,OrgLoomNativeAccess.capabilities().get('create-slot-canvas'));
        try {
            OrgLoomNativeAccess.requireCapability('create-slot-canvas');
            System.assert(allowed,'Capability checks must require an enabled feature grant.');
        } catch(OrgLoomNativeAccess.AccessDeniedException e){System.assert(!allowed,e.getMessage());}
        try {
            OrgLoomNativeSharedEdits.requests(null,new Map<String,Object>{'drafts'=>new List<Object>{new Map<String,Object>{'tempId'=>'request','slot'=>new Map<String,Object>{'slotId'=>1,'kind'=>'whole-record'}}}});
            System.assert(allowed,'Request creation must require an enabled feature grant.');
        } catch(OrgLoomNativeAccess.AccessDeniedException e){System.assert(!allowed,e.getMessage());}
    }
    @IsTest static void requestsRequireFeatureGrantsAndOrgPolicyWithoutSubscriptionPlans() {
        User administrator=user('requestsadmin'),recipient=user('requestsuser'),outsider=user('requestsnone');
        grant(administrator,new Set<String>{'Admin'});grant(recipient,new Set<String>{'Access'});
        System.runAs(administrator){
            assertRequestAccess(false);
            Boolean found=false;
            for(Object value:(List<Object>)admin('features',new Map<String,Object>()).get('data')){
                Map<String,Object> row=(Map<String,Object>)value;
                if(row.get('id')=='create-slot-canvas'){found=true;System.assertEquals('Create record and field requests',row.get('label'));}
            }
            System.assert(found,'The request feature must be configurable in administration.');
            System.runAs(recipient){assertRequestAccess(false);}
            System.assertEquals(200,admin('grant',new Map<String,Object>{'userId'=>recipient.Id,'capability'=>'create-slot-canvas','enabled'=>true}).get('status'));
            System.runAs(recipient){assertRequestAccess(true);}
            System.assertEquals(200,admin('grant',new Map<String,Object>{'userId'=>recipient.Id,'capability'=>'create-slot-canvas','enabled'=>false}).get('status'));
            System.runAs(recipient){assertRequestAccess(false);}
            OrgLoomFeatureAccess.setGrant(recipient.Id,'create-slot-canvas',true);
            OrgLoomFeatureAccess.setGrant(administrator.Id,'create-slot-canvas',true);
            System.assertEquals(200,admin('policy',new Map<String,Object>{'capability'=>'create-slot-canvas','enabled'=>false}).get('status'));
            assertRequestAccess(false);
            System.runAs(recipient){assertRequestAccess(false);}
            System.assertEquals(200,admin('policy',new Map<String,Object>{'capability'=>'create-slot-canvas','enabled'=>true}).get('status'));
            System.runAs(recipient){assertRequestAccess(true);System.assertEquals(false,OrgLoomNativeAccess.capabilities().get('save-canvas'));}
        }
        System.runAs(outsider){try{OrgLoomNativeAccess.requireCapability('create-slot-canvas');System.assert(false);}catch(OrgLoomNativeAccess.AccessDeniedException e){System.assert(e.getMessage().contains('grant'));}}
    }
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
