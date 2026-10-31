@IsTest private class OrgLoomNativeRequestSaveTest {
    @TestSetup static void setup(){
        for(String alias:new List<String>{'reqown','reqedit','reqview','reqcontr','reqdeny'}){
            User u=new User(ProfileId=UserInfo.getProfileId(),Username=alias+'-'+System.now().getTime()+'@example.invalid',Email=alias+'@example.invalid',Alias=alias,LastName=alias,TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
            Set<String> caps=new Set<String>{'Access','save-canvas','open-saved-canvas','receive-canvas'};
            if(alias!='reqdeny')caps.add('create-slot-canvas');
            OrgLoomAccessFixture.grant(u,caps);
        }
        User limited=new User(ProfileId=[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' LIMIT 1].Id,Username='reqlimit-'+System.now().getTime()+'@example.invalid',Email='reqlimit@example.invalid',Alias='reqlimit',LastName='Limited requester',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert limited;
        PermissionSet accountAccess=new PermissionSet(Name='RequestSaveAccounts',Label='Request save accounts');insert accountAccess;
        insert new ObjectPermissions(ParentId=accountAccess.Id,SobjectType='Account',PermissionsRead=true,PermissionsCreate=true,PermissionsEdit=true);
        insert new PermissionSetAssignment(AssigneeId=limited.Id,PermissionSetId=accountAccess.Id);
        OrgLoomAccessFixture.grant(limited,new Set<String>{'Access','save-canvas','open-saved-canvas','receive-canvas','create-slot-canvas'});
    }
    static User actor(String alias){return [SELECT Id FROM User WHERE Alias=:alias LIMIT 1];}
    static Map<String,Object> slot(){return new Map<String,Object>{'slotId'=>1,'kind'=>'fields','fields'=>new List<Object>{'Name'},'label'=>'Complete name'};}
    static Map<String,Object> row(){return new Map<String,Object>{'tempId'=>'account-1','objectName'=>'Account','values'=>new Map<String,Object>{'Name'=>'Saved name'},'x'=>10,'y'=>20};}
    static Map<String,Object> create(Boolean withSlot){
        Map<String,Object> r=row();if(withSlot)r.put('slot',slot());
        Map<String,Object> p=new Map<String,Object>{'_meta'=>new Map<String,Object>{'savedFrom'=>UserInfo.getOrganizationId()},'schema'=>new Map<String,Object>{'objects'=>new List<Object>()},'loadedRecords'=>new List<Object>(),'drafts'=>new List<Object>{r,new Map<String,Object>{'tempId'=>'contact-1','objectName'=>'Contact','values'=>new Map<String,Object>{'LastName'=>'Unrelated'}}},'associations'=>new List<Object>{new Map<String,Object>{'from'=>new Map<String,Object>{'kind'=>'draft','ref'=>'contact-1'},'to'=>new Map<String,Object>{'kind'=>withSlot?'slot':'draft','ref'=>withSlot?(Object)1:(Object)'account-1'},'fieldName'=>'AccountId'}}};
        return (Map<String,Object>)OrgLoomNativeCanvases.handle('create',new Map<String,Object>{'name'=>'Request autosave','payload'=>p});
    }
    static Map<String,Object> save(Map<String,Object> c,Map<String,Object> r){return (Map<String,Object>)OrgLoomNativeCanvases.handle('request',new Map<String,Object>{'id'=>c.get('id'),'sessionToken'=>c.get('sessionToken'),'expectedVersionId'=>c.get('versionId'),'record'=>r});}
    static Map<String,Object> open(Map<String,Object> c){return (Map<String,Object>)((Map<String,Object>)OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>c.get('id'),'sessionToken'=>c.get('sessionToken')})).get('payload');}
    @IsTest static void metadataOnlyPreservesValuesLayoutAndRelationships(){System.runAs(actor('reqown')){
        Map<String,Object> c=create(false),r=row();r.put('slot',slot());r.put('values',new Map<String,Object>{'Name'=>'Must remain local'});r.put('pendingDelete',true);r.put('x',999);
        Test.startTest();save(c,r);Map<String,Object> p=open(c);Test.stopTest();
        Map<String,Object> stored=(Map<String,Object>)((List<Object>)p.get('drafts'))[0];
        System.assertEquals('Saved name',((Map<String,Object>)stored.get('values')).get('Name'));System.assertEquals(10,stored.get('x'));System.assertEquals(null,stored.get('pendingDelete'));System.assertEquals('fields',((Map<String,Object>)stored.get('slot')).get('kind'));
        System.assertEquals('Unrelated',((Map<String,Object>)((Map<String,Object>)((List<Object>)p.get('drafts'))[1]).get('values')).get('LastName'));
        System.assertEquals('slot',((Map<String,Object>)((Map<String,Object>)((List<Object>)p.get('associations'))[0]).get('to')).get('kind'));
    }}
    @IsTest static void removalPreservesRecordAndRewritesLinks(){System.runAs(actor('reqown')){
        Map<String,Object> c=create(true);Test.startTest();save(c,row());Map<String,Object> p=open(c);Test.stopTest();
        Map<String,Object> stored=(Map<String,Object>)((List<Object>)p.get('drafts'))[0];System.assertEquals(null,stored.get('slot'));System.assertEquals('Saved name',((Map<String,Object>)stored.get('values')).get('Name'));
        System.assertEquals('draft',((Map<String,Object>)((Map<String,Object>)((List<Object>)p.get('associations'))[0]).get('to')).get('kind'));
    }}
    @IsTest static void createsStandaloneRecordRequest(){System.runAs(actor('reqown')){
        Map<String,Object> c=create(false),r=new Map<String,Object>{'tempId'=>'new-request','objectName'=>'Contact','values'=>new Map<String,Object>(),'slot'=>new Map<String,Object>{'slotId'=>3,'kind'=>'whole-record','label'=>'Add contact'}};
        Test.startTest();save(c,r);Map<String,Object> p=open(c);Test.stopTest();System.assertEquals(3,((List<Object>)p.get('drafts')).size());
    }}
    @IsTest static void staleVersionCannotOverwriteRequest(){System.runAs(actor('reqown')){
        Map<String,Object> c=create(false),r=row();r.put('slot',slot());Test.startTest();save(c,r);
        try{save(c,row());System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('changed'));}Test.stopTest();
    }}
    @IsTest static void editorCanChangeRequestsButContributorAndViewerCannot(){
        User owner=actor('reqown');Map<String,Object> c;System.runAs(owner){c=create(false);}
        for(String alias:new List<String>{'reqedit','reqcontr','reqview'}){
            User u=actor(alias);String role=alias=='reqedit'?'editor':alias=='reqcontr'?'contributor':'viewer';
            insert new OrgLoomNativeGrant__c(Key__c=c.get('id')+':'+u.Id,Canvas__c=(Id)c.get('id'),Recipient__c=u.Id,Role__c=role);
        }
        Test.startTest();System.runAs(actor('reqedit')){
            Map<String,Object> editor=(Map<String,Object>)OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>c.get('id'),'takeover'=>true});Map<String,Object> r=row();r.put('slot',slot());save(editor,r);
        }
        System.runAs(actor('reqcontr')){
            Map<String,Object> contributor=(Map<String,Object>)OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>c.get('id'),'takeover'=>true});try{save(contributor,row());System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('owners and editors'));}
        }
        System.runAs(actor('reqview')){try{save(c,row());System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){}}
        Test.stopTest();
    }
    @IsTest static void requiresRequestCapabilityAndValidFields(){
        System.runAs(actor('reqdeny')){Map<String,Object> c=create(false),r=row();r.put('slot',slot());try{save(c,r);System.assert(false);}catch(Exception e){System.assert(!e.getMessage().contains('Assertion Failed'));}}
        System.runAs(actor('reqown')){Map<String,Object> c=create(false),r=row(),s=slot();s.put('fields',new List<Object>{'CreatedDate'});r.put('slot',s);try{save(c,r);System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('read-only'));}}
    }
    @IsTest static void restrictedEditorPreservesHiddenRecordsAndCannotTargetThem(){
        User owner=actor('reqown'),limited=actor('reqlimit');Map<String,Object> c;
        System.runAs(owner){c=create(false);}
        insert new OrgLoomNativeGrant__c(Key__c=c.get('id')+':'+limited.Id,Canvas__c=(Id)c.get('id'),Recipient__c=limited.Id,Role__c='editor');
        Test.startTest();System.runAs(limited){
            Map<String,Object> opened=(Map<String,Object>)OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>c.get('id'),'takeover'=>true});
            System.assertEquals(true,opened.get('partialView'));
            Map<String,Object> r=row();r.put('slot',slot());Map<String,Object> saved=save(opened,r);
            System.assert(!JSON.serialize(saved).contains('Unrelated'),'Hidden Contact data must not be returned');
            opened.put('versionId',saved.get('versionId'));
            try{save(opened,new Map<String,Object>{'tempId'=>'contact-1','objectName'=>'Contact','slot'=>new Map<String,Object>{'slotId'=>9,'kind'=>'whole-record'}});System.assert(false);}
            catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('unavailable'));}
        }
        System.runAs(owner){
            Map<String,Object> restored=(Map<String,Object>)OrgLoomNativeCanvases.handle('open',new Map<String,Object>{'id'=>c.get('id'),'takeover'=>true});
            System.assert(JSON.serialize(restored.get('payload')).contains('Unrelated'),'Request save must preserve hidden records');
            Map<String,Object> link=(Map<String,Object>)((List<Object>)((Map<String,Object>)restored.get('payload')).get('associations'))[0];
            System.assertEquals('slot',((Map<String,Object>)link.get('to')).get('kind'),'Hidden relationship must follow new request endpoint');
        }Test.stopTest();
    }
}
