@IsTest private class OrgLoomNativeAdminTest {
    private static User actor(String suffix) {
        return new User(ProfileId=[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' LIMIT 1].Id,
            Username='directory-'+suffix+'-'+System.now().getTime()+'@example.invalid',Email='directory@example.invalid',Alias='oldir',LastName='Directory '+suffix,
            TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');
    }
    private static Map<String,Object> invoke(String operation,Map<String,Object> body) {
        return (Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeAdmin.invoke(operation,JSON.serialize(body)));
    }
    private static Set<Id> search(String term) {
        Map<String,Object> response=invoke('users',new Map<String,Object>{'search'=>term});System.assertEquals(200,response.get('status'),JSON.serialize(response));
        Set<Id> ids=new Set<Id>();for(Object row:(List<Object>)response.get('data'))ids.add((Id)(String)((Map<String,Object>)row).get('Id'));return ids;
    }
    @IsTest static void searchIncludesCanvasAndAdminButNotUnassignedOrInactiveUsers() {
        User administrator=actor('admin'),canvas=actor('canvas'),unassigned=actor('unassigned'),inactive=actor('inactive');
        insert new List<User>{administrator,canvas,unassigned,inactive};
        OrgLoomAccessFixture.grant(administrator,new Set<String>{'Admin'});OrgLoomAccessFixture.grant(canvas,new Set<String>{'Access'});OrgLoomAccessFixture.grant(inactive,new Set<String>{'Access'});
        inactive.IsActive=false;update inactive;
        System.runAs(administrator){
            Set<Id> ids=search('Directory ');System.assert(ids.contains(administrator.Id));System.assert(ids.contains(canvas.Id));System.assert(!ids.contains(unassigned.Id));System.assert(!ids.contains(inactive.Id));
            System.assertEquals(new Set<Id>{canvas.Id},search(canvas.Username));
            System.assertEquals(400,invoke('features',new Map<String,Object>{'userId'=>unassigned.Id}).get('status'));
            System.assertEquals(400,invoke('grant',new Map<String,Object>{'userId'=>unassigned.Id,'capability'=>'browse-records','enabled'=>true}).get('status'));
            System.assertEquals(400,invoke('features',new Map<String,Object>{'userId'=>inactive.Id}).get('status'));
        }
        System.runAs(canvas){System.assertEquals(400,invoke('users',new Map<String,Object>{'search'=>'Directory'}).get('status'));}
    }
    @IsTest static void orgPoliciesCanBeManagedWithoutSelectingAUser() {
        User administrator=actor('policyadmin'),canvas=actor('policycanvas');insert new List<User>{administrator,canvas};
        OrgLoomAccessFixture.grant(administrator,new Set<String>{'Admin'});OrgLoomAccessFixture.grant(canvas,new Set<String>{'Access'});
        System.runAs(administrator){
            System.assertEquals(200,invoke('features',new Map<String,Object>()).get('status'));
            System.assertEquals(200,invoke('policy',new Map<String,Object>{'capability'=>'browse-records','enabled'=>false}).get('status'));
            Map<String,Object> response=invoke('features',new Map<String,Object>{'userId'=>''});
            System.assertEquals(200,response.get('status'));Boolean found=false;
            for(Object value:(List<Object>)response.get('data')){
                Map<String,Object> row=(Map<String,Object>)value;
                if(row.get('id')=='browse-records'){found=true;System.assertEquals(false,row.get('enabled'));System.assertEquals(false,row.get('assigned'));}
            }
            System.assert(found,'Org-wide features must be available without a selected user.');
            System.assertEquals(400,invoke('grant',new Map<String,Object>{'capability'=>'browse-records','enabled'=>true}).get('status'));
        }
        System.runAs(canvas){
            System.assertEquals(400,invoke('features',new Map<String,Object>()).get('status'));
            System.assertEquals(400,invoke('policy',new Map<String,Object>{'capability'=>'browse-records','enabled'=>true}).get('status'));
        }
    }
    @IsTest static void profileAndPermissionSetMatchesMergeWithoutReadOnlyCollectionErrors() {
        User assigned=actor('assignedmatch'),profileOnly=actor('profilematch');insert new List<User>{assigned,profileOnly};
        System.assertEquals(new Set<Id>{assigned.Id,profileOnly.Id},
            OrgLoomNativeAdmin.mergeUserIds(new List<User>{assigned},new List<User>{assigned,profileOnly}),
            'Profile grants must merge into a writable set and deduplicate permission-set matches.');
        System.assertEquals(new Set<Id>{profileOnly.Id},OrgLoomNativeAdmin.mergeUserIds(new List<User>(),new List<User>{profileOnly}));
        System.assertEquals(new Set<Id>{assigned.Id},OrgLoomNativeAdmin.mergeUserIds(new List<User>{assigned},new List<User>()));
    }
    @IsTest static void revokedAccessCannotBeManagedFromAStaleSelection() {
        User administrator=actor('revoker'),canvas=actor('revoked');insert new List<User>{administrator,canvas};
        OrgLoomAccessFixture.grant(administrator,new Set<String>{'Admin'});OrgLoomAccessFixture.grant(canvas,new Set<String>{'Access'});
        System.runAs(administrator){System.assert(search('Directory revoked').contains(canvas.Id));}
        String ns=OrgLoomNativeAccess.packageNamespace();
        delete [SELECT Id FROM PermissionSetAssignment WHERE AssigneeId=:canvas.Id AND PermissionSet.Name='OrgLoomNativePrototype' AND PermissionSet.NamespacePrefix=:ns];
        System.runAs(administrator){
            System.assertEquals(0,search('Directory revoked').size());
            System.assertEquals(400,invoke('features',new Map<String,Object>{'userId'=>canvas.Id}).get('status'));
            System.assertEquals(400,invoke('grant',new Map<String,Object>{'userId'=>canvas.Id,'capability'=>'browse-records','enabled'=>true}).get('status'));
        }
    }
    @IsTest static void accessFilteringHappensBeforeTheSearchLimit() {
        User administrator=actor('limitadmin'),canvas=actor('zzeligible');List<User> users=new List<User>{administrator,canvas};
        for(Integer i=0;i<51;i++)users.add(actor('aaunassigned'+i));insert users;
        OrgLoomAccessFixture.grant(administrator,new Set<String>{'Admin'});OrgLoomAccessFixture.grant(canvas,new Set<String>{'Access'});
        System.runAs(administrator){System.assert(search('Directory').contains(canvas.Id),'Eligible users must not be hidden behind the first 50 unassigned users.');}
    }
    @IsTest static void calculatedPermissionSetGroupGrantsAccess() {
        User administrator=actor('groupadmin'),groupUser=actor('groupuser');insert new List<User>{administrator,groupUser};
        OrgLoomAccessFixture.grant(administrator,new Set<String>{'Admin'});
        String ns=OrgLoomNativeAccess.packageNamespace();
        Id accessSet=[SELECT Id FROM PermissionSet WHERE Name='OrgLoomNativePrototype' AND NamespacePrefix=:ns LIMIT 1].Id;
        PermissionSetGroup accessGroup=new PermissionSetGroup(DeveloperName='OrgLoomDirectoryTest',MasterLabel='Org Loom Directory Test');insert accessGroup;
        insert new PermissionSetGroupComponent(PermissionSetGroupId=accessGroup.Id,PermissionSetId=accessSet);Test.calculatePermissionSetGroup(accessGroup.Id);
        insert new PermissionSetAssignment(AssigneeId=groupUser.Id,PermissionSetGroupId=accessGroup.Id);
        System.runAs(groupUser){System.assert(FeatureManagement.checkPermission('OrgLoomNative_Access'));}
        System.runAs(administrator){System.assert(search(groupUser.Username).contains(groupUser.Id));System.assertEquals(200,invoke('features',new Map<String,Object>{'userId'=>groupUser.Id}).get('status'));}
    }
}
