@IsTest private class OrgLoomNativeRecipientsTest {
    @TestSetup static void setup(){
        Id profile=[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' LIMIT 1].Id;
        List<User> users=new List<User>();
        for(String alias:new List<String>{'nrOwner','nrGood','nrBase','nrRecv','nrOpen','nrOff'})users.add(makeUser(profile,alias));
        for(Integer i=0;i<25;i++)users.add(makeUser(profile,'nrX'+i));
        insert users;
        for(Integer i=0;i<6;i++){
            Set<String> caps=new Set<String>{'Access','receive-canvas','open-saved-canvas'};
            if(i==0)caps.addAll(new Set<String>{'save-canvas','share-canvas','create-slot-canvas'});
            if(i==3)caps.remove('receive-canvas');
            if(i==4)caps.remove('open-saved-canvas');
            OrgLoomAccessFixture.grant(users[i],caps);
        }
        String ns=OrgLoomNativeAccess.packageNamespace();
        delete [SELECT Id FROM PermissionSetAssignment WHERE AssigneeId=:users[2].Id AND PermissionSet.Name='OrgLoomNativePrototype' AND PermissionSet.NamespacePrefix=:ns];
        users[5].IsActive=false;update users[5];
    }
    private static User makeUser(Id profile,String alias){
        return new User(ProfileId=profile,Username=alias+System.now().getTime()+'@example.invalid',Email='recipient@example.invalid',Alias=alias,
            LastName='Recipient QA '+(alias=='nrGood'?'ZZ eligible':alias),TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');
    }
    private static User actor(String alias){return [SELECT Id,Username FROM User WHERE Alias=:alias LIMIT 1];}
    private static Set<Id> search(){
        Map<String,Object> result=(Map<String,Object>)OrgLoomNativeCanvases.users(new Map<String,Object>{'q'=>'Recipient QA'});
        Set<Id> ids=new Set<Id>();for(Object raw:(List<Object>)result.get('users'))ids.add((Id)(String)((Map<String,Object>)raw).get('id'));return ids;
    }
    private static String createCanvas(){
        Map<String,Object> payload=new Map<String,Object>{'_meta'=>new Map<String,Object>{'savedFrom'=>UserInfo.getOrganizationId()},'loadedRecords'=>new List<Object>(),'drafts'=>new List<Object>(),'associations'=>new List<Object>()};
        return (String)((Map<String,Object>)OrgLoomNativeCanvases.handle('create',new Map<String,Object>{'name'=>'Recipient eligibility','payload'=>payload})).get('id');
    }
    private static void grant(String cid,Id recipient,String role){OrgLoomNativeCanvases.handle('grant',new Map<String,Object>{'id'=>cid,'recipientSfUserId'=>recipient,'role'=>role});}
    private static void denied(String cid,Id recipient){
        for(String role:new List<String>{'viewer','contributor','editor'}){
            try{grant(cid,recipient,role);System.assert(false,'Ineligible recipient accepted');}
            catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('cannot receive')||e.getMessage().contains('unavailable'),e.getMessage());}
        }
    }
    @IsTest static void pickerAndShareUseSamePermissionsBeforeLimit(){
        User good=actor('nrGood');
        System.runAs(actor('nrOwner')){
            System.assertEquals(new Set<Id>{good.Id},search(),'More than 20 ineligible users must not hide the eligible match');
            String cid=createCanvas();
            for(String role:new List<String>{'viewer','contributor','editor'})grant(cid,good.Id,role);
            System.assertEquals(1,[SELECT COUNT() FROM OrgLoomNativeGrant__c WHERE Canvas__c=:cid]);
        }
    }
    private static void rejectsRecipient(String alias){
        Id recipient=actor(alias).Id;
        System.runAs(actor('nrOwner')){denied(createCanvas(),recipient);}
    }
    @IsTest static void leftoverFeaturesWithoutBaseAccessCannotReceive(){rejectsRecipient('nrBase');}
    @IsTest static void missingReceivePermissionCannotReceive(){rejectsRecipient('nrRecv');}
    @IsTest static void missingOpenPermissionCannotReceive(){rejectsRecipient('nrOpen');}
    @IsTest static void inactiveRecipientCannotReceive(){rejectsRecipient('nrOff');}
    @IsTest static void unassignedRecipientCannotReceive(){rejectsRecipient('nrX0');}
    @IsTest static void staleSelectionAndRemovalAfterRevocation(){
        User good=actor('nrGood');String cid;
        System.runAs(actor('nrOwner')){System.assert(search().contains(good.Id));cid=createCanvas();grant(cid,good.Id,'viewer');}
        String ns=OrgLoomNativeAccess.packageNamespace();
        delete [SELECT Id FROM PermissionSetAssignment WHERE AssigneeId=:good.Id AND PermissionSet.Name='OrgLoomNativePrototype' AND PermissionSet.NamespacePrefix=:ns];
        System.runAs(actor('nrOwner')){
            System.assertEquals(0,search().size());denied(cid,good.Id);
            grant(cid,good.Id,'none');System.assertEquals(0,[SELECT COUNT() FROM OrgLoomNativeGrant__c WHERE Canvas__c=:cid]);
        }
    }
    @IsTest static void eitherOrgPolicyBlocksPickerAndShare(){
        System.runAs(actor('nrOwner')){
            String cid=createCanvas();Id good=actor('nrGood').Id;
            for(String capability:new List<String>{'receive-canvas','open-saved-canvas'}){
                OrgLoomNativePolicy__c policy=new OrgLoomNativePolicy__c(Capability__c=capability,Enabled__c=false);insert policy;
                System.assertEquals(0,search().size());denied(cid,good);delete policy;
            }
            System.assertEquals(new Set<Id>{good},search());
        }
    }
    @IsTest static void disabledFeatureGrantIsNotEligible(){
        User good=actor('nrGood');String key=String.valueOf(good.Id);
        update new OrgLoomFeatureAccess__c(Id=[SELECT Id FROM OrgLoomFeatureAccess__c WHERE UserId__c=:key AND Capability__c='open-saved-canvas'].Id,Enabled__c=false);
        System.runAs(actor('nrOwner')){System.assertEquals(0,search().size());denied(createCanvas(),good.Id);}
    }
    @IsTest static void calculatedGroupCanProvideBaseAccess(){
        User recipient=actor('nrBase');String ns=OrgLoomNativeAccess.packageNamespace();
        Id accessSet=[SELECT Id FROM PermissionSet WHERE Name='OrgLoomNativePrototype' AND NamespacePrefix=:ns LIMIT 1].Id;
        PermissionSetGroup groupAccess=new PermissionSetGroup(DeveloperName='OrgLoomRecipientTest',MasterLabel='Org Loom Recipient Test');insert groupAccess;
        insert new PermissionSetGroupComponent(PermissionSetGroupId=groupAccess.Id,PermissionSetId=accessSet);Test.calculatePermissionSetGroup(groupAccess.Id);
        insert new PermissionSetAssignment(AssigneeId=recipient.Id,PermissionSetGroupId=groupAccess.Id);
        System.runAs(recipient){System.assert(FeatureManagement.checkPermission('OrgLoomNative_Access'));}
        System.runAs(actor('nrOwner')){System.assert(search().contains(recipient.Id));grant(createCanvas(),recipient.Id,'viewer');}
    }
}
