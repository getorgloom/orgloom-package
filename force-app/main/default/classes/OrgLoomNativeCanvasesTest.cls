@IsTest private class OrgLoomNativeCanvasesTest {
    @TestSetup static void setup() {
        User u=new User(ProfileId=UserInfo.getProfileId(),Username='native-store-'+System.now().getTime()+'@example.invalid',Email='native-store@example.invalid',Alias='nastore',LastName='Native Store Test',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
        OrgLoomAccessFixture.grant(u,new Set<String>{'Access','save-canvas','open-saved-canvas','upload-records'});
        List<User> recipients=new List<User>();
        for(String alias:new List<String>{'naedit','nacontr','naview'})recipients.add(new User(ProfileId=UserInfo.getProfileId(),Username=alias+'-'+System.now().getTime()+'@example.invalid',Email=alias+'@example.invalid',Alias=alias,LastName=alias,TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US'));
        insert recipients;
        for(User recipient:recipients)OrgLoomAccessFixture.grant(recipient,new Set<String>{'Access','save-canvas','open-saved-canvas','receive-canvas','upload-records'});
        Profile minimum=[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' LIMIT 1];
        User restricted=new User(ProfileId=minimum.Id,Username='naread-'+System.now().getTime()+'@example.invalid',Email='naread@example.invalid',Alias='naread',LastName='Restricted Reader',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert restricted;
        PermissionSet readAccounts=new PermissionSet(Name='NativeReadAccountsTest',Label='Native read Accounts test');insert readAccounts;
        insert new ObjectPermissions(ParentId=readAccounts.Id,SobjectType='Account',PermissionsRead=true);
        List<PermissionSetAssignment> grants=new List<PermissionSetAssignment>{new PermissionSetAssignment(AssigneeId=restricted.Id,PermissionSetId=readAccounts.Id)};
        OrgLoomAccessFixture.grant(restricted,new Set<String>{'Access','open-saved-canvas','receive-canvas'});insert grants;
    }
    private static Map<String,Object> snapshot(String name) {
        return new Map<String,Object>{'_meta'=>new Map<String,Object>{'app'=>'Org Loom','version'=>1,'savedFrom'=>UserInfo.getOrganizationId()},'schema'=>new Map<String,Object>{'objects'=>new List<Object>()},'loadedRecords'=>new List<Object>(),'drafts'=>new List<Object>{new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','values'=>new Map<String,Object>{'Name'=>name}}},'associations'=>new List<Object>()};
    }
    @IsTest static void deleteSavedCanvasRequiresOwnerAndValidLease() {
        User owner=[SELECT Id FROM User WHERE Alias='nastore' LIMIT 1],editor=[SELECT Id FROM User WHERE Alias='naedit' LIMIT 1];
        Map<String,Object> saved;Id fileId;Account account;
        System.runAs(owner){account=new Account(Name='Keep business record');insert account;saved=(Map<String,Object>)OrgLoomNativeCanvases.handle('create',new Map<String,Object>{'name'=>'Disposable saved canvas','payload'=>snapshot('Draft')});}
        Id id=(Id)(String)saved.get('id');fileId=(Id)[SELECT FileId__c FROM OrgLoomNativeCanvas__c WHERE Id=:id].FileId__c;
        insert new OrgLoomNativeGrant__c(Key__c=id+':'+editor.Id,Canvas__c=id,Recipient__c=editor.Id,Role__c='editor');
        System.runAs(editor){try{OrgLoomNativeCanvases.handle('delete',new Map<String,Object>{'id'=>id});System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('owner'));}}
        System.runAs(owner){
            try{OrgLoomNativeCanvases.handle('delete',new Map<String,Object>{'id'=>id});System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('session'));}
            OrgLoomNativeCanvases.handle('delete',new Map<String,Object>{'id'=>id,'sessionToken'=>saved.get('sessionToken')});
            System.assertEquals(0,[SELECT COUNT() FROM OrgLoomNativeCanvas__c WHERE Id=:id]);
            System.assertEquals(0,[SELECT COUNT() FROM OrgLoomNativeGrant__c WHERE Canvas__c=:id]);
            System.assertEquals(0,[SELECT COUNT() FROM ContentDocument WHERE Id=:fileId]);
            System.assertEquals(1,[SELECT COUNT() FROM Account WHERE Id=:account.Id]);
        }
    }
    @IsTest static void encryptedSaveOpenAndTakeover() {
        User actor=[SELECT Id FROM User WHERE Alias='nastore' LIMIT 1];System.runAs(actor) {
            Map<String,Object> created=(Map<String,Object>)OrgLoomNativeCanvases.handle('create',new Map<String,Object>{'name'=>'Native test canvas','payload'=>snapshot('Private draft')});
            Id id=(Id)(String)created.get('id');String token=(String)created.get('sessionToken');
            ContentVersion file=[SELECT VersionData FROM ContentVersion WHERE Id=:(String)created.get('versionId')];System.assert(!file.VersionData.toString().contains('Private draft'));
            Map<String,Object> opened=(Map<String,Object>)OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>id,'sessionToken'=>token});System.assert(JSON.serialize(opened.get('payload')).contains('Private draft'));
            try{OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>id});System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().startsWith('OCCUPIED_SELF: '));}
            Map<String,Object> takeover=(Map<String,Object>)OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>id,'takeover'=>true});String next=(String)takeover.get('sessionToken');System.assertNotEquals(token,next);
            try{OrgLoomNativeCanvases.handle('save',new Map<String,Object>{'id'=>id,'sessionToken'=>token,'expectedVersionId'=>created.get('versionId'),'payload'=>snapshot('Blocked')});System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('SESSION_ENDED'));}
            Map<String,Object> saved=(Map<String,Object>)OrgLoomNativeCanvases.handle('save',new Map<String,Object>{'id'=>id,'sessionToken'=>next,'expectedVersionId'=>created.get('versionId'),'payload'=>snapshot('Saved draft')});System.assertNotEquals(created.get('versionId'),saved.get('versionId'));
            OrgLoomNativeCanvases.handle('heartbeat',new Map<String,Object>{'id'=>id,'sessionToken'=>next});
            try{OrgLoomNativeCanvases.handle('save',new Map<String,Object>{'id'=>id,'sessionToken'=>next,'expectedVersionId'=>created.get('versionId'),'payload'=>snapshot('Stale')});System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('changed'));}
            Map<String,Object> listed=(Map<String,Object>)OrgLoomNativeCanvases.handle('list',new Map<String,Object>());System.assertEquals(1,((List<Object>)listed.get('items')).size());
            // Releasing a superseded tab must not unlock the new session.
            OrgLoomNativeCanvases.handle('release',new Map<String,Object>{'id'=>id,'sessionToken'=>token});
            OrgLoomNativeCanvases.requireSession(id,next,false);
            OrgLoomNativeCanvases.handle('release',new Map<String,Object>{'id'=>id,'sessionToken'=>next});
            Map<String,Object> reopened=(Map<String,Object>)OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>id});
            System.assertNotEquals(next,reopened.get('sessionToken'));
        }
    }
    @IsTest static void failedSaveDoesNotLeaveCanvasOrFile() {
        User actor=[SELECT Id FROM User WHERE Alias='nastore' LIMIT 1];System.runAs(actor) {
            Map<String,Object> data=snapshot('Never stored');((Map<String,Object>)data.get('_meta')).put('savedFrom','another-org');
            try{OrgLoomNativeCanvases.handle('create',new Map<String,Object>{'name'=>'Bad import','payload'=>data});System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('Reconcile'));}
            System.assertEquals(0,[SELECT COUNT() FROM OrgLoomNativeCanvas__c]);
        }
    }
    @IsTest static void takeoverPreservesRoleAndRevocation() {
        // Exercise the role/lease foundation without enabling the unfinished sharing UI.
        OrgLoomNativeAccess.IMPLEMENTED.add('receive-canvas');
        Map<String,User> users=new Map<String,User>();for(User u:[SELECT Id,Alias FROM User WHERE Alias IN ('nastore','naedit','nacontr','naview')])users.put(u.Alias,u);
        Map<String,Object> created;
        System.runAs(users.get('nastore')){created=(Map<String,Object>)OrgLoomNativeCanvases.handle('create',new Map<String,Object>{'name'=>'Role test','payload'=>snapshot('Draft')});}
        Id id=(Id)(String)created.get('id');
        insert new List<OrgLoomNativeGrant__c>{
            new OrgLoomNativeGrant__c(Key__c=id+':'+users.get('naedit').Id,Canvas__c=id,Recipient__c=users.get('naedit').Id,Role__c='editor'),
            new OrgLoomNativeGrant__c(Key__c=id+':'+users.get('nacontr').Id,Canvas__c=id,Recipient__c=users.get('nacontr').Id,Role__c='contributor'),
            new OrgLoomNativeGrant__c(Key__c=id+':'+users.get('naview').Id,Canvas__c=id,Recipient__c=users.get('naview').Id,Role__c='viewer')
        };
        String editorToken,contributorToken;
        System.runAs(users.get('naedit')){
            try{OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>id});System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().startsWith('OCCUPIED: '));}
            Map<String,Object> opened=(Map<String,Object>)OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>id,'takeover'=>true});editorToken=(String)opened.get('sessionToken');System.assertEquals('editor',opened.get('recipientRole'));
            OrgLoomNativeCanvases.requireLocalTools(id,editorToken);
            OrgLoomNativeCanvases.handle('save',new Map<String,Object>{'id'=>id,'sessionToken'=>editorToken,'expectedVersionId'=>created.get('versionId'),'payload'=>snapshot('Editor change')});
            try{OrgLoomNativeCanvases.requireSession(id,editorToken,true);System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('owner'));}
        }
        System.runAs(users.get('nacontr')){
            Map<String,Object> opened=(Map<String,Object>)OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>id,'takeover'=>true});contributorToken=(String)opened.get('sessionToken');System.assertEquals('contributor',opened.get('recipientRole'));
            try{OrgLoomNativeCanvases.requireLocalTools(id,contributorToken);System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('owners and editors'));}
            try{OrgLoomNativeCanvases.handle('save',new Map<String,Object>{'id'=>id,'sessionToken'=>contributorToken,'expectedVersionId'=>opened.get('versionId'),'payload'=>snapshot('Not allowed')});System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('Contributors'));}
        }
        System.runAs(users.get('naview')){
            Map<String,Object> opened=(Map<String,Object>)OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>id,'takeover'=>true});System.assertEquals(null,opened.get('sessionToken'));System.assertEquals('viewer',opened.get('recipientRole'));
            try{OrgLoomNativeCanvases.requireSession(id,contributorToken,false);System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){}
        }
        System.runAs(users.get('nacontr')){OrgLoomNativeCanvases.requireSession(id,contributorToken,false);}
        System.runAs(users.get('naedit')){try{OrgLoomNativeCanvases.requireSession(id,editorToken,false);System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('SESSION_ENDED'));}}
        delete [SELECT Id FROM OrgLoomNativeGrant__c WHERE Canvas__c=:id AND Role__c='contributor'];
        System.runAs(users.get('nacontr')){try{OrgLoomNativeCanvases.requireSession(id,contributorToken,false);System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('not shared'));}}
    }
    @IsTest static void sharedEncryptionDoesNotBypassFieldPermissions() {
        OrgLoomNativeAccess.IMPLEMENTED.add('receive-canvas');
        User owner=[SELECT Id FROM User WHERE Alias='nastore' LIMIT 1],reader=[SELECT Id FROM User WHERE Alias='naread' LIMIT 1];
        Map<String,Object> created;
        System.runAs(owner){
            Map<String,Object> data=snapshot('Restricted draft');
            Map<String,Object> draft=(Map<String,Object>)((List<Object>)data.get('drafts'))[0];
            ((Map<String,Object>)draft.get('values')).put('Phone','555-0100');
            created=(Map<String,Object>)OrgLoomNativeCanvases.handle('create',new Map<String,Object>{'name'=>'Field access test','payload'=>data});
        }
        Id id=(Id)(String)created.get('id');insert new OrgLoomNativeGrant__c(Key__c=id+':'+reader.Id,Canvas__c=id,Recipient__c=reader.Id,Role__c='viewer');
        System.runAs(reader){
            System.assert(Account.SObjectType.getDescribe().isAccessible());System.assert(!Account.Phone.getDescribe().isAccessible());
            Map<String,Object> opened=(Map<String,Object>)OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>id});
            System.assertEquals(true,opened.get('partialView'));System.assert(!JSON.serialize(opened.get('payload')).contains('555-0100'));System.assert(JSON.serialize(opened.get('payload')).contains('Restricted draft'));
        }
        // Permission checks also cover metadata defaults, not just record values.
        System.runAs(owner){
            Map<String,Object> data=snapshot('Metadata draft');
            data.put('schema',new Map<String,Object>{'objects'=>new List<Object>{new Map<String,Object>{'name'=>'Account','fields'=>new List<Object>{new Map<String,Object>{'name'=>'Phone','defaultValue'=>'555-0200'}}}}});
            OrgLoomNativeCanvases.handle('save',new Map<String,Object>{'id'=>id,'sessionToken'=>created.get('sessionToken'),'expectedVersionId'=>created.get('versionId'),'payload'=>data});
        }
        System.runAs(reader){Map<String,Object> opened=(Map<String,Object>)OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>id});System.assertEquals(true,opened.get('partialView'));System.assert(!JSON.serialize(opened.get('payload')).contains('555-0200'));}
    }
}
