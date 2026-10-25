@IsTest private class OrgLoomNativeRecoveryTest {
    @TestSetup static void setup() {
        for(String alias:new List<String>{'recover1','recover2'}){
            User u=new User(ProfileId=UserInfo.getProfileId(),Username=alias+'-'+System.now().getTime()+'@example.invalid',Email=alias+'@example.invalid',Alias=alias,LastName=alias,TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
            OrgLoomAccessFixture.grant(u,new Set<String>{'Access','save-canvas','open-saved-canvas','receive-canvas'});
        }
        Profile minimum=[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' LIMIT 1];
        User limited=new User(ProfileId=minimum.Id,Username='reclimit-'+System.now().getTime()+'@example.invalid',Email='reclimit@example.invalid',Alias='reclimit',LastName='Recovery Restricted',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert limited;
        PermissionSet readAccounts=new PermissionSet(Name='RecoveryReadAccounts',Label='Recovery test read Accounts');insert readAccounts;
        insert new ObjectPermissions(ParentId=readAccounts.Id,SobjectType='Account',PermissionsRead=true);
        insert new PermissionSetAssignment(AssigneeId=limited.Id,PermissionSetId=readAccounts.Id);
        OrgLoomAccessFixture.grant(limited,new Set<String>{'Access'});
    }
    private static String token(){return EncodingUtil.convertToHex(Crypto.generateAesKey(256));}
    private static Map<String,Object> payload(String value){return new Map<String,Object>{'_meta'=>new Map<String,Object>{'savedFrom'=>UserInfo.getOrganizationId()},'schema'=>new Map<String,Object>{'objects'=>new List<Object>()},'loadedRecords'=>new List<Object>(),'drafts'=>new List<Object>{new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','values'=>new Map<String,Object>{'Name'=>value}}},'associations'=>new List<Object>()};}
    private static Map<String,Object> request(String key,String writer,Integer sequence){return new Map<String,Object>{'key'=>key,'writer'=>writer,'sequence'=>sequence,'payload'=>payload('Private recovery draft')};}
    private static Map<String,Object> run(String op,Map<String,Object> body){return (Map<String,Object>)OrgLoomNativeRecovery.handle(op,body);}
    private static void rejects(String op,Map<String,Object> body,String message){try{run(op,body);System.assert(false,'Expected rejection');}catch(Exception e){System.assert(e.getMessage().contains(message),e.getMessage());}}
    @IsTest static void privateEncryptedReplacementAndDiscard(){
        User u=[SELECT Id FROM User WHERE Alias='recover1'];String key=token(),writer=token();
        System.runAs(u){
            run('write',request(key,writer,1));
            OrgLoomNativeRecovery__c first=[SELECT FileId__c,VersionId__c FROM OrgLoomNativeRecovery__c WHERE Key__c=:key];
            Blob encrypted=[SELECT VersionData FROM ContentVersion WHERE Id=:first.VersionId__c].VersionData;
            System.assert(!encrypted.toString().contains('Private recovery draft'));
            run('write',request(key,writer,2));
            OrgLoomNativeRecovery__c second=[SELECT FileId__c,VersionId__c FROM OrgLoomNativeRecovery__c WHERE Key__c=:key];
            System.assertNotEquals(first.FileId__c,second.FileId__c);
            System.assertEquals(0,[SELECT COUNT() FROM ContentDocument WHERE Id=:first.FileId__c]);
            System.assertEquals(1,[SELECT COUNT() FROM ContentVersion WHERE ContentDocumentId=:second.FileId__c]);
            System.assertEquals(true,run('peek',new Map<String,Object>{'key'=>key}).get('available'));
            String next=token();Map<String,Object> restored=run('restore',request(key,next,2));System.assert(JSON.serialize(restored).contains('Private recovery draft'));
            rejects('write',request(key,writer,3),'another tab');
            run('discard',request(key,next,3));
            System.assertEquals(false,run('peek',new Map<String,Object>{'key'=>key}).get('available'));
            rejects('write',request(key,next,4),'discarded');
            System.assertEquals(0,[SELECT COUNT() FROM ContentDocument WHERE Id=:second.FileId__c]);
            System.assertEquals(0,[SELECT COUNT() FROM OrgLoomNativeCanvas__c]);
        }
    }
    @IsTest static void isolationExpiryAndFailedReplacement(){
        User one=[SELECT Id FROM User WHERE Alias='recover1'],two=[SELECT Id FROM User WHERE Alias='recover2'];String key=token(),writer=token();
        System.runAs(one){run('write',request(key,writer,1));Map<String,Object> bad=request(key,writer,2);((Map<String,Object>)((Map<String,Object>)bad.get('payload')).get('_meta')).put('savedFrom','other-org');rejects('write',bad,'Reconcile');}
        System.runAs(two){System.assertEquals(false,run('peek',new Map<String,Object>{'key'=>key}).get('available'));rejects('restore',request(key,writer,1),'unavailable');rejects('write',request(key,writer,1),'DUPLICATE_VALUE');System.assertEquals(0,[SELECT COUNT() FROM ContentDocument WHERE OwnerId=:two.Id]);}
        System.runAs(one){
            String next=token();System.assert(JSON.serialize(run('restore',request(key,next,1))).contains('Private recovery draft'));
            OrgLoomNativeRecovery__c r=[SELECT Id,FileId__c FROM OrgLoomNativeRecovery__c WHERE Key__c=:key];r.Expires__c=System.now().addSeconds(-1);update r;
            rejects('restore',request(key,token(),1),'expired');
            new OrgLoomNativeRecoveryCleanup().execute(null,new List<SObject>{r});
            System.assertEquals(0,[SELECT COUNT() FROM OrgLoomNativeRecovery__c WHERE Id=:r.Id]);System.assertEquals(0,[SELECT COUNT() FROM ContentDocument WHERE Id=:r.FileId__c]);
        }
    }
    @IsTest static void savedLeaseRotationAndTakeover(){
        User one=[SELECT Id FROM User WHERE Alias='recover1'];System.runAs(one){
            Map<String,Object> saved=(Map<String,Object>)OrgLoomNativeCanvases.handle('create',new Map<String,Object>{'name'=>'Recovery lease test','payload'=>payload('Saved')});
            String key=token(),writer=token();Map<String,Object> body=request(key,writer,1);
            body.put('canvasId',saved.get('id'));body.put('versionId',saved.get('versionId'));body.put('sessionToken',saved.get('sessionToken'));run('write',body);
            Map<String,Object> restored=run('restore',request(key,token(),1));System.assertEquals(saved.get('id'),restored.get('id'));System.assertNotEquals(saved.get('sessionToken'),restored.get('sessionToken'));
            OrgLoomNativeCanvases.requireSession((Id)restored.get('id'),(String)restored.get('sessionToken'),false);
            try{OrgLoomNativeCanvases.requireSession((Id)saved.get('id'),(String)saved.get('sessionToken'),false);System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('SESSION_ENDED'));}
            OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>saved.get('id'),'takeover'=>true});
            rejects('restore',request(key,token(),1),'taken over');
        }
    }
    @IsTest static void revisedCanvasAndRevokedGrantBlockRecovery(){
        User one=[SELECT Id FROM User WHERE Alias='recover1'],two=[SELECT Id FROM User WHERE Alias='recover2'];Map<String,Object> saved;
        System.runAs(one){saved=(Map<String,Object>)OrgLoomNativeCanvases.handle('create',new Map<String,Object>{'name'=>'Shared recovery','payload'=>payload('Saved')});}
        Id id=(Id)saved.get('id');insert new OrgLoomNativeGrant__c(Key__c=id+':'+two.Id,Canvas__c=id,Recipient__c=two.Id,Role__c='editor');
        String key=token(),writer=token();
        System.runAs(two){Map<String,Object> opened=(Map<String,Object>)OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>id,'takeover'=>true});Map<String,Object> body=request(key,writer,1);body.put('canvasId',id);body.put('versionId',opened.get('versionId'));body.put('sessionToken',opened.get('sessionToken'));run('write',body);}
        delete [SELECT Id FROM OrgLoomNativeGrant__c WHERE Canvas__c=:id];
        System.runAs(two){rejects('restore',request(key,token(),1),'not shared');}
    }
    @IsTest static void schedulerAndRemotingAuthorization(){
        Test.startTest();System.schedule('Recovery cleanup test','0 0 1 * * ?',new OrgLoomNativeRecoveryCleanup());Test.stopTest();
        System.assertNotEquals(null,new OrgLoomNativeRecoveryCleanup().start(null));
        new OrgLoomNativeRecoveryCleanup().finish(null);
        User one=[SELECT Id FROM User WHERE Alias='recover1'];System.runAs(one){
            Map<String,Object> response=(Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke('recovery:peek',JSON.serialize(new Map<String,Object>{'key'=>token()})));System.assertEquals(200,response.get('status'));
        }
    }
    @IsTest static void schedulerReplacesHourlyJobAndDoesNotDuplicateDailyJob(){
        String testJobName='Org Loom recovery test '+System.now().getTime();
        OrgLoomNativeRecoveryCleanup.jobName=testJobName;
        Id oldJob=System.schedule(testJobName,'0 0 * * * ?',new OrgLoomNativeRecoveryCleanup());
        OrgLoomNativeRecoveryCleanup.scheduleOnce();
        List<CronTrigger> jobs=[SELECT Id,CronExpression FROM CronTrigger WHERE CronJobDetail.Name=:testJobName AND State NOT IN ('DELETED','COMPLETE','ERROR')];
        System.assertEquals(1,jobs.size());
        System.assertEquals('0 0 2 * * ?',jobs[0].CronExpression);
        System.assertNotEquals(oldJob,jobs[0].Id);
        OrgLoomNativeRecoveryCleanup.scheduleOnce();
        System.assertEquals(1,[SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name=:testJobName AND State NOT IN ('DELETED','COMPLETE','ERROR')]);
    }
    @IsTest static void restoreRechecksObjectAccess(){
        User limited=[SELECT Id FROM User WHERE Alias='reclimit'];String key=token(),writer=token();
        System.runAs(limited){run('write',request(key,writer,1));}
        delete [SELECT Id FROM PermissionSetAssignment WHERE AssigneeId=:limited.Id AND PermissionSet.Name='RecoveryReadAccounts'];
        System.runAs(limited){
            Map<String,Object> restored=run('restore',request(key,token(),1));
            System.assertEquals(true,restored.get('partialView'));System.assertEquals(0,((List<Object>)((Map<String,Object>)restored.get('payload')).get('drafts')).size());
        }
    }
}
