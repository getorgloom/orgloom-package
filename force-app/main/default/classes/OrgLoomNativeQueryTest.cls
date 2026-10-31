@IsTest private class OrgLoomNativeQueryTest {
    @TestSetup static void setup() {
        User actor=new User(ProfileId=UserInfo.getProfileId(),Username='native-query-'+System.now().getTime()+'@example.invalid',Email='native-query@example.invalid',Alias='naquery',LastName='Native Query Test',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert actor;

        OrgLoomAccessFixture.grant(actor,new Set<String>{'Access','soql-import','bulk-edit-records','export-canvas'});
    }
    private static Map<String,Object> query(String soql) { return (Map<String,Object>)OrgLoomNativeQuery.run(new Map<String,Object>{'soql'=>soql}); }
    @IsTest static void hydratesChildRecordsAndRelationships() {
        User actor=[SELECT Id FROM User WHERE Alias='naquery' LIMIT 1];System.runAs(actor){
            Account a=new Account(Name='Native query family',Phone='555-0100');insert a;
            insert new List<Contact>{new Contact(AccountId=a.Id,LastName='First'),new Contact(AccountId=a.Id,LastName='Second')};
            Map<String,Object> result=query('SELECT Id, Name, (SELECT Id, LastName FROM Contacts ORDER BY LastName LIMIT 1) FROM Account WHERE Id = \''+a.Id+'\' LIMIT 1');
            List<Object> rows=(List<Object>)result.get('records');System.assertEquals(2,rows.size());
            System.assertEquals(1,((List<Object>)result.get('associations')).size());
            System.assertEquals('555-0100',((SObject)((Map<String,Object>)rows[0]).get('values')).get('Phone'));
            System.assertEquals('Contact',((Map<String,Object>)rows[1]).get('objectName'));
        }
    }
    @IsTest static void capsAtFiveHundredAndSupportsOffset() {
        User actor=[SELECT Id FROM User WHERE Alias='naquery' LIMIT 1];System.runAs(actor){
            List<Account> fixtures=new List<Account>();for(Integer i=0;i<505;i++)fixtures.add(new Account(Name='Native cap '+i));insert fixtures;
            Test.startTest();Map<String,Object> result=query('SELECT Id FROM Account WHERE Name LIKE \'Native cap %\' ORDER BY Id LIMIT 900');
            System.assertEquals(500,((List<Object>)result.get('records')).size());System.assertEquals(true,result.get('capped'));
            result=query('SELECT Id FROM Account WHERE Name LIKE \'Native cap %\' ORDER BY Id LIMIT 2 OFFSET 1');Test.stopTest();
            System.assertEquals(2,((List<Object>)result.get('records')).size());System.assertEquals(false,result.get('capped'));
        }
    }
    @IsTest static void keywordsInsideStringsAreNotCommands() {
        User actor=[SELECT Id FROM User WHERE Alias='naquery' LIMIT 1];System.runAs(actor){
            Account a=new Account(Name='FOR UPDATE / GROUP BY; ALL ROWS');insert a;
            Map<String,Object> result=query('SELECT Id FROM Account WHERE Name = \'FOR UPDATE / GROUP BY; ALL ROWS\'');
            System.assertEquals(1,((List<Object>)result.get('records')).size());
            result=query('SELECT Id FROM Account WHERE Name = \'Doesn\\\'t exist\'');System.assertEquals(0,((List<Object>)result.get('records')).size());
        }
    }
    @IsTest static void rejectsUnsafeAndInvalidQueries() {
        User actor=[SELECT Id FROM User WHERE Alias='naquery' LIMIT 1];System.runAs(actor){
            for(String soql:new List<String>{'SELECT Id FROM Account FOR UPDATE','SELECT Id FROM Account ALL ROWS','SELECT Id FROM Account WITH SYSTEM_MODE','SELECT COUNT() FROM Account','SELECT Name FROM Account','SELECT Id FROM Account; DELETE FROM Account','SELECT Id FROM Account /* comment */','SELECT Id FROM OrgLoomNativeCanvas__c','SELECT Id, NotARealField__c FROM Account','SELECT Id FROM Account WHERE Name = \'unterminated'}){
                Boolean rejected=false;try{query(soql);}catch(Exception e){rejected=true;}System.assert(rejected,soql);
            }
        }
    }
    @IsTest static void selectedFileLoadsDoNotGrantGeneralSoql() {
        User actor=[SELECT Id FROM User WHERE Alias='naquery' LIMIT 1];System.runAs(actor){
            Account a=new Account(Name='File identity');insert a;
            Map<String,Object> result=(Map<String,Object>)OrgLoomNativeBrowse.fileLoad(new Map<String,Object>{'soql'=>'SELECT Id FROM Account WHERE Id IN (\''+a.Id+'\')'});
            System.assertEquals(1,((List<Object>)result.get('records')).size());
            Boolean rejected=false;try{OrgLoomNativeBrowse.fileLoad(new Map<String,Object>{'soql'=>'SELECT Id FROM Account WHERE Name != null'});}catch(Exception e){rejected=true;}System.assert(rejected);
            Map<String,Object> reply=(Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke('capabilityCheck','{"capability":"export-canvas"}'));System.assertEquals(200,reply.get('status'));
            insert new OrgLoomNativePolicy__c(Capability__c='export-canvas',Enabled__c=false);
            reply=(Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke('capabilityCheck','{"capability":"export-canvas"}'));System.assertEquals(400,reply.get('status'));
        }
    }
}
