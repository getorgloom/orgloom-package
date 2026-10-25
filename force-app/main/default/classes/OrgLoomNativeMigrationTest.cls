@IsTest private class OrgLoomNativeMigrationTest {
    @IsTest static void matchingIsBoundedAndAmbiguityIsPreserved(){
        User u=new User(ProfileId=UserInfo.getProfileId(),Username='native-migrate-'+System.now().getTime()+'@example.invalid',Email='native-migrate@example.invalid',Alias='namigr',LastName='Native Migration Test',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
        OrgLoomAccessFixture.grant(u,new Set<String>{'Access','bulk-edit-records'});
        System.runAs(u){
            insert new List<Account>{new Account(Name='Migration match',NumberOfEmployees=10),new Account(Name='Migration match',NumberOfEmployees=10)};
            Map<String,Object> body=new Map<String,Object>{'objectName'=>'Account','keyField'=>'Name','values'=>new List<Object>{'Migration match'}};
            Map<String,Object> result=(Map<String,Object>)OrgLoomNativeMigration.matchRecords(body);
            System.assertEquals(2,((List<Object>)((Map<String,Object>)result.get('candidatesByValue')).get('Migration match')).size());
            body.put('keyField','NumberOfEmployees');body.put('values',new List<Object>{10});
            System.assertEquals(1,((Map<String,Object>)((Map<String,Object>)OrgLoomNativeMigration.matchRecords(body)).get('candidatesByValue')).size());
            body.put('keyField','Id');try{OrgLoomNativeMigration.matchRecords(body);System.assert(false);}catch(OrgLoomNativeMigration.MigrationException e){System.assert(e.getMessage().contains('Source record IDs'));}
            body.put('keyField','Name FROM User');try{OrgLoomNativeMigration.matchRecords(body);System.assert(false);}catch(OrgLoomNativeMigration.MigrationException e){System.assert(e.getMessage().contains('Unavailable'));}
            body.put('keyField','Name');body.put('values',new List<Object>());try{OrgLoomNativeMigration.matchRecords(body);System.assert(false);}catch(OrgLoomNativeMigration.MigrationException e){System.assert(e.getMessage().contains('100'));}
        }
    }
}
