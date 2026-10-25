@IsTest private class OrgLoomNativeRecordLinkTest {
    private static User actor(Boolean browse,Boolean minimum) {
        Id profile=minimum?[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' LIMIT 1].Id:UserInfo.getProfileId();
        User u=new User(ProfileId=profile,Username='native-link-'+EncodingUtil.convertToHex(Crypto.generateAesKey(128))+'@example.invalid',Email='native-link@example.invalid',Alias='nalink',LastName='Native Record Link Test',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
        Set<String> names=new Set<String>{'Access'};if(browse)names.add('browse-records');
        OrgLoomAccessFixture.grant(u,names);return u;
    }
    private static Map<String,Object> loadLink(String id) {
        return (Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke('loadRecordLink',JSON.serialize(new Map<String,Object>{'recordId'=>id,'objectName'=>'Contact'})));
    }
    @IsTest static void savedRecordLoadsWithBrowseOnlyAndServerDerivedType() {
        User u=actor(true,false);System.runAs(u) {
            Account a=new Account(Name='Record link fixture',Phone='555-0100');insert a;
            Map<String,Object> response=loadLink(String.valueOf(a.Id).substring(0,15));System.assertEquals(200,response.get('status'),JSON.serialize(response));
            Map<String,Object> data=(Map<String,Object>)response.get('data');System.assertEquals('Account',data.get('objectName'));
            List<Object> records=(List<Object>)data.get('records');System.assertEquals(1,records.size());Map<String,Object> record=(Map<String,Object>)records[0];
            System.assertEquals(a.Id,(Id)(String)record.get('loadedFromId'));System.assertEquals('555-0100',((Map<String,Object>)record.get('values')).get('Phone'));
            System.assertEquals(1,[SELECT COUNT() FROM Account WHERE Name='Record link fixture']);
            System.assertEquals(400,loadLink('not-an-id').get('status'));
            System.assertEquals(400,loadLink(OrgLoomNativeCanvas__c.SObjectType.getDescribe().getKeyPrefix()+'000000000001').get('status'));
            delete a;System.assertEquals(400,loadLink(a.Id).get('status'));
        }
    }
    @IsTest static void browseGrantRequired() {
        // Installer profiles can inherit every packaged custom permission.
        // Use a profile without those grants and assert the specific feature gate.
        User u=actor(false,true);System.runAs(u) {
            Account a=new Account(Name='Not allowed');insert a;
            Map<String,Object> response=loadLink(a.Id);System.assertEquals(400,response.get('status'));
            System.assert(JSON.serialize(response).contains('Browse records'));
        }
    }
    @IsTest static void browseGrantDoesNotGrantBusinessObjectAccess() {
        User u=actor(true,true);
        System.runAs(u) {System.assertEquals(400,loadLink('001000000000001').get('status'));}
    }
}
