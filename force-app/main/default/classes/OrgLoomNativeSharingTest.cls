@IsTest private class OrgLoomNativeSharingTest {
    @TestSetup static void setup(){
        List<User> users=new List<User>();for(String alias:new List<String>{'nashown','nashcon','nashedit'})users.add(new User(ProfileId=UserInfo.getProfileId(),Username=alias+System.now().getTime()+'@example.invalid',Email=alias+'@example.invalid',Alias=alias,LastName=alias,TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US'));insert users;

        for(User u:users)OrgLoomAccessFixture.grant(u,new Set<String>{'Access','save-canvas','open-saved-canvas','receive-canvas','share-canvas','create-slot-canvas'});
    }
    private static User actor(String alias){return [SELECT Id FROM User WHERE Alias=:alias LIMIT 1];}
    private static Map<String,Object> snapshot(){return new Map<String,Object>{'_meta'=>new Map<String,Object>{'savedFrom'=>UserInfo.getOrganizationId()},'loadedRecords'=>new List<Object>(),'drafts'=>new List<Object>{new Map<String,Object>{'tempId'=>'request-one','objectName'=>'Account','values'=>new Map<String,Object>(),'slot'=>new Map<String,Object>{'slotId'=>1,'kind'=>'whole-record'}}},'associations'=>new List<Object>()};}
    private static Map<String,Object> run(String operation,Map<String,Object> body){return (Map<String,Object>)OrgLoomNativeCanvases.handle(operation,body);}
    @IsTest static void sharingRequestsAndRevocation(){
        User owner=actor('nashown'),contributor=actor('nashcon');Map<String,Object> saved;
        System.runAs(owner){
            saved=run('create',new Map<String,Object>{'name'=>'Shared fixture','payload'=>snapshot()});
            run('grant',new Map<String,Object>{'id'=>saved.get('id'),'recipientSfUserId'=>contributor.Id,'role'=>'contributor'});
            System.assertEquals(1,((List<Object>)run('shares',new Map<String,Object>{'id'=>saved.get('id')}).get('directShares')).size());
        }
        String token;Object nextVersion;
        System.runAs(contributor){
            Map<String,Object> opened=run('open',new Map<String,Object>{'id'=>saved.get('id'),'takeover'=>true});token=(String)opened.get('sessionToken');
            Map<String,Object> submitted=run('fill',new Map<String,Object>{'id'=>saved.get('id'),'sessionToken'=>token,'expectedVersionId'=>opened.get('versionId'),
                'fills'=>new List<Object>{new Map<String,Object>{'slotId'=>1,'values'=>new Map<String,Object>{'Name'=>'Completed request'}}}});
            nextVersion=submitted.get('versionId');System.assertEquals(1,submitted.get('submitted'));System.assertNotEquals(saved.get('versionId'),nextVersion);
            try{run('grant',new Map<String,Object>{'id'=>saved.get('id'),'recipientSfUserId'=>actor('nashedit').Id,'role'=>'editor'});System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('owner'));}
            try{run('fill',new Map<String,Object>{'id'=>saved.get('id'),'sessionToken'=>token,'expectedVersionId'=>saved.get('versionId'),'fills'=>new List<Object>()});System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('changed'));}
        }
        System.runAs(owner){
            run('grant',new Map<String,Object>{'id'=>saved.get('id'),'recipientSfUserId'=>contributor.Id,'role'=>'none'});
            Map<String,Object> opened=run('open',new Map<String,Object>{'id'=>saved.get('id')});
            Map<String,Object> record=(Map<String,Object>)((List<Object>)((Map<String,Object>)opened.get('payload')).get('drafts'))[0];
            System.assertEquals('Completed request',((Map<String,Object>)record.get('values')).get('Name'));System.assertEquals(null,record.get('slot'));
            System.assertEquals(0,[SELECT COUNT() FROM Account WHERE Name='Completed request'],'Submitting does not write business records.');
        }
        System.runAs(contributor){try{OrgLoomNativeCanvases.requireSession((Id)(String)saved.get('id'),token,false);System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('not shared'));}}
    }
    @IsTest static void fieldRequestsRejectExtraFieldsAndWrongAssignee(){
        System.runAs(actor('nashcon')){
            Map<String,Object> data=snapshot();Map<String,Object> record=(Map<String,Object>)((List<Object>)data.get('drafts'))[0];
            record.put('slot',new Map<String,Object>{'slotId'=>1,'kind'=>'fields','fields'=>new List<Object>{'Phone'}});
            try{OrgLoomNativeRequests.apply(data,new List<Object>{new Map<String,Object>{'slotId'=>1,'values'=>new Map<String,Object>{'Name'=>'Not requested'}}});System.assert(false);}catch(OrgLoomNativeRequests.RequestException e){System.assert(e.getMessage().contains('requested'));}
            System.assertEquals(1,OrgLoomNativeRequests.apply(data,new List<Object>{new Map<String,Object>{'slotId'=>1,'values'=>new Map<String,Object>{'Phone'=>'555-0100'}}}));
            ((Map<String,Object>)record.get('slot')).put('assigneeSfUserId',actor('nashown').Id);
            try{OrgLoomNativeRequests.apply(data,new List<Object>{new Map<String,Object>{'slotId'=>1,'values'=>new Map<String,Object>{'Phone'=>'555-0101'}}});System.assert(false);}catch(OrgLoomNativeRequests.RequestException e){System.assert(e.getMessage().contains('another user'));}
        }
    }
    @IsTest static void editorCannotWriteReadOnlyFields(){
        System.runAs(actor('nashedit')){
            Map<String,Object> before=snapshot(),after=snapshot();
            Map<String,Object> record=(Map<String,Object>)((List<Object>)after.get('drafts'))[0];
            ((Map<String,Object>)record.get('values')).put('CreatedDate','2025-01-01T00:00:00.000Z');
            try{OrgLoomNativeSharedEdits.validate(before,after);System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('CreatedDate'));}
        }
    }
    @IsTest static void existingRequestChecksAccessAndReplacesRelationship(){
        System.runAs(actor('nashcon')){
            Account parent=new Account(Name='Request parent');insert parent;
            Contact child=new Contact(LastName='Request child');insert child;
            Map<String,Object> data=snapshot();data.put('drafts',new List<Object>());
            Map<String,Object> row=new Map<String,Object>{'objectName'=>'Contact','loadedFromId'=>child.Id,'slot'=>new Map<String,Object>{'slotId'=>2,'kind'=>'fields','fields'=>new List<Object>{'AccountId'}}};
            data.put('loadedRecords',new List<Object>{row});
            data.put('associations',new List<Object>{new Map<String,Object>{'from'=>new Map<String,Object>{'kind'=>'slot','ref'=>2},'to'=>new Map<String,Object>{'kind'=>'loaded','ref'=>parent.Id},'fieldName'=>'AccountId'}});
            OrgLoomNativeRequests.apply(data,new List<Object>{new Map<String,Object>{'slotId'=>2,'values'=>new Map<String,Object>{'AccountId'=>parent.Id},'relationshipFields'=>new List<Object>{'AccountId'}}});
            System.assertEquals(parent.Id,((Map<String,Object>)row.get('changes')).get('AccountId'));
            System.assertEquals(0,((List<Object>)data.get('associations')).size());
            System.assertEquals(null,[SELECT AccountId FROM Contact WHERE Id=:child.Id].AccountId,'Request submission must not upload.');
            OrgLoomNativeSharedEdits.validate(new Map<String,Object>{'loadedRecords'=>new List<Object>{new Map<String,Object>{'objectName'=>'Contact','loadedFromId'=>child.Id}},'drafts'=>new List<Object>()},data);
        }
    }
    @IsTest static void existingRecordRequestUsesIdentityAndDiscardsUntrustedValues(){
        System.runAs(actor('nashcon')){
            Account account=new Account(Name='Canonical record');insert account;
            Map<String,Object> data=snapshot();
            OrgLoomNativeRequests.apply(data,new List<Object>{new Map<String,Object>{'slotId'=>1,'values'=>new Map<String,Object>{'Id'=>account.Id,'Name'=>'Injected name','CreatedDate'=>'bad'}}});
            System.assertEquals(0,((List<Object>)data.get('drafts')).size());
            Map<String,Object> row=(Map<String,Object>)((List<Object>)data.get('loadedRecords'))[0];
            System.assertEquals(account.Id,row.get('loadedFromId'));System.assertEquals(null,row.get('values'));System.assertEquals(null,row.get('changes'));System.assertEquals(null,row.get('slot'));
            System.assertEquals('Canonical record',[SELECT Name FROM Account WHERE Id=:account.Id].Name);
        }
    }
    @IsTest static void wholeRequestMovesPlaceholderAndRemapsLinks(){
        System.runAs(actor('nashcon')){
            Map<String,Object> data=snapshot();Map<String,Object> row=(Map<String,Object>)((List<Object>)data.get('drafts'))[0];row.remove('tempId');
            data.put('drafts',new List<Object>());data.put('loadedRecords',new List<Object>{row});
            data.put('associations',new List<Object>{new Map<String,Object>{'from'=>new Map<String,Object>{'kind'=>'slot','ref'=>1},'to'=>new Map<String,Object>{'kind'=>'slot','ref'=>1},'fieldName'=>'ParentId'}});
            OrgLoomNativeRequests.apply(data,new List<Object>{new Map<String,Object>{'slotId'=>1,'values'=>new Map<String,Object>{'Name'=>'Draft request'}}});
            System.assertEquals(0,((List<Object>)data.get('loadedRecords')).size());
            System.assertEquals('request-1',row.get('tempId'));
            System.assertEquals('draft',((Map<String,Object>)((Map<String,Object>)((List<Object>)data.get('associations'))[0]).get('from')).get('kind'));
        }
    }
}
