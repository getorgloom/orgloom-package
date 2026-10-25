@IsTest private class OrgLoomNativeUpsertTest {
    @TestSetup static void setup() {
        User u=new User(ProfileId=UserInfo.getProfileId(),Username='native-upsert-'+System.now().getTime()+'@example.invalid',Email='upsert@example.invalid',Alias='naupsert',LastName='Native Upsert Test',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
        OrgLoomAccessFixture.grant(u,new Set<String>{'Access','upload-records'});
    }
    private static Map<String,Object> row(Integer temp,String email,String lastName) {
        return new Map<String,Object>{'tempId'=>temp,'objectName'=>'Contact','_csvOperation'=>'upsert','_csvExternalIdField'=>'Email','values'=>new Map<String,Object>{'Email'=>email,'LastName'=>lastName}};
    }
    private static Map<String,Object> body(List<Object> rows) {return new Map<String,Object>{'attemptId'=>EncodingUtil.convertToHex(Crypto.generateAesKey(128)),'expectedSfOrgId'=>UserInfo.getOrganizationId(),'records'=>rows};}
    private static Map<String,Object> execute(Map<String,Object> request,Map<String,Object> plan) {
        return (Map<String,Object>)OrgLoomNativeUploadPlan.execute(new Map<String,Object>{'rootAttemptId'=>request.get('attemptId'),'index'=>0,'payload'=>((List<Object>)plan.get('groups'))[0]});
    }
    @IsTest static void createsUpdatesAndReplaysWithEncryptedHistory() {
        User actor=[SELECT Id FROM User WHERE Alias='naupsert' LIMIT 1];System.runAs(actor) {
            Contact c=new Contact(LastName='Original match',Email='native-existing@example.invalid');insert c;
            Map<String,Object> request=body(new List<Object>{row(1,c.Email,'Changed match'),row(2,'native-new@example.invalid','New match')});
            Map<String,Object> plan=(Map<String,Object>)OrgLoomNativeUploadPlan.plan(request);
            Map<String,Object> response=execute(request,plan);List<Object> results=(List<Object>)response.get('results');
            System.assertEquals(2,results.size());for(Object raw:results)System.assertEquals(true,((Map<String,Object>)raw).get('success'),JSON.serialize(response));
            System.assertEquals('Changed match',[SELECT LastName FROM Contact WHERE Id=:c.Id].LastName);
            System.assertEquals(1,[SELECT COUNT() FROM Contact WHERE Email='native-new@example.invalid']);
            Map<String,Object> replay=(Map<String,Object>)OrgLoomNativeUploadPlan.plan(request);execute(request,replay);
            System.assertEquals(1,[SELECT COUNT() FROM Contact WHERE Email='native-new@example.invalid']);
            String manifest=[SELECT Results__c FROM OrgLoomNativeAttempt__c WHERE Key__c=:(UserInfo.getUserId()+':'+request.get('attemptId'))].Results__c;
            System.assert(!manifest.contains(c.Email));System.assert(!manifest.contains('Changed match'));
            System.assertEquals(1,[SELECT COUNT() FROM OrgLoomNativeAttempt__c WHERE RecallVersion__c!=null]);
        }
    }
    @IsTest static void changedMatchStopsTheWholeBatch() {
        User actor=[SELECT Id FROM User WHERE Alias='naupsert' LIMIT 1];System.runAs(actor) {
            Map<String,Object> request=body(new List<Object>{row(1,'native-race@example.invalid','Must not overwrite')});
            Map<String,Object> plan=(Map<String,Object>)OrgLoomNativeUploadPlan.plan(request);
            Contact c=new Contact(Email='native-race@example.invalid',LastName='Concurrent insert');insert c;
            Map<String,Object> response=execute(request,plan);
            System.assertEquals(false,((Map<String,Object>)((List<Object>)response.get('results'))[0]).get('success'));
            System.assertEquals('Concurrent insert',[SELECT LastName FROM Contact WHERE Id=:c.Id].LastName);
        }
    }
    @IsTest static void duplicateKeysAndNonKeyFieldsAreRejected() {
        User actor=[SELECT Id FROM User WHERE Alias='naupsert' LIMIT 1];System.runAs(actor) {
            Map<String,Object> request=body(new List<Object>{row(1,'same@example.invalid','One'),row(2,'SAME@example.invalid','Two')});
            try{OrgLoomNativeUploadPlan.plan(request);System.assert(false);}catch(OrgLoomNativeUpload.UploadException e){System.assert(e.getMessage().contains('more than once'));}
            Map<String,Object> invalid=row(1,'unused@example.invalid','No write');invalid.put('_csvExternalIdField','LastName');
            try{OrgLoomNativeUploadPlan.plan(body(new List<Object>{invalid}));System.assert(false);}catch(OrgLoomNativeUpload.UploadException e){System.assert(e.getMessage().contains('external ID'));}
            invalid=row(1,'','No write');try{OrgLoomNativeUploadPlan.plan(body(new List<Object>{invalid}));System.assert(false);}catch(OrgLoomNativeUpload.UploadException e){System.assert(e.getMessage().contains('nonempty'));}
            System.assertEquals(0,[SELECT COUNT() FROM Contact WHERE LastName='No write']);
        }
    }
    @IsTest static void resolvedParentsStayInSameAtomicGroup() {
        User actor=[SELECT Id FROM User WHERE Alias='naupsert' LIMIT 1];System.runAs(actor) {
            Account a=new Account(Name='Upsert parent');insert a;
            Contact c=new Contact(LastName='Existing child',Email='native-child@example.invalid',AccountId=a.Id);insert c;
            Map<String,Object> parent=new Map<String,Object>{'tempId'=>2,'objectName'=>'Account','loadedFromId'=>a.Id,'loadedValues'=>JSON.deserializeUntyped(JSON.serialize(OrgLoomNativeController.read('Account',new Set<Id>{a.Id},false)[0])),'values'=>new Map<String,Object>{'Name'=>'Parent changed'}};
            List<Object> rows=new List<Object>();for(Integer i=0;i<199;i++)rows.add(new Map<String,Object>{'tempId'=>i+10,'objectName'=>'Account','values'=>new Map<String,Object>{'Name'=>'Independent '+i}});rows.add(row(1,c.Email,'Child changed'));rows.add(parent);
            Map<String,Object> plan=(Map<String,Object>)OrgLoomNativeUploadPlan.plan(body(rows));
            System.assertEquals(2,((List<Object>)plan.get('groups')).size());
            for(Object batchKey:(List<Object>)plan.get('groups')){Set<String> temps=new Set<String>();for(Object raw:(List<Object>)((Map<String,Object>)batchKey).get('records'))temps.add(String.valueOf(((Map<String,Object>)raw).get('tempId')));System.assertEquals(temps.contains('1'),temps.contains('2'));}
        }
    }
    @IsTest static void overrideStillRejectsReadOnlyFields() {
        User actor=[SELECT Id FROM User WHERE Alias='naupsert' LIMIT 1];System.runAs(actor) {
            Map<String,Object> request=body(new List<Object>{new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','values'=>new Map<String,Object>{'Name'=>'Override validation','CreatedDate'=>'2000-01-01T00:00:00.000Z'}}});request.put('allowDuplicates',true);
            Map<String,Object> response=execute(request,(Map<String,Object>)OrgLoomNativeUploadPlan.plan(request));
            System.assertEquals(false,((Map<String,Object>)((List<Object>)response.get('results'))[0]).get('success'));
            System.assertEquals(0,[SELECT COUNT() FROM Account WHERE Name='Override validation']);
        }
    }
    @IsTest static void dmlErrorsRemainActionableAndReceiptsContainNoValues() {
        User actor=[SELECT Id FROM User WHERE Alias='naupsert' LIMIT 1];System.runAs(actor) {
            Map<String,Object> request=body(new List<Object>{new Map<String,Object>{'tempId'=>1,'objectName'=>'Contact','values'=>new Map<String,Object>{'FirstName'=>'Private error fixture'}}});
            request.put('allowDuplicates',true);
            Map<String,Object> response=execute(request,(Map<String,Object>)OrgLoomNativeUploadPlan.plan(request));
            Map<String,Object> failed=(Map<String,Object>)((List<Object>)response.get('results'))[0];
            System.assertEquals(false,failed.get('success'));System.assertEquals('REQUIRED_FIELD_MISSING',failed.get('errorCode'));
            System.assert(((List<Object>)failed.get('fields')).contains('LastName'));
            for(OrgLoomNativeAttempt__c receipt:[SELECT Results__c FROM OrgLoomNativeAttempt__c])System.assert(!receipt.Results__c.contains('Private error fixture'));
        }
    }
}

