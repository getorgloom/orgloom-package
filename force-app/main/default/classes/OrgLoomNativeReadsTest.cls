@IsTest private class OrgLoomNativeReadsTest {
    @TestSetup static void setup() {
        User u=new User(ProfileId=UserInfo.getProfileId(),Username='native-reads-'+System.now().getTime()+'@example.invalid',Email='reads@example.invalid',Alias='nareads',LastName='Native Reads Test',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
        OrgLoomAccessFixture.grant(u,new Set<String>{'Access'});
    }
    @IsTest static void dynamicDiscoveryAndGraph() {
        User actor=[SELECT Id FROM User WHERE Alias='nareads' LIMIT 1];
        System.runAs(actor) {
            Map<String,Object> reply=(Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke('objects','{}'));
            System.assertEquals(200,reply.get('status'),JSON.serialize(reply));Set<String> names=new Set<String>();
            for(Object raw:(List<Object>)reply.get('data'))names.add((String)((Map<String,Object>)raw).get('name'));
            System.assert(names.contains('Lead'));System.assert(names.contains('Task'));System.assert(!names.contains('OrgLoomNativeCanvas__c'));System.assert(!names.contains('OrgLoomNativeKey__c'));
            Map<String,Object> graph=(Map<String,Object>)OrgLoomNativeReads.graph('Contact');Boolean account=false;
            for(Object raw:(List<Object>)graph.get('parents')){Map<String,Object> r=(Map<String,Object>)raw;if(r.get('object')=='Account'&&r.get('field')=='AccountId')account=true;}
            System.assert(account,'Contact must expose its Account relationship.');
            try{OrgLoomNativeController.objectInfo('OrgLoomNativeKey__c');System.assert(false);}catch(Exception expected){}
        }
    }
    @IsTest static void relationshipsLookupAndRefresh() {
        User actor=[SELECT Id FROM User WHERE Alias='nareads' LIMIT 1];
        System.runAs(actor) {
            Account a=new Account(Name='Native relationship fixture');insert a;
            Contact c=new Contact(LastName='Native contact fixture',AccountId=a.Id);insert c;
            Map<String,Object> request=new Map<String,Object>{'objectName'=>'Contact','field'=>'AccountId','id'=>a.Id};
            System.assertEquals(1,((Map<String,Object>)OrgLoomNativeReads.handle('related-count',request)).get('count'));
            List<SObject> rows=(List<SObject>)((Map<String,Object>)OrgLoomNativeReads.handle('by-ref',request)).get('records');System.assertEquals(c.Id,rows[0].get('Id'));
            Map<String,Object> lookup=(Map<String,Object>)OrgLoomNativeReads.handle('lookup',new Map<String,Object>{'objectName'=>'Contact','fieldName'=>'AccountId','targetApiName'=>'Account','q'=>'Native relationship fixture'});
            System.assertEquals(a.Id,((Map<String,Object>)((List<Object>)lookup.get('records'))[0]).get('id'));
            try{OrgLoomNativeReads.handle('lookup',new Map<String,Object>{'objectName'=>'Contact','fieldName'=>'AccountId','targetApiName'=>'Lead','q'=>'test'});System.assert(false);}catch(OrgLoomNativeReads.ReadException expected){}
            List<Object> results=(List<Object>)((Map<String,Object>)OrgLoomNativeReads.handle('refresh',new Map<String,Object>{'records'=>new List<Object>{new Map<String,Object>{'objectName'=>'Contact','sfId'=>c.Id}}})).get('results');
            System.assertEquals(true,((Map<String,Object>)results[0]).get('ok'));
            delete c;
            results=(List<Object>)((Map<String,Object>)OrgLoomNativeReads.handle('refresh',new Map<String,Object>{'records'=>new List<Object>{new Map<String,Object>{'objectName'=>'Contact','sfId'=>c.Id}}})).get('results');
            System.assertEquals(false,((Map<String,Object>)results[0]).get('ok'));
        }
    }
    @IsTest static void lookupExcludesSourceBeforeLimit() {
        User actor=[SELECT Id FROM User WHERE Alias='nareads' LIMIT 1];
        System.runAs(actor) {
            Account source=new Account(Name='Self lookup fixture');insert source;
            List<Account> peers=new List<Account>();
            for(Integer i=0;i<25;i++)peers.add(new Account(Name='Self lookup fixture '+i));
            insert peers;
            Map<String,Object> request=new Map<String,Object>{'objectName'=>'Account','fieldName'=>'ParentId','targetApiName'=>'Account','q'=>'Self lookup fixture','sourceRecordId'=>String.valueOf(source.Id).substring(0,15)};
            List<Object> rows=(List<Object>)((Map<String,Object>)OrgLoomNativeReads.handle('lookup',request)).get('records');
            System.assertEquals(25,rows.size());
            for(Object raw:rows)System.assertNotEquals(source.Id,((Map<String,Object>)raw).get('id'));
            request.put('q',String.valueOf(source.Id));request.put('sourceRecordId',String.valueOf(source.Id));
            System.assertEquals(0,((List<Object>)((Map<String,Object>)OrgLoomNativeReads.handle('lookup',request)).get('records')).size());
            request.put('q','');
            for(Object raw:(List<Object>)((Map<String,Object>)OrgLoomNativeReads.handle('lookup',request)).get('records'))System.assertNotEquals(source.Id,((Map<String,Object>)raw).get('id'));
            request.put('sourceRecordId','bad input');
            try{OrgLoomNativeReads.handle('lookup',request);System.assert(false,'Invalid source IDs must fail.');}catch(OrgLoomNativeReads.ReadException expected){}
        }
    }
    @IsTest static void deniedReaderCannotUseRelatedRoutes() {
        Profile p=[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' LIMIT 1];
        User u=new User(ProfileId=p.Id,Username='native-read-denied-'+System.now().getTime()+'@example.invalid',Email='denied@example.invalid',Alias='nardeny',LastName='Native Read Denied',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
        OrgLoomAccessFixture.grant(u,new Set<String>{'Access'});
        System.runAs(u) {
            System.assertEquals(false,OrgLoomNativeController.available(Account.SObjectType.getDescribe()));
            for(String operation:new List<String>{'graph','search','by-ref','lookup'}) {
                Map<String,Object> reply=(Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke('reads:'+operation,'{"objectName":"Account","q":"test","field":"ParentId","fieldName":"ParentId","targetApiName":"Account","id":"001000000000001"}'));
                System.assertEquals(400,reply.get('status'),operation);
            }
        }
    }
}
