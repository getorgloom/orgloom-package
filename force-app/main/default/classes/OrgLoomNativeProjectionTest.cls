@IsTest private class OrgLoomNativeProjectionTest {
    @TestSetup static void setup(){
        Profile minimum=[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' LIMIT 1];
        List<User> users=new List<User>();
        for(String alias:new List<String>{'napown','napedit'})users.add(new User(ProfileId=alias=='napown'?UserInfo.getProfileId():minimum.Id,Username=alias+System.now().getTime()+'@example.invalid',Email=alias+'@example.invalid',Alias=alias,LastName=alias,TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US'));insert users;
        PermissionSet ps=new PermissionSet(Name='NativeProjectionAccountEdit',Label='Projection fixture Account edit');insert ps;
        insert new ObjectPermissions(ParentId=ps.Id,SobjectType='Account',PermissionsRead=true,PermissionsCreate=true,PermissionsEdit=true);
        List<PermissionSetAssignment> grants=new List<PermissionSetAssignment>{new PermissionSetAssignment(AssigneeId=users[1].Id,PermissionSetId=ps.Id)};
        for(User u:users)OrgLoomAccessFixture.grant(u,new Set<String>{'Access','save-canvas','open-saved-canvas','receive-canvas','create-slot-canvas'});insert grants;
    }
    private static User actor(String alias){return [SELECT Id FROM User WHERE Alias=:alias LIMIT 1];}
    private static Map<String,Object> row(Map<String,Object> p,Integer i){return (Map<String,Object>)((List<Object>)p.get('drafts'))[i];}
    private static Map<String,Object> snapshot(){
        return new Map<String,Object>{'_meta'=>new Map<String,Object>{'savedFrom'=>UserInfo.getOrganizationId()},
            'schema'=>new Map<String,Object>{'objects'=>new List<Object>{new Map<String,Object>{'name'=>'Account','idx'=>0,'fields'=>new List<Object>{new Map<String,Object>{'name'=>'Name','defaultValue'=>'Visible default'},new Map<String,Object>{'name'=>'Phone','defaultValue'=>'Private default'}}},new Map<String,Object>{'name'=>'Contact','idx'=>1}}},
            'loadedRecords'=>new List<Object>(),'drafts'=>new List<Object>{
                new Map<String,Object>{'tempId'=>'account','objectName'=>'Account','values'=>new Map<String,Object>{'Name'=>'Visible draft','Phone'=>'Private phone'},'slot'=>new Map<String,Object>{'slotId'=>1,'kind'=>'fields','fields'=>new List<Object>{'Name','Phone'},'description'=>'Private instruction'}},
                new Map<String,Object>{'tempId'=>'contact','objectName'=>'Contact','values'=>new Map<String,Object>{'LastName'=>'Private contact'}}},
            'associations'=>new List<Object>{new Map<String,Object>{'from'=>new Map<String,Object>{'kind'=>'draft','ref'=>'contact'},'to'=>new Map<String,Object>{'kind'=>'draft','ref'=>'account'},'fieldName'=>'AccountId'}}};
    }
    private static Map<String,Object> run(String op,Map<String,Object> b){return (Map<String,Object>)OrgLoomNativeCanvases.handle(op,b);}
    private static Map<String,Object> create(User owner,User editor,String role){
        Map<String,Object> created;System.runAs(owner){created=run('create',new Map<String,Object>{'name'=>'Partial access fixture','payload'=>snapshot()});}
        Id id=(Id)(String)created.get('id');insert new OrgLoomNativeGrant__c(Key__c=id+':'+editor.Id,Canvas__c=id,Recipient__c=editor.Id,Role__c=role);return created;
    }
    @IsTest static void visibleEditsPreserveHiddenRecordsFieldsRequestsAndMetadata(){
        User owner=actor('napown'),editor=actor('napedit');Map<String,Object> created=create(owner,editor,'editor');
        Test.startTest();
        System.runAs(editor){
            System.assert(!Account.Phone.getDescribe().isAccessible());System.assert(!Contact.SObjectType.getDescribe().isAccessible());
            Map<String,Object> opened=run('open',new Map<String,Object>{'id'=>created.get('id'),'takeover'=>true}),data=(Map<String,Object>)opened.get('payload');
            System.assertEquals(true,opened.get('partialView'));System.assert(!JSON.serialize(data).contains('Private'));System.assertEquals(1,((List<Object>)data.get('drafts')).size());
            ((Map<String,Object>)row(data,0).get('values')).put('Name','Changed visible draft');
            // The shared client restores absent request notes as null.
            ((Map<String,Object>)row(data,0).get('slot')).put('description',null);
            run('save',new Map<String,Object>{'id'=>created.get('id'),'sessionToken'=>opened.get('sessionToken'),'expectedVersionId'=>opened.get('versionId'),'payload'=>data});
        }
        System.runAs(owner){
            Map<String,Object> opened=run('open',new Map<String,Object>{'id'=>created.get('id'),'takeover'=>true}),data=(Map<String,Object>)opened.get('payload');
            System.assertEquals('Changed visible draft',((Map<String,Object>)row(data,0).get('values')).get('Name'));
            System.assertEquals('Private phone',((Map<String,Object>)row(data,0).get('values')).get('Phone'));
            System.assertEquals(2,((List<Object>)data.get('drafts')).size());System.assertEquals(1,((List<Object>)data.get('associations')).size());
            System.assert(JSON.serialize(data).contains('Private default'));System.assert(JSON.serialize(data).contains('Private instruction'));
        }Test.stopTest();
    }
    @IsTest static void removalAndForgedFieldsCannotDestroyHiddenContent(){
        User editor=actor('napedit');Map<String,Object> full=snapshot();
        System.runAs(editor){
            OrgLoomNativeProjection.View view=OrgLoomNativeProjection.project(full);Map<String,Object> after=OrgLoomNativeProjection.copy(view.payload);
            ((Map<String,Object>)row(after,0).get('values')).put('Phone','Forged');
            try{OrgLoomNativeProjection.mergeVisible(full,view,after);System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('unavailable'));}
            after=OrgLoomNativeProjection.copy(view.payload);after.put('drafts',new List<Object>());after.put('schema',new Map<String,Object>{'objects'=>new List<Object>()});
            Map<String,Object> merged=OrgLoomNativeProjection.mergeVisible(full,view,after);
            System.assertEquals(2,((List<Object>)merged.get('drafts')).size());System.assertEquals(1,((List<Object>)merged.get('associations')).size());System.assert(JSON.serialize(merged).contains('Private default'));
            after=OrgLoomNativeProjection.copy(view.payload);((List<Object>)after.get('drafts')).add(new Map<String,Object>{'tempId'=>'contact','objectName'=>'Account','values'=>new Map<String,Object>{'Name'=>'Collision'}});
            try{OrgLoomNativeProjection.mergeVisible(full,view,after);System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('unavailable'));}
        }
    }
    @IsTest static void contributorFillsOnlyVisibleRequestFields(){
        User owner=actor('napown'),editor=actor('napedit');Map<String,Object> created=create(owner,editor,'contributor');
        Test.startTest();System.runAs(editor){
            Map<String,Object> opened=run('open',new Map<String,Object>{'id'=>created.get('id'),'takeover'=>true});
            Map<String,Object> request=new Map<String,Object>{'id'=>created.get('id'),'sessionToken'=>opened.get('sessionToken'),'expectedVersionId'=>opened.get('versionId'),'fills'=>new List<Object>{new Map<String,Object>{'slotId'=>1,'values'=>new Map<String,Object>{'Phone'=>'Forged'}}}};
            try{run('fill',request);System.assert(false);}catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('unavailable'));}
            request.put('fills',new List<Object>{new Map<String,Object>{'slotId'=>1,'values'=>new Map<String,Object>{'Name'=>'Requested visible change'}}});run('fill',request);
        }
        System.runAs(owner){Map<String,Object> opened=run('open',new Map<String,Object>{'id'=>created.get('id'),'takeover'=>true}),data=(Map<String,Object>)opened.get('payload');System.assertEquals('Requested visible change',((Map<String,Object>)row(data,0).get('values')).get('Name'));System.assertEquals('Private phone',((Map<String,Object>)row(data,0).get('values')).get('Phone'));System.assertEquals(2,((List<Object>)((Map<String,Object>)row(data,0).get('slot')).get('fields')).size());}Test.stopTest();
    }
    @IsTest static void invisibleLookupTargetsAreFilteredAndFrozen(){
        User owner=actor('napown'),editor=actor('napedit');Contact hidden;
        System.runAs(owner){hidden=new Contact(LastName='Private target');insert hidden;}
        // Contact references are not fields on Account; use an accessible object's
        // inaccessible lookup field to test both relationship and scalar removal.
        Map<String,Object> full=snapshot();((Map<String,Object>)row(full,0).get('values')).put('ParentId','001000000000001AAA');
        System.runAs(editor){OrgLoomNativeProjection.View view=OrgLoomNativeProjection.project(full);System.assert(!JSON.serialize(view.payload).contains('001000000000001'));System.assert(view.frozen.get('draft:account').contains('ParentId'));
            ((List<Object>)full.get('loadedRecords')).add(new Map<String,Object>{'loadedFromId'=>hidden.Id,'objectName'=>'Contact','changes'=>new Map<String,Object>{'LastName'=>'Private edit'}});
            view=OrgLoomNativeProjection.project(full);System.assertEquals(0,((List<Object>)view.payload.get('loadedRecords')).size());System.assert(!JSON.serialize(view.payload).contains(String.valueOf(hidden.Id)));
        }
    }
    @IsTest static void hiddenWholeRequestCannotBeReplacedWithAnExistingRecord(){
        User editor=actor('napedit');Map<String,Object> full=snapshot();
        row(full,0).put('slot',new Map<String,Object>{'slotId'=>1,'kind'=>'whole-record'});
        System.runAs(editor){OrgLoomNativeProjection.View view=OrgLoomNativeProjection.project(full);
            try{OrgLoomNativeProjection.validateFills(full,view,new List<Object>{new Map<String,Object>{'slotId'=>1,'values'=>new Map<String,Object>{'Id'=>'001000000000001AAA'}}});System.assert(false);}
            catch(OrgLoomNativeCanvases.CanvasException e){System.assert(e.getMessage().contains('hidden content'));}
            OrgLoomNativeProjection.validateFills(full,view,new List<Object>{new Map<String,Object>{'slotId'=>1,'values'=>new Map<String,Object>{'Name'=>'Visible completion'}}});
        }
    }
    @IsTest static void staleUnfilteredSubmissionCannotSaveAfterAccessChanges(){
        User owner=actor('napown'),editor=actor('napedit');Map<String,Object> created=create(owner,editor,'editor');
        Test.startTest();System.runAs(editor){
            Map<String,Object> opened=run('open',new Map<String,Object>{'id'=>created.get('id'),'takeover'=>true});
            try{run('save',new Map<String,Object>{'id'=>created.get('id'),'sessionToken'=>opened.get('sessionToken'),'expectedVersionId'=>opened.get('versionId'),'payload'=>snapshot()});System.assert(false);}
            catch(Exception e){System.assert(e.getMessage().contains('cannot access')||e.getMessage().contains('unavailable'));}
        }
        System.runAs(owner){Id id=(Id)(String)created.get('id');System.assertEquals(created.get('versionId'),[SELECT VersionId__c FROM OrgLoomNativeCanvas__c WHERE Id=:id].VersionId__c);}
        Test.stopTest();
    }
    @IsTest static void fullyVisibleRemovalStillWorks(){
        System.runAs(actor('napown')){
            Map<String,Object> full=snapshot();OrgLoomNativeProjection.View view=OrgLoomNativeProjection.project(full);System.assertEquals(false,view.partial);
            Map<String,Object> after=OrgLoomNativeProjection.copy(view.payload);after.put('drafts',new List<Object>());after.put('associations',new List<Object>());after.put('schema',new Map<String,Object>{'objects'=>new List<Object>()});
            Map<String,Object> merged=OrgLoomNativeProjection.mergeVisible(full,view,after);System.assertEquals(0,((List<Object>)merged.get('drafts')).size());System.assertEquals(0,((List<Object>)merged.get('associations')).size());
        }
    }
    @IsTest static void newRequestIdentifiersDoNotCollideWithHiddenRequests(){
        Map<String,Object> full=snapshot();row(full,1).put('slot',new Map<String,Object>{'slotId'=>8,'kind'=>'whole-record'});
        System.runAs(actor('napedit')){
            OrgLoomNativeProjection.View view=OrgLoomNativeProjection.project(full);
            System.assertEquals(9,((Map<String,Object>)view.payload.get('_meta')).get('nativeNextSlotId'));
            Map<String,Object> after=OrgLoomNativeProjection.copy(view.payload);
            ((List<Object>)after.get('drafts')).add(new Map<String,Object>{'tempId'=>'new-request','objectName'=>'Account','values'=>new Map<String,Object>(),'slot'=>new Map<String,Object>{'slotId'=>9,'kind'=>'whole-record'}});
            Map<String,Object> merged=OrgLoomNativeProjection.mergeVisible(full,view,after);System.assertEquals(3,((List<Object>)merged.get('drafts')).size());
            System.assertEquals(8,((Map<String,Object>)row(merged,2).get('slot')).get('slotId'));
        }
    }
}
