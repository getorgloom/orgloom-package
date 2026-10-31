@IsTest private class OrgLoomNativeHistoryTest {
    @TestSetup static void setup(){
        User u=new User(ProfileId=UserInfo.getProfileId(),Username='native-recall-'+System.now().getTime()+'@example.invalid',Email='native-recall@example.invalid',Alias='narecall',LastName='Native Recall Test',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
        OrgLoomAccessFixture.grant(u,new Set<String>{'Access','upload-records','view-activity-history','recall-upload'});
    }
    private static Map<String,Object> write(List<Object> rows){return (Map<String,Object>)OrgLoomNativeUpload.execute(new Map<String,Object>{'attemptId'=>EncodingUtil.convertToHex(Crypto.generateAesKey(128)),'expectedSfOrgId'=>UserInfo.getOrganizationId(),'records'=>rows,'deletes'=>new List<Object>()});}
    private static Map<String,Object> updateRow(Account a,String value){return new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','loadedFromId'=>a.Id,'loadedValues'=>JSON.deserializeUntyped(JSON.serialize(a)),'values'=>new Map<String,Object>{'Name'=>value}};}
    @IsTest static void datetimeComparisonUsesInstantsAndFailsClosed(){
        Schema.DescribeFieldResult field=Event.StartDateTime.getDescribe();
        Object instant=JSON.deserialize('"2026-11-01T00:00:00.123Z"',Datetime.class);
        for(String equivalent:new List<String>{'2026-11-01T00:00:00.123Z','2026-11-01T00:00:00.123+0000','2026-10-31T17:00:00.123-07:00','2026-11-01T05:30:00.123+05:30'}){
            System.assert(OrgLoomNativeHistory.sameFieldValue(instant,equivalent,field),equivalent);
            System.assert(OrgLoomNativeHistory.sameFieldValue(equivalent,instant,field),equivalent);
        }
        System.assert(!OrgLoomNativeHistory.sameFieldValue(instant,'2026-11-01T00:00:00.124Z',field),'Milliseconds must remain significant.');
        System.assert(!OrgLoomNativeHistory.sameFieldValue(instant,'2026-11-01T00:00:01.123Z',field));
        System.assert(!OrgLoomNativeHistory.sameFieldValue(instant,null,field));
        System.assert(!OrgLoomNativeHistory.sameFieldValue(null,instant,field));
        System.assert(OrgLoomNativeHistory.sameFieldValue(null,null,field));
        System.assert(!OrgLoomNativeHistory.sameFieldValue(instant,'invalid timestamp',field));
        System.assert(!OrgLoomNativeHistory.sameFieldValue('invalid timestamp','invalid timestamp',field));
        System.assert(!OrgLoomNativeHistory.sameFieldValue('2026-11-01T00:00:00.123Z','2026-11-01T00:00:00.123+0000',Account.Description.getDescribe()),'Text fields must retain exact comparisons.');
    }
    private static Event eventRecord(){
        Event e=new Event(Subject='Before',StartDateTime=Datetime.newInstanceGmt(2026,11,1,0,0,0),EndDateTime=Datetime.newInstanceGmt(2026,11,1,4,0,0));insert e;
        return [SELECT Id,Subject,StartDateTime,EndDateTime,LastModifiedDate FROM Event WHERE Id=:e.Id];
    }
    private static Map<String,Object> eventRow(Event e,Map<String,Object> values){
        return new Map<String,Object>{'tempId'=>1,'objectName'=>'Event','loadedFromId'=>e.Id,'loadedValues'=>JSON.deserializeUntyped(JSON.serialize(e)),'values'=>values};
    }
    private static Map<String,Object> eventReview(Map<String,Object> review){
        return (Map<String,Object>)((List<Object>)((Map<String,Object>)review.get('valueDrift')).get('records'))[0];
    }
    @IsTest static void unchangedDatetimeIsNotCapturedForRecall(){System.runAs((User)[SELECT Id FROM User WHERE Alias='narecall' LIMIT 1]){
        Event e=eventRecord();write(new List<Object>{eventRow(e,new Map<String,Object>{'Subject'=>'Uploaded','StartDateTime'=>'2026-10-31T17:00:00.000-07:00'})});
        Id id=[SELECT Id FROM OrgLoomNativeAttempt__c WHERE RecallVersion__c!=null LIMIT 1].Id;
        Map<String,Object> fields=eventReview((Map<String,Object>)OrgLoomNativeHistory.preflight(id));
        System.assertEquals(0,((List<Object>)fields.get('drifted')).size());
        List<Object> clean=(List<Object>)fields.get('clean');System.assertEquals(1,clean.size(),'Only Subject changed; the identical datetime must not enter history.');
        System.assertEquals('Subject',((Map<String,Object>)clean[0]).get('fieldName'));
    }}
    @IsTest static void changedDatetimeIsCleanAndCanBeRecalled(){System.runAs((User)[SELECT Id FROM User WHERE Alias='narecall' LIMIT 1]){
        Event e=eventRecord();write(new List<Object>{eventRow(e,new Map<String,Object>{'StartDateTime'=>'2026-10-31T18:00:00.000-07:00'})});
        Id id=[SELECT Id FROM OrgLoomNativeAttempt__c WHERE RecallVersion__c!=null LIMIT 1].Id;
        Map<String,Object> review=(Map<String,Object>)OrgLoomNativeHistory.preflight(id),fields=eventReview(review);
        System.assertEquals(0,((List<Object>)fields.get('drifted')).size(),'Serialized timezone formatting is not drift.');
        System.assertEquals(1,((List<Object>)fields.get('clean')).size());
        Map<String,Object> result=(Map<String,Object>)OrgLoomNativeHistory.recall(id,new Map<String,Object>{'nativeReviewToken'=>review.get('nativeReviewToken'),'revertSelections'=>new List<Object>{new Map<String,Object>{'sfId'=>e.Id,'fields'=>new List<Object>{'StartDateTime'}}}});
        System.assertEquals(1,result.get('revertedFieldCount'));
        System.assertEquals(e.StartDateTime,[SELECT StartDateTime FROM Event WHERE Id=:e.Id].StartDateTime);
    }}
    @IsTest static void laterDatetimeEditStillRequiresExplicitFreshReview(){System.runAs((User)[SELECT Id FROM User WHERE Alias='narecall' LIMIT 1]){
        Event e=eventRecord();write(new List<Object>{eventRow(e,new Map<String,Object>{'StartDateTime'=>'2026-11-01T01:00:00.000Z'})});
        Id id=[SELECT Id FROM OrgLoomNativeAttempt__c WHERE RecallVersion__c!=null LIMIT 1].Id;
        Map<String,Object> review=(Map<String,Object>)OrgLoomNativeHistory.preflight(id);
        Datetime later=Datetime.newInstanceGmt(2026,11,1,2,0,0);update new Event(Id=e.Id,StartDateTime=later);
        Map<String,Object> body=new Map<String,Object>{'nativeReviewToken'=>review.get('nativeReviewToken'),'revertSelections'=>new List<Object>{new Map<String,Object>{'sfId'=>e.Id,'fields'=>new List<Object>{'StartDateTime'}}}};
        try{OrgLoomNativeHistory.recall(id,body);System.assert(false,'Stale review must fail.');}catch(OrgLoomNativeHistory.HistoryException ex){System.assertEquals('This Recall review is no longer current. No Salesforce records were changed. Open Upload History, select this upload, and start Recall again to review the latest values.',ex.getMessage());}
        review=(Map<String,Object>)OrgLoomNativeHistory.preflight(id);
        System.assertEquals(1,((List<Object>)eventReview(review).get('drifted')).size());
        body.put('nativeReviewToken',review.get('nativeReviewToken'));
        try{OrgLoomNativeHistory.recall(id,body);System.assert(false,'Unforced recall must not overwrite later edits.');}catch(OrgLoomNativeHistory.HistoryException ex){System.assert(ex.getMessage().contains('changed since'));}
        System.assertEquals(later,[SELECT StartDateTime FROM Event WHERE Id=:e.Id].StartDateTime);
        body.remove('revertSelections');
        Map<String,Object> forcedField=new Map<String,Object>{'fieldName'=>'StartDateTime','expectedCurrent'=>'2026-11-01T02:00:00.001Z'};
        body.put('forceRevertSelections',new List<Object>{new Map<String,Object>{'sfId'=>e.Id,'fields'=>new List<Object>{forcedField}}});
        try{OrgLoomNativeHistory.recall(id,body);System.assert(false,'A forced selection must match the exact reviewed millisecond.');}catch(OrgLoomNativeHistory.HistoryException ex){System.assert(ex.getMessage().contains('changed since'));}
        forcedField.put('expectedCurrent','2026-10-31T19:00:00.000-07:00');
        Map<String,Object> result=(Map<String,Object>)OrgLoomNativeHistory.recall(id,body);
        System.assertEquals(1,result.get('forcedRevertedFieldCount'));
        System.assertEquals(e.StartDateTime,[SELECT StartDateTime FROM Event WHERE Id=:e.Id].StartDateTime);
    }}
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
        try{OrgLoomNativeHistory.recall(id,body);System.assert(false);}catch(OrgLoomNativeHistory.HistoryException e){System.assertEquals('This Recall review is no longer current. No Salesforce records were changed. Open Upload History, select this upload, and start Recall again to review the latest values.',e.getMessage());}
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
