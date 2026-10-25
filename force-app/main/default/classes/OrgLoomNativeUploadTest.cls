@IsTest private class OrgLoomNativeUploadTest {
    @TestSetup static void setup() {
        User u=new User(ProfileId=UserInfo.getProfileId(),Username='native-writes-'+System.now().getTime()+'@example.invalid',Email='native-writes@example.invalid',Alias='nawrite',LastName='Native Writes Test',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;

        OrgLoomAccessFixture.grant(u,new Set<String>{'Access','upload-records'});
    }
    private static Map<String,Object> request(List<Object> rows) {return new Map<String,Object>{'attemptId'=>EncodingUtil.convertToHex(Crypto.generateAesKey(128)),'expectedSfOrgId'=>UserInfo.getOrganizationId(),'records'=>rows,'deletes'=>new List<Object>()};}
    private static Map<String,Object> draft(Integer temp,String objectName,Map<String,Object> values) {return new Map<String,Object>{'tempId'=>temp,'objectName'=>objectName,'values'=>values};}
    @IsTest static void createsLinkedRecordsAndReplaysWithoutDuplication() {
        User actor=[SELECT Id FROM User WHERE Alias='nawrite' LIMIT 1];System.runAs(actor) {
            Map<String,Object> body=request(new List<Object>{draft(1,'Contact',new Map<String,Object>{'LastName'=>'Native child'}),draft(2,'Account',new Map<String,Object>{'Name'=>'Native parent'})});
            body.put('associations',new List<Object>{new Map<String,Object>{'fromId'=>1,'toId'=>2,'fieldName'=>'AccountId'}});
            Map<String,Object> first=(Map<String,Object>)OrgLoomNativeUpload.execute(body);
            System.assertEquals(2,((List<Object>)first.get('results')).size());
            Contact c=[SELECT Id,Account.Name FROM Contact WHERE LastName='Native child' LIMIT 1];System.assertEquals('Native parent',c.Account.Name);
            Map<String,Object> replay=(Map<String,Object>)OrgLoomNativeUpload.execute(body);
            System.assertEquals(2,((List<Object>)replay.get('results')).size());System.assertEquals(1,[SELECT COUNT() FROM Contact WHERE LastName='Native child']);
            ((Map<String,Object>)((Map<String,Object>)((List<Object>)body.get('records'))[0]).get('values')).put('LastName','different');
            try{OrgLoomNativeUpload.execute(body);System.assert(false);}catch(OrgLoomNativeUpload.UploadException e){System.assert(e.getMessage().contains('different'));}
        }
    }
    @IsTest static void failedBatchRollsBackRecordsAndReceipt() {
        User actor=[SELECT Id FROM User WHERE Alias='nawrite' LIMIT 1];System.runAs(actor) {
            Map<String,Object> body=request(new List<Object>{draft(1,'Account',new Map<String,Object>{'Name'=>'Must roll back'}),draft(2,'Contact',new Map<String,Object>{'FirstName'=>'Missing required last name'})});
            body.put('associations',new List<Object>{new Map<String,Object>{'fromId'=>2,'toId'=>1,'fieldName'=>'AccountId'}});
            Boolean failed=false;try{OrgLoomNativeUpload.execute(body);}catch(Exception e){failed=true;}System.assert(failed);
            System.assertEquals(0,[SELECT COUNT() FROM Account WHERE Name='Must roll back']);System.assertEquals(0,[SELECT COUNT() FROM OrgLoomNativeAttempt__c]);
        }
    }
    @IsTest static void updateDeleteAndPermissionValidation() {
        User actor=[SELECT Id FROM User WHERE Alias='nawrite' LIMIT 1];System.runAs(actor) {
            Account a=new Account(Name='Delete fixture');insert a;
            SObject before=OrgLoomNativeController.read('Account',new Set<Id>{a.Id},false)[0];
            Map<String,Object> body=request(new List<Object>());body.put('deletes',new List<Object>{new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','sfId'=>a.Id,'loadedValues'=>JSON.deserializeUntyped(JSON.serialize(before))}});
            Map<String,Object> result=(Map<String,Object>)OrgLoomNativeUpload.execute(body);System.assertEquals(1,((List<Object>)result.get('deletes')).size());
            System.assertEquals(0,[SELECT COUNT() FROM Account WHERE Id=:a.Id]);
            Map<String,Object> absent=(Map<String,Object>)OrgLoomNativeUpload.receipt('unconfirmed-attempt');System.assertEquals('unconfirmed',absent.get('status'));
            body=request(new List<Object>{draft(1,'Account',new Map<String,Object>{'Name'=>'Bad field','CreatedDate'=>'2000-01-01T00:00:00.000Z'})});
            try{OrgLoomNativeUpload.execute(body);System.assert(false);}catch(OrgLoomNativeUpload.UploadException e){System.assert(e.getMessage().contains('permission'));}
        }
    }
    @IsTest static void malformedLinksAndUncertainOperationsAreRejected() {
        User actor=[SELECT Id FROM User WHERE Alias='nawrite' LIMIT 1];System.runAs(actor) {
            Map<String,Object> body=request(new List<Object>{draft(1,'Account',new Map<String,Object>{'Name'=>'No insert'})});body.put('associations',new List<Object>{new Map<String,Object>{'fromId'=>1,'toId'=>99,'fieldName'=>'ParentId'}});
            try{OrgLoomNativeUpload.execute(body);System.assert(false);}catch(OrgLoomNativeUpload.UploadException e){System.assert(e.getMessage().contains('both ends'));}
            body=request(new List<Object>{draft(1,'Account',new Map<String,Object>{'Name'=>'No insert'})});body.put('canvasId','unvalidated');
            Boolean rejected=false;try{OrgLoomNativeUpload.execute(body);}catch(Exception e){rejected=true;}System.assert(rejected);
            body=request(new List<Object>{draft(1,'Account',new Map<String,Object>{'Name'=>'No insert'})});body.put('expectedSfOrgId','wrong');
            try{OrgLoomNativeUpload.execute(body);System.assert(false);}catch(OrgLoomNativeUpload.UploadException e){System.assert(e.getMessage().contains('org'));}
            System.assertEquals(0,[SELECT COUNT() FROM Account WHERE Name='No insert']);
        }
    }
    @IsTest static void bulkCreateAndUpdateUseBoundedQueriesAndDml() {
        User actor=[SELECT Id FROM User WHERE Alias='nawrite' LIMIT 1];System.runAs(actor) {
            List<Object> rows=new List<Object>();for(Integer i=0;i<100;i++)rows.add(draft(i,'Account',new Map<String,Object>{'Name'=>'Native bulk '+i}));
            Test.startTest();Integer startDml=Limits.getDmlStatements(),startQueries=Limits.getQueries();
            Map<String,Object> first=(Map<String,Object>)OrgLoomNativeUpload.execute(request(rows));
            System.assertEquals(100,((List<Object>)first.get('results')).size());
            System.assert(Limits.getDmlStatements()-startDml<10,'DML must scale by object, not record count.');
            System.assert(Limits.getQueries()-startQueries<15,'Queries must scale by object, not record count.');
            rows.clear();Integer index=0;
            for(Account a:[SELECT Id,Name,LastModifiedDate FROM Account WHERE Name LIKE 'Native bulk %']){
                Map<String,Object> row=draft(index++,'Account',new Map<String,Object>{'Name'=>a.Name+' changed'});row.put('loadedFromId',a.Id);row.put('loadedValues',JSON.deserializeUntyped(JSON.serialize(a)));rows.add(row);
            }
            startDml=Limits.getDmlStatements();startQueries=Limits.getQueries();
            OrgLoomNativeUpload.execute(request(rows));
            System.assert(Limits.getDmlStatements()-startDml<10);System.assert(Limits.getQueries()-startQueries<15);Test.stopTest();
            System.assertEquals(100,[SELECT COUNT() FROM Account WHERE Name LIKE 'Native bulk % changed']);
        }
    }
    @IsTest static void deletionIsChildFirstEvenIfParentIsListedFirst() {
        User actor=[SELECT Id FROM User WHERE Alias='nawrite' LIMIT 1];System.runAs(actor) {
            Account parent=new Account(Name='Delete hierarchy');insert parent;Contact child=new Contact(LastName='Delete child',AccountId=parent.Id);insert child;
            List<Object> deleted=new List<Object>();Integer temp=0;
            for(SObject row:new List<SObject>{OrgLoomNativeController.read('Account',new Set<Id>{parent.Id},false)[0],OrgLoomNativeController.read('Contact',new Set<Id>{child.Id},false)[0]})deleted.add(new Map<String,Object>{'tempId'=>++temp,'objectName'=>row.getSObjectType().getDescribe().getName(),'sfId'=>row.get('Id'),'loadedValues'=>JSON.deserializeUntyped(JSON.serialize(row))});
            Map<String,Object> body=request(new List<Object>());body.put('deletes',deleted);
            Map<String,Object> result=(Map<String,Object>)OrgLoomNativeUpload.execute(body);List<Object> outcomes=(List<Object>)result.get('deletes');
            System.assertEquals('Contact',((Map<String,Object>)outcomes[0]).get('objectName'));System.assertEquals(2,outcomes.size());
            System.assertEquals(0,[SELECT COUNT() FROM Account WHERE Id=:parent.Id]);System.assertEquals(0,[SELECT COUNT() FROM Contact WHERE Id=:child.Id]);
        }
    }
    @IsTest static void salesforceHierarchyRulesStillRejectCycles() {
        User actor=[SELECT Id FROM User WHERE Alias='nawrite' LIMIT 1];System.runAs(actor) {
            Map<String,Object> body=request(new List<Object>{draft(1,'Contact',new Map<String,Object>{'LastName'=>'Cycle one'}),draft(2,'Contact',new Map<String,Object>{'LastName'=>'Cycle two'})});
            body.put('associations',new List<Object>{new Map<String,Object>{'fromId'=>1,'toId'=>2,'fieldName'=>'ReportsToId'},new Map<String,Object>{'fromId'=>2,'toId'=>1,'fieldName'=>'ReportsToId'}});
            Boolean failed=false;try{OrgLoomNativeUpload.execute(body);}catch(DmlException e){failed=true;System.assert(e.getMessage().contains('CIRCULAR_DEPENDENCY'));}
            System.assert(failed);System.assertEquals(0,[SELECT COUNT() FROM Contact WHERE LastName IN ('Cycle one','Cycle two')]);System.assertEquals(0,[SELECT COUNT() FROM OrgLoomNativeAttempt__c]);
        }
    }
    @IsTest static void replayIgnoresLeaseTokenButRejectsChangedContent() {
        User actor=[SELECT Id FROM User WHERE Alias='nawrite' LIMIT 1];System.runAs(actor) {
            Map<String,Object> body=request(new List<Object>{draft(1,'Account',new Map<String,Object>{'Name'=>'Native lease replay'})});
            OrgLoomNativeUpload.execute(body);body.put('nativeSessionToken','renewed-token');OrgLoomNativeUpload.execute(body);
            System.assertEquals(1,[SELECT COUNT() FROM Account WHERE Name='Native lease replay']);
            body.put('records',new List<Object>{draft(1,'Account',new Map<String,Object>{'Name'=>'Altered replay'})});
            Boolean rejected=false;try{OrgLoomNativeUpload.execute(body);}catch(OrgLoomNativeUpload.UploadException e){rejected=true;System.assert(e.getMessage().contains('different'));}System.assert(rejected);
        }
    }
    @IsTest static void oversizedUploadsAndStaleBaselinesDoNotWrite() {
        User actor=[SELECT Id FROM User WHERE Alias='nawrite' LIMIT 1];System.runAs(actor) {
            List<Object> rows=new List<Object>();for(Integer i=0;i<201;i++)rows.add(draft(i,'Account',new Map<String,Object>{'Name'=>'Oversized native '+i}));
            Boolean rejected=false;try{OrgLoomNativeUpload.execute(request(rows));}catch(OrgLoomNativeUpload.UploadException e){rejected=true;}System.assert(rejected);
            System.assertEquals(0,[SELECT COUNT() FROM Account WHERE Name LIKE 'Oversized native %']);
            Account a=new Account(Name='Stale native');insert a;Map<String,Object> row=draft(1,'Account',new Map<String,Object>{'Name'=>'Should not change'});
            row.put('loadedFromId',a.Id);row.put('loadedValues',new Map<String,Object>{'LastModifiedDate'=>'2000-01-01T00:00:00.000Z'});
            rejected=false;try{OrgLoomNativeUpload.execute(request(new List<Object>{row}));}catch(OrgLoomNativeUpload.UploadException e){rejected=true;System.assert(e.getMessage().contains('baseline'));}System.assert(rejected);
            System.assertEquals('Stale native',[SELECT Name FROM Account WHERE Id=:a.Id].Name);
        }
    }
    @IsTest static void rejectedBatchDoesNotCommitEarlierObjects() {
        User actor=[SELECT Id FROM User WHERE Alias='nawrite' LIMIT 1];System.runAs(actor) {
            List<Object> rows=new List<Object>();for(Integer i=0;i<100;i++)rows.add(draft(i,'Account',new Map<String,Object>{'Name'=>'Bulk rollback '+i}));
            rows.add(draft(101,'Contact',new Map<String,Object>{'FirstName'=>'Missing last name'}));Map<String,Object> body=request(rows);
            body.put('associations',new List<Object>{new Map<String,Object>{'fromId'=>101,'toId'=>0,'fieldName'=>'AccountId'}});
            Boolean failed=false;try{OrgLoomNativeUpload.execute(body);}catch(Exception e){failed=true;}System.assert(failed);
            System.assertEquals(0,[SELECT COUNT() FROM Account WHERE Name LIKE 'Bulk rollback %']);System.assertEquals(0,[SELECT COUNT() FROM OrgLoomNativeAttempt__c]);
        }
    }
    @IsTest static void independentBatchesKeepSuccessAndDurableFailureReceipts() {
        User actor=[SELECT Id FROM User WHERE Alias='nawrite' LIMIT 1];System.runAs(actor) {
            List<Object> rows=new List<Object>();for(Integer i=0;i<200;i++)rows.add(draft(i,'Account',new Map<String,Object>{'Name'=>'Planned batch '+i}));
            rows.add(draft(201,'Contact',new Map<String,Object>{'FirstName'=>'Missing required last name'}));Map<String,Object> body=request(rows);
            Test.startTest();Map<String,Object> plan=(Map<String,Object>)OrgLoomNativeUploadPlan.plan(body);List<Object> groups=(List<Object>)plan.get('groups');System.assertEquals(2,groups.size());
            Map<String,Object> initial=(Map<String,Object>)OrgLoomNativeUpload.receipt((String)body.get('attemptId'));System.assertEquals('unconfirmed',initial.get('status'));
            OrgLoomNativeUploadPlan.execute(new Map<String,Object>{'rootAttemptId'=>body.get('attemptId'),'index'=>0,'payload'=>groups[0]});
            Map<String,Object> failure=(Map<String,Object>)OrgLoomNativeUploadPlan.execute(new Map<String,Object>{'rootAttemptId'=>body.get('attemptId'),'index'=>1,'payload'=>groups[1]});
            System.assertEquals(false,((Map<String,Object>)((List<Object>)failure.get('results'))[0]).get('success'));
            Map<String,Object> receipt=(Map<String,Object>)OrgLoomNativeUpload.receipt((String)body.get('attemptId'));System.assertEquals('completed',receipt.get('status'));System.assertEquals(201,((List<Object>)receipt.get('results')).size());System.assertEquals(1,((List<Object>)receipt.get('retryableTempIds')).size());
            Map<String,Object> resumed=(Map<String,Object>)OrgLoomNativeUploadPlan.plan(body);System.assertEquals(2,((List<Object>)resumed.get('groups')).size());
            OrgLoomNativeUploadPlan.execute(new Map<String,Object>{'rootAttemptId'=>body.get('attemptId'),'index'=>0,'payload'=>groups[0]});Test.stopTest();
            System.assertEquals(200,[SELECT COUNT() FROM Account WHERE Name LIKE 'Planned batch %']);
            System.assertEquals(1,[SELECT COUNT() FROM OrgLoomNativeActivity__c WHERE Action__c='upload' AND Status__c='success']);
            System.assertEquals(1,[SELECT COUNT() FROM OrgLoomNativeActivity__c WHERE Action__c='upload' AND Status__c='failed']);
            for(OrgLoomNativeAttempt__c journal:[SELECT Results__c FROM OrgLoomNativeAttempt__c]){System.assert(!journal.Results__c.contains('Planned batch'));System.assert(!journal.Results__c.contains('Missing required last name'));}
        }
    }
    @IsTest static void plannedPayloadTamperingAndOversizeConnectedGroupsAreRejected() {
        User actor=[SELECT Id FROM User WHERE Alias='nawrite' LIMIT 1];System.runAs(actor) {
            Map<String,Object> body=request(new List<Object>{draft(1,'Account',new Map<String,Object>{'Name'=>'Planned original'})});Map<String,Object> plan=(Map<String,Object>)OrgLoomNativeUploadPlan.plan(body);
            Map<String,Object> batchPayload=(Map<String,Object>)((List<Object>)plan.get('groups'))[0];((Map<String,Object>)((Map<String,Object>)((List<Object>)batchPayload.get('records'))[0]).get('values')).put('Name','Tampered');
            Boolean rejected=false;try{OrgLoomNativeUploadPlan.execute(new Map<String,Object>{'rootAttemptId'=>body.get('attemptId'),'index'=>0,'payload'=>batchPayload});}catch(OrgLoomNativeUpload.UploadException e){rejected=true;}System.assert(rejected);System.assertEquals(0,[SELECT COUNT() FROM Account WHERE Name='Tampered']);
            List<Object> rows=new List<Object>(),links=new List<Object>();rows.add(draft(0,'Account',new Map<String,Object>{'Name'=>'Large family'}));
            for(Integer i=1;i<=200;i++){rows.add(draft(i,'Contact',new Map<String,Object>{'LastName'=>'Large family child'}));links.add(new Map<String,Object>{'fromId'=>i,'toId'=>0,'fieldName'=>'AccountId'});}
            body=request(rows);body.put('associations',links);rejected=false;try{OrgLoomNativeUploadPlan.plan(body);}catch(OrgLoomNativeUpload.UploadException e){rejected=true;System.assert(e.getMessage().contains('connected group'));}System.assert(rejected);
        }
    }
    @IsTest static void existingReferencesKeepDeletesInTheSameTransaction() {
        User actor=[SELECT Id FROM User WHERE Alias='nawrite' LIMIT 1];System.runAs(actor) {
            Account a=new Account(Name='Planned deletion');insert a;Contact c=new Contact(LastName='Planned child',AccountId=a.Id);insert c;
            Map<String,Object> body=request(new List<Object>());List<Object> deleted=new List<Object>();Integer i=0;
            for(SObject row:new List<SObject>{OrgLoomNativeController.read('Account',new Set<Id>{a.Id},false)[0],OrgLoomNativeController.read('Contact',new Set<Id>{c.Id},false)[0]})deleted.add(new Map<String,Object>{'tempId'=>++i,'objectName'=>row.getSObjectType().getDescribe().getName(),'sfId'=>row.get('Id'),'loadedValues'=>JSON.deserializeUntyped(JSON.serialize(row))});
            body.put('deletes',deleted);Map<String,Object> plan=(Map<String,Object>)OrgLoomNativeUploadPlan.plan(body);List<Object> groups=(List<Object>)plan.get('groups');System.assertEquals(1,groups.size());
            OrgLoomNativeUploadPlan.execute(new Map<String,Object>{'rootAttemptId'=>body.get('attemptId'),'index'=>0,'payload'=>groups[0]});
            // Re-planning after deletion must use the saved manifest, not query missing rows.
            Map<String,Object> replay=(Map<String,Object>)OrgLoomNativeUploadPlan.plan(body);System.assertEquals(1,((List<Object>)replay.get('groups')).size());
        }
    }
    @IsTest static void recoverySealsPlanBeforeMakingMissingBatchesRetryable() {
        User actor=[SELECT Id FROM User WHERE Alias='nawrite' LIMIT 1];System.runAs(actor) {
            Map<String,Object> body=request(new List<Object>{draft(1,'Account',new Map<String,Object>{'Name'=>'Do not send after recovery'})});
            Map<String,Object> plan=(Map<String,Object>)OrgLoomNativeUploadPlan.plan(body);Object payload=((List<Object>)plan.get('groups'))[0];
            Map<String,Object> receipt=(Map<String,Object>)OrgLoomNativeUpload.receipt((String)body.get('attemptId'));System.assertEquals('unconfirmed',receipt.get('status'));System.assertEquals(0,((List<Object>)receipt.get('retryableTempIds')).size());
            receipt=(Map<String,Object>)OrgLoomNativeUploadPlan.recover((String)body.get('attemptId'));System.assertEquals('completed',receipt.get('status'));System.assertEquals(1,((List<Object>)receipt.get('retryableTempIds')).size());
            Boolean rejected=false;try{OrgLoomNativeUploadPlan.execute(new Map<String,Object>{'rootAttemptId'=>body.get('attemptId'),'index'=>0,'payload'=>payload});}catch(OrgLoomNativeUpload.UploadException e){rejected=true;System.assert(e.getMessage().contains('closed'));}System.assert(rejected);
            System.assertEquals(0,[SELECT COUNT() FROM Account WHERE Name='Do not send after recovery']);
        }
    }
}
