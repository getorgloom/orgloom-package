@IsTest private class OrgLoomNativeEncryptedTest {
    // Exercise every storage/write boundary without installing a customer field.
    // A live-org smoke test separately uses a real ENCRYPTEDSTRING field.
    private static void encrypted(){OrgLoomNativeEncrypted.testFields=new Map<String,Set<String>>{'Account'=>new Set<String>{'description'}};}
    @TestSetup static void setup(){
        User u=new User(ProfileId=UserInfo.getProfileId(),Username='native-encrypted-'+System.now().getTime()+'@example.invalid',Email='encrypted@example.invalid',Alias='naenc',LastName='Encrypted Test',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
        OrgLoomAccessFixture.grant(u,new Set<String>{'Access','upload-records','save-canvas','open-saved-canvas','view-activity-history','recall-upload','create-slot-canvas'});
    }
    private static String token(){return EncodingUtil.convertToHex(Crypto.generateAesKey(256));}
    private static Map<String,Object> payload(){
        Map<String,Object> row=new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','encryptedFieldIntents'=>new List<Object>{'Description'},'_encryptedFieldProposals'=>new Map<String,Object>{'Description'=>'SECRET_PROPOSAL'}};
        for(String key:new List<String>{'values','changes','loadedValues','originalValues'})row.put(key,new Map<String,Object>{'Name'=>'Ordinary','Description'=>'SECRET_'+key});
        row.put('slot',new Map<String,Object>{'slotId'=>1,'kind'=>'fields','fields'=>new List<Object>{'Name','Description'}});
        Map<String,Object> obj=new Map<String,Object>{'name'=>'Account','fields'=>new List<Object>{new Map<String,Object>{'name'=>'Description','type'=>'encryptedstring','defaultValue'=>'SECRET_DEFAULT'}}};
        return new Map<String,Object>{'_meta'=>new Map<String,Object>{'savedFrom'=>UserInfo.getOrganizationId()},'schema'=>new Map<String,Object>{'objects'=>new List<Object>{obj}},'loadedRecords'=>new List<Object>(),'drafts'=>new List<Object>{row},'associations'=>new List<Object>()};
    }
    private static void noSecrets(Object value){System.assert(!JSON.serialize(value).contains('SECRET_'),'No encrypted values may enter durable or shared content');}
    @IsTest static void stripsOnlyEncryptedValuesAndPreservesMetadata(){
        encrypted();Map<String,Object> source=payload(),safe=OrgLoomNativeEncrypted.canvas(source);noSecrets(safe);
        System.assert(JSON.serialize(source).contains('SECRET_'),'Must not modify tab-local values');
        Map<String,Object> row=(Map<String,Object>)((List<Object>)safe.get('drafts'))[0];
        System.assertEquals('Ordinary',((Map<String,Object>)row.get('values')).get('Name'));
        System.assertEquals(new List<Object>{'Description'},row.get('encryptedFieldIntents'));
        System.assertEquals(new List<Object>{'Name'},((Map<String,Object>)row.get('slot')).get('fields'));
        System.assert(JSON.serialize(safe).contains('encryptedstring'),'Keep the field metadata for its UI');
        System.assert(OrgLoomNativeEncrypted.isField('Account','DESCRIPTION'));
    }
    @IsTest static void savedCanvasAndRecoveryNeverStoreSecrets(){System.runAs((User)[SELECT Id FROM User WHERE Alias='naenc']){
        encrypted();Map<String,Object> input=payload();
        Map<String,Object> saved=(Map<String,Object>)OrgLoomNativeCanvases.handle('create',new Map<String,Object>{'name'=>'Encrypted policy','payload'=>input});
        OrgLoomNativeCanvas__c canvas=[SELECT Id,VersionId__c,Revision__c FROM OrgLoomNativeCanvas__c WHERE Id=:(Id)saved.get('id')];
        String stored=OrgLoomNativeCrypto.open([SELECT VersionData FROM ContentVersion WHERE Id=:canvas.VersionId__c].VersionData,UserInfo.getOrganizationId()+':'+canvas.Id+':'+canvas.Revision__c);
        noSecrets(stored);noSecrets(OrgLoomNativeProjection.project(input).payload);
        String key=token(),writer=token();Map<String,Object> request=new Map<String,Object>{'key'=>key,'writer'=>writer,'sequence'=>1,'payload'=>input};
        OrgLoomNativeRecovery.handle('write',request);
        OrgLoomNativeRecovery__c recovery=[SELECT OwnerId,Key__c,Sequence__c,VersionId__c FROM OrgLoomNativeRecovery__c WHERE Key__c=:key];
        stored=OrgLoomNativeCrypto.open([SELECT VersionData FROM ContentVersion WHERE Id=:recovery.VersionId__c].VersionData,UserInfo.getOrganizationId()+':recovery:'+recovery.OwnerId+':'+key+':'+recovery.Sequence__c);
        noSecrets(stored);noSecrets(OrgLoomNativeRecovery.handle('restore',request));
    }}
    private static Map<String,Object> write(Map<String,Object> row){return (Map<String,Object>)OrgLoomNativeUpload.execute(new Map<String,Object>{'attemptId'=>token(),'expectedSfOrgId'=>UserInfo.getOrganizationId(),'records'=>new List<Object>{row},'deletes'=>new List<Object>()});}
    private static Map<String,Object> updateRow(Id id,Map<String,Object> values){return new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','loadedFromId'=>id,'loadedValues'=>JSON.deserializeUntyped(JSON.serialize(OrgLoomNativeController.read('Account',new Set<Id>{id},false)[0])),'values'=>values};}
    private static void checkHistory(){
        for(OrgLoomNativeAttempt__c receipt:[SELECT Id,Results__c,RecallVersion__c FROM OrgLoomNativeAttempt__c WHERE RecallVersion__c!=null]){
            noSecrets(receipt.Results__c);
            String stored=OrgLoomNativeCrypto.open([SELECT VersionData FROM ContentVersion WHERE Id=:receipt.RecallVersion__c].VersionData,UserInfo.getOrganizationId()+':upload-recall:'+receipt.Id);
            noSecrets(stored);System.assert(!stored.contains('Description'),'Encrypted fields cannot be recalled');
        }
    }
    @IsTest static void explicitReplaceClearAndUnchanged(){System.runAs((User)[SELECT Id FROM User WHERE Alias='naenc']){
        encrypted();Account a=new Account(Name='Before',Description='SECRET_ORIGINAL');insert a;
        Map<String,Object> row=updateRow(a.Id,new Map<String,Object>{'Name'=>'After'});write(row);
        System.assertEquals('SECRET_ORIGINAL',[SELECT Description FROM Account WHERE Id=:a.Id].Description);
        row=updateRow(a.Id,new Map<String,Object>{'Description'=>'SECRET_REPLACEMENT'});
        try{write(row);System.assert(false,'Implicit encrypted writes must be rejected');}catch(OrgLoomNativeUpload.UploadException e){System.assert(e.getMessage().contains('Replace or Clear'));}
        row.put('explicitFields',new List<Object>{'Description'});write(row);
        System.assertEquals('SECRET_REPLACEMENT',[SELECT Description FROM Account WHERE Id=:a.Id].Description);
        row=updateRow(a.Id,new Map<String,Object>{'Description'=>null});row.put('explicitFields',new List<Object>{'Description'});write(row);
        System.assertEquals(null,[SELECT Description FROM Account WHERE Id=:a.Id].Description);checkHistory();
    }}
    @IsTest static void encryptedCreateHistoryRemainsRecallable(){System.runAs((User)[SELECT Id FROM User WHERE Alias='naenc']){
        encrypted();write(new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','values'=>new Map<String,Object>{'Name'=>'Created','Description'=>'SECRET_CREATED'},'explicitFields'=>new List<Object>{'Description'}});checkHistory();
        Id receipt=[SELECT Id FROM OrgLoomNativeAttempt__c WHERE RecallVersion__c!=null LIMIT 1].Id;
        Map<String,Object> review=(Map<String,Object>)OrgLoomNativeHistory.preflight(receipt);
        System.assertEquals(1,((List<Object>)review.get('clean')).size(),'Excluding encrypted values must not create false drift');
        System.assertEquals(0,((List<Object>)review.get('drifted')).size());noSecrets(review);
    }}
    @IsTest static void contributorCannotSubmitEncryptedValues(){
        encrypted();Map<String,Object> input=payload(),row=(Map<String,Object>)((List<Object>)input.get('drafts'))[0];
        row.put('slot',new Map<String,Object>{'slotId'=>1,'kind'=>'record'});
        try{OrgLoomNativeRequests.apply(input,new List<Object>{new Map<String,Object>{'slotId'=>1,'values'=>new Map<String,Object>{'Description'=>'SECRET_REQUEST'}}});System.assert(false);}
        catch(OrgLoomNativeRequests.RequestException e){System.assert(e.getMessage().contains('Encrypted fields'));}
    }
}
