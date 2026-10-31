@IsTest private class OrgLoomNativeActivityTest {
    @TestSetup static void setup(){
        // Admins-only installation grants custom permissions to the installer's
        // profile. The non-admin fixture must not inherit those profile grants.
        Id memberProfile=[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' LIMIT 1].Id;
        List<User> users=new List<User>();
        for(String alias:new List<String>{'actadmin','actuser'})users.add(new User(ProfileId=alias=='actuser'?memberProfile:UserInfo.getProfileId(),Username=alias+System.now().getTime()+'@example.invalid',Email=alias+'@example.invalid',Alias=alias,LastName=alias,TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US'));
        insert users;
        OrgLoomAccessFixture.grant(users[0],new Set<String>{'Admin','save-canvas','share-canvas','open-saved-canvas','upload-records','recall-upload','view-activity-history'});
        OrgLoomAccessFixture.grant(users[1],new Set<String>{'Access','view-activity-history','receive-canvas','open-saved-canvas'});
    }
    private static User actor(String alias){return [SELECT Id FROM User WHERE Alias=:alias LIMIT 1];}
    private static Map<String,Object> payload(){return new Map<String,Object>{'_meta'=>new Map<String,Object>{'savedFrom'=>UserInfo.getOrganizationId()},'loadedRecords'=>new List<Object>(),'drafts'=>new List<Object>(),'associations'=>new List<Object>()};}
    @IsTest static void adminOnlyAndNoClientWriteEndpoint(){
        System.runAs(actor('actadmin')){OrgLoomNativeActivity.record('canvas_created','success',null,'New canvas saved.');System.assert(new OrgLoomNativeActivity().getAllowed());}
        System.runAs(actor('actuser')){
            System.assert(!new OrgLoomNativeActivity().getAllowed());
            try{OrgLoomNativeActivity.listEvents(new Map<String,Object>());System.assert(false);}catch(OrgLoomNativeAccess.AccessDeniedException expected){}
            System.assertEquals(400,((Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeActivity.invoke('list','{}'))).get('status'));
        }
        System.runAs(actor('actadmin')){
            System.assertEquals(400,((Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeActivity.invoke('record','{}'))).get('status'));
            System.assertEquals(200,((Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeActivity.invoke('users','{"search":"actuser"}'))).get('status'));
        }
        System.assertEquals(1,[SELECT COUNT() FROM OrgLoomNativeActivity__c]);
    }
    @IsTest static void paginationAndFiltersIncludeOtherUsersWithoutRecordData(){
        User admin=actor('actadmin'),member=actor('actuser');
        List<OrgLoomNativeActivity__c> seeds=new List<OrgLoomNativeActivity__c>();
        System.runAs(member){for(Integer i=0;i<55;i++)seeds.add(new OrgLoomNativeActivity__c(Action__c='upload',Status__c='success',Detail__c='1 created.'));insert seeds;}
        System.runAs(admin){
            OrgLoomNativeActivity.record('recall','partial',null,'1 field restored.');
            Map<String,Object> filters=new Map<String,Object>{'userId'=>member.Id,'action'=>'upload','status'=>'success','from'=>String.valueOf(Date.today()),'to'=>String.valueOf(Date.today())};
            Map<String,Object> first=OrgLoomNativeActivity.listEvents(filters);System.assertEquals(50,((List<Object>)first.get('rows')).size());
            Set<String> seen=new Set<String>();for(Object raw:(List<Object>)first.get('rows'))seen.add((String)((Map<String,Object>)raw).get('id'));
            filters.putAll((Map<String,Object>)first.get('next'));Map<String,Object> second=OrgLoomNativeActivity.listEvents(filters);
            System.assertEquals(5,((List<Object>)second.get('rows')).size());System.assertEquals(null,second.get('next'));
            for(Object raw:(List<Object>)second.get('rows'))System.assert(!seen.contains((String)((Map<String,Object>)raw).get('id')));
            System.assertEquals(0,((List<Object>)OrgLoomNativeActivity.listEvents(new Map<String,Object>{'from'=>String.valueOf(Date.today().addDays(1))}).get('rows')).size());
            System.assertEquals(1,((List<Object>)OrgLoomNativeActivity.listEvents(new Map<String,Object>{'status'=>'partial'}).get('rows')).size());
            System.assertEquals(400,((Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeActivity.invoke('list','{"action":"injected"}'))).get('status'));
        }
    }
    @IsTest static void canvasLifecycleAndRejectedSave(){System.runAs(actor('actadmin')){
        Map<String,Object> created=(Map<String,Object>)OrgLoomNativeCanvases.handle('create',new Map<String,Object>{'name'=>'SECRET CANVAS TITLE','payload'=>payload()});
        Id id=(Id)created.get('id');String token=(String)created.get('sessionToken');
        Map<String,Object> saved=(Map<String,Object>)OrgLoomNativeCanvases.handle('save',new Map<String,Object>{'id'=>id,'sessionToken'=>token,'expectedVersionId'=>created.get('versionId'),'payload'=>payload()});
        OrgLoomNativeCanvases.handle('grant',new Map<String,Object>{'id'=>id,'recipientSfUserId'=>actor('actuser').Id,'role'=>'viewer'});
        OrgLoomNativeCanvases.handle('grant',new Map<String,Object>{'id'=>id,'recipientSfUserId'=>actor('actuser').Id,'role'=>'none'});
        String rejected=OrgLoomNativeController.invoke('canvas:save',JSON.serialize(new Map<String,Object>{'id'=>id,'sessionToken'=>token,'expectedVersionId'=>'invalid','payload'=>payload()}));
        System.assertEquals(400,((Map<String,Object>)JSON.deserializeUntyped(rejected)).get('status'));
        System.assertEquals(1,[SELECT COUNT() FROM OrgLoomNativeActivity__c WHERE Status__c='failed']);
        OrgLoomNativeCanvases.handle('delete',new Map<String,Object>{'id'=>id,'sessionToken'=>token});
        List<OrgLoomNativeActivity__c> events=[SELECT Action__c,Status__c,Detail__c,Reference__c FROM OrgLoomNativeActivity__c];
        System.assertEquals(6,events.size());System.assert(!JSON.serialize(events).contains('SECRET CANVAS TITLE'));
        System.assertEquals(1,[SELECT COUNT() FROM OrgLoomNativeActivity__c WHERE Action__c='canvas_deleted' AND Reference__c=:id]);
    }}
    @IsTest static void uploadRetryAndRefreshDoNotExposeValues(){System.runAs(actor('actadmin')){
        Map<String,Object> body=new Map<String,Object>{'attemptId'=>EncodingUtil.convertToHex(Crypto.generateAesKey(128)),'expectedSfOrgId'=>UserInfo.getOrganizationId(),
            'records'=>new List<Object>{new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','values'=>new Map<String,Object>{'Name'=>'SECRET RECORD VALUE'}}},'deletes'=>new List<Object>()};
        Map<String,Object> uploaded=(Map<String,Object>)OrgLoomNativeUpload.execute(body);OrgLoomNativeUpload.execute(body);
        System.assertEquals(1,[SELECT COUNT() FROM OrgLoomNativeActivity__c WHERE Action__c='upload']);
        Map<String,Object> row=(Map<String,Object>)((List<Object>)uploaded.get('results'))[0];
        OrgLoomNativeReads.handle('refresh',new Map<String,Object>{'records'=>new List<Object>{new Map<String,Object>{'objectName'=>'Account','sfId'=>row.get('id'),'tempId'=>1}}});
        List<OrgLoomNativeActivity__c> events=[SELECT Action__c,Status__c,Detail__c,Reference__c FROM OrgLoomNativeActivity__c];
        System.assertEquals(2,events.size());System.assert(!JSON.serialize(events).contains('SECRET RECORD VALUE'));
        System.assertEquals(1,[SELECT COUNT() FROM OrgLoomNativeActivity__c WHERE Action__c='records_refreshed']);
        OrgLoomNativeController.invoke('upload',JSON.serialize(new Map<String,Object>{'expectedSfOrgId'=>'bad','records'=>new List<Object>(),'deletes'=>new List<Object>()}));
        System.assertEquals(1,[SELECT COUNT() FROM OrgLoomNativeActivity__c WHERE Status__c='failed']);
    }}
}
