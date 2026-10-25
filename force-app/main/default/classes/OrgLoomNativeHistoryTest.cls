@IsTest private class OrgLoomNativeHistoryTest {
    @TestSetup static void setup(){
        User u=new User(ProfileId=UserInfo.getProfileId(),Username='native-recall-'+System.now().getTime()+'@example.invalid',Email='native-recall@example.invalid',Alias='narecall',LastName='Native Recall Test',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
        OrgLoomAccessFixture.grant(u,new Set<String>{'Access','upload-records','view-activity-history','recall-upload'});
    }
    private static Map<String,Object> write(List<Object> rows){return (Map<String,Object>)OrgLoomNativeUpload.execute(new Map<String,Object>{'attemptId'=>EncodingUtil.convertToHex(Crypto.generateAesKey(128)),'expectedSfOrgId'=>UserInfo.getOrganizationId(),'records'=>rows,'deletes'=>new List<Object>()});}
    private static Map<String,Object> updateRow(Account a,String value){return new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','loadedFromId'=>a.Id,'loadedValues'=>JSON.deserializeUntyped(JSON.serialize(a)),'values'=>new Map<String,Object>{'Name'=>value}};}
    @IsTest static void encryptedHistoryAndFieldRecallAreAtomicAndIdempotent(){System.runAs((User)[SELECT Id FROM User WHERE Alias='narecall' LIMIT 1]){
        Account a=new Account(Name='Private prior name');insert a;a=[SELECT Id,Name,LastModifiedDate FROM Account WHERE Id=:a.Id];
        write(new List<Object>{updateRow(a,'Private uploaded name')});
        OrgLoomNativeAttempt__c journal=[SELECT Id,RecallVersion__c,Results__c FROM OrgLoomNativeAttempt__c LIMIT 1];
        System.assert(!journal.Results__c.contains('Private'),'Plaintext receipts contain no field values.');
        Blob encrypted=[SELECT VersionData FROM ContentVersion WHERE Id=:journal.RecallVersion__c].VersionData;System.assert(!encrypted.toString().contains('Private'));
        Map<String,Object> page=(Map<String,Object>)OrgLoomNativeHistory.listBatches(new Map<String,Object>());System.assertEquals(1,((List<Object>)page.get('batches')).size());
        Map<String,Object> review=(Map<String,Object>)OrgLoomNativeHistory.preflight(journal.Id);
        Map<String,Object> body=new Map<String,Object>{'nativeReviewToken'=>review.get('nativeReviewToken'),'revertSelections'=>new List<Object>{new Map<String,Object>{'sfId'=>a.Id,'fields'=>new List<Object>{'Name'}}}};
        Map<String,Object> result=(Map<String,Object>)OrgLoomNativeHistory.recall(journal.Id,body);System.assertEquals(1,result.get('revertedFieldCount'));System.assertEquals('recalled',result.get('status'));
        System.assertEquals('Private prior name',[SELECT Name FROM Account WHERE Id=:a.Id].Name);
        System.assertEquals('recalled',((Map<String,Object>)OrgLoomNativeHistory.recall(journal.Id,body)).get('status'));
        System.assertEquals(1,[SELECT COUNT() FROM OrgLoomNativeActivity__c WHERE Action__c='recall'],'Retry must not duplicate recall activity.');
        OrgLoomNativeHistory.forget(journal.Id);System.assertEquals(0,((List<Object>)((Map<String,Object>)OrgLoomNativeHistory.listBatches(new Map<String,Object>())).get('batches')).size());
    }}
    @IsTest static void overridesRequireFreshReviewAndCannotChooseUncapturedFields(){System.runAs((User)[SELECT Id FROM User WHERE Alias='narecall' LIMIT 1]){
        Account a=new Account(Name='Before');insert a;a=[SELECT Id,Name,LastModifiedDate FROM Account WHERE Id=:a.Id];write(new List<Object>{updateRow(a,'Uploaded')});
        Id id=[SELECT Id FROM OrgLoomNativeAttempt__c LIMIT 1].Id;Map<String,Object> stale=(Map<String,Object>)OrgLoomNativeHistory.preflight(id);
        update new Account(Id=a.Id,Name='Later edit');
        Map<String,Object> body=new Map<String,Object>{'nativeReviewToken'=>stale.get('nativeReviewToken'),'forceRevertSelections'=>new List<Object>{new Map<String,Object>{'sfId'=>a.Id,'fields'=>new List<Object>{new Map<String,Object>{'fieldName'=>'Name','expectedCurrent'=>'Later edit'}}}}};
        try{OrgLoomNativeHistory.recall(id,body);System.assert(false);}catch(OrgLoomNativeHistory.HistoryException e){System.assert(e.getMessage().contains('changed since'));}
        Map<String,Object> review=(Map<String,Object>)OrgLoomNativeHistory.preflight(id);body.put('nativeReviewToken',review.get('nativeReviewToken'));
        Map<String,Object> result=(Map<String,Object>)OrgLoomNativeHistory.recall(id,body);System.assertEquals(1,result.get('revertedFieldCount'));System.assertEquals('Before',[SELECT Name FROM Account WHERE Id=:a.Id].Name);
    }}
    @IsTest static void createdRecordsRecallAndRelatedRecordGuard(){System.runAs((User)[SELECT Id FROM User WHERE Alias='narecall' LIMIT 1]){
        Map<String,Object> response=write(new List<Object>{new Map<String,Object>{'tempId'=>1,'objectName'=>'Contact','values'=>new Map<String,Object>{'LastName'=>'Recall creation'}}});
        Id contactId=(Id)(String)((Map<String,Object>)((List<Object>)response.get('results'))[0]).get('id');Id id=[SELECT Id FROM OrgLoomNativeAttempt__c LIMIT 1].Id;
        Map<String,Object> review=(Map<String,Object>)OrgLoomNativeHistory.preflight(id);System.assertEquals(1,((List<Object>)review.get('clean')).size());
        Map<String,Object> result=(Map<String,Object>)OrgLoomNativeHistory.recall(id,new Map<String,Object>{'nativeReviewToken'=>review.get('nativeReviewToken')});
        System.assertEquals(1,((List<Object>)result.get('results')).size());System.assertEquals(0,[SELECT COUNT() FROM Contact WHERE Id=:contactId]);
    }}
    @IsTest static void laterChangesToCreationsRequireExplicitDeletion(){System.runAs((User)[SELECT Id FROM User WHERE Alias='narecall' LIMIT 1]){
        Map<String,Object> response=write(new List<Object>{new Map<String,Object>{'tempId'=>1,'objectName'=>'Contact','values'=>new Map<String,Object>{'LastName'=>'Original creation'}}});
        Id contactId=(Id)(String)((Map<String,Object>)((List<Object>)response.get('results'))[0]).get('id');Id id=[SELECT Id FROM OrgLoomNativeAttempt__c LIMIT 1].Id;
        update new Contact(Id=contactId,LastName='Later change');
        Map<String,Object> review=(Map<String,Object>)OrgLoomNativeHistory.preflight(id);System.assertEquals(1,((List<Object>)review.get('drifted')).size());
        try{OrgLoomNativeHistory.recall(id,new Map<String,Object>{'nativeReviewToken'=>review.get('nativeReviewToken')});System.assert(false);}catch(OrgLoomNativeHistory.HistoryException e){System.assert(e.getMessage().contains('explicitly select'));}
        OrgLoomNativeHistory.recall(id,new Map<String,Object>{'nativeReviewToken'=>review.get('nativeReviewToken'),'forceDeleteSfIds'=>new List<Object>{contactId}});
        System.assertEquals(0,[SELECT COUNT() FROM Contact WHERE Id=:contactId]);
    }}
    @IsTest static void childOutsideRecallIsNeverCascaded(){System.runAs((User)[SELECT Id FROM User WHERE Alias='narecall' LIMIT 1]){
        Map<String,Object> response=write(new List<Object>{new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','values'=>new Map<String,Object>{'Name'=>'Recall parent'}}});
        Id accountId=(Id)(String)((Map<String,Object>)((List<Object>)response.get('results'))[0]).get('id');Id id=[SELECT Id FROM OrgLoomNativeAttempt__c LIMIT 1].Id;
        Contact child=new Contact(LastName='Must survive',AccountId=accountId);insert child;
        Map<String,Object> review=(Map<String,Object>)OrgLoomNativeHistory.preflight(id);
        try{OrgLoomNativeHistory.recall(id,new Map<String,Object>{'nativeReviewToken'=>review.get('nativeReviewToken'),'forceDeleteSfIds'=>new List<Object>{accountId}});System.assert(false);}catch(OrgLoomNativeHistory.HistoryException e){System.assert(e.getMessage().contains('related')||e.getMessage().contains('verify'));}
        System.assertEquals(1,[SELECT COUNT() FROM Account WHERE Id=:accountId]);System.assertEquals(accountId,[SELECT AccountId FROM Contact WHERE Id=:child.Id].AccountId);
    }}
    @IsTest static void anotherUserCannotReadSnapshots(){
        Id id;System.runAs((User)[SELECT Id FROM User WHERE Alias='narecall' LIMIT 1]){write(new List<Object>{new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','values'=>new Map<String,Object>{'Name'=>'Private'}}});id=[SELECT Id FROM OrgLoomNativeAttempt__c LIMIT 1].Id;}
        try{OrgLoomNativeHistory.preflight(id);System.assert(false);}catch(Exception e){System.assert(e.getMessage().contains('grant')||e.getMessage().contains('unavailable'));}
    }
}
