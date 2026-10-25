@IsTest private class OrgLoomNativeBrowseTest {
    @IsTest static void filtersAndIdLoadsUseUserPermissions() {
        User u=new User(ProfileId=UserInfo.getProfileId(),Username='native-browse-'+System.now().getTime()+'@example.invalid',Email='native-browse@example.invalid',Alias='nabrowse',LastName='Native Browse Test',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
        OrgLoomAccessFixture.grant(u,new Set<String>{'Access','browse-records'});
        System.runAs(u) {
            Account a=new Account(Name='Native browse match',Phone='555-0100');insert a;insert new Account(Name='Other fixture');
            Map<String,Object> body=new Map<String,Object>{'objectName'=>'Account','search'=>'Native browse','limit'=>25,'filters'=>new List<Object>{new Map<String,Object>{'field'=>'Phone','op'=>'equals','value'=>'555-0100'}}};
            Map<String,Object> result=(Map<String,Object>)OrgLoomNativeBrowse.browse(body);System.assertEquals(1,result.get('count'));
            result=(Map<String,Object>)OrgLoomNativeBrowse.load(new Map<String,Object>{'soql'=>'SELECT Id FROM Account WHERE Id IN (\''+a.Id+'\')'});System.assertEquals(1,((List<Object>)result.get('records')).size());
            try{OrgLoomNativeBrowse.load(new Map<String,Object>{'soql'=>'SELECT Id FROM Account WHERE Name != null'});System.assert(false);}catch(OrgLoomNativeBrowse.BrowseException e){System.assert(e.getMessage().contains('Select individual'));}
            body.put('search','\' OR Name != null');result=(Map<String,Object>)OrgLoomNativeBrowse.browse(body);System.assertEquals(0,result.get('count'));
            body.put('filters',new List<Object>{new Map<String,Object>{'field'=>'Name FROM User','op'=>'equals','value'=>'bad'}});
            try{OrgLoomNativeBrowse.browse(body);System.assert(false);}catch(OrgLoomNativeBrowse.BrowseException e){System.assert(e.getMessage().contains('Unavailable'));}
        }
    }
}
