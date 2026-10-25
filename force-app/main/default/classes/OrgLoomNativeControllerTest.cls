@IsTest
private class OrgLoomNativeControllerTest {
    @TestSetup static void featureGrants() {
        User u=new User(ProfileId=UserInfo.getProfileId(),Username='native-controller-'+System.now().getTime()+'@example.invalid',Email='native-controller@example.invalid',Alias='nactrl',LastName='Native Controller Test',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
        Set<String> names=new Set<String>{'Access','soql-import','upload-records','bulk-edit-records'};

        OrgLoomAccessFixture.grant(u,names);

    }
    private static Map<String,Object> call(String op,Map<String,Object> body) {
        return (Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke(op,JSON.serialize(body)));
    }
    private static Map<String,Object> payload(Account a,String phone) {
        Map<String,Object> fetched=call('record',new Map<String,Object>{'objectName'=>'Account','recordId'=>a.Id});
        System.assertEquals(200,fetched.get('status'),JSON.serialize(fetched));
        Map<String,Object> original=(Map<String,Object>)fetched.get('data');
        Map<String,Object> values=new Map<String,Object>(original);values.put('Phone',phone);
        return new Map<String,Object>{'attemptId'=>EncodingUtil.convertToHex(Crypto.generateAesKey(128)),'expectedSfOrgId'=>UserInfo.getOrganizationId(),'records'=>new List<Object>{new Map<String,Object>{'tempId'=>1,'objectName'=>'Account','loadedFromId'=>a.Id,'loadedValues'=>original,'values'=>values}},'deletes'=>new List<Object>()};
    }
    @IsTest static void readsAndUpdates() {
      User actor=[SELECT Id FROM User WHERE Alias='nactrl' LIMIT 1];
      System.runAs(actor) {
        Account a=new Account(Name='Native MVP test',Phone='555-0100');insert a;
        Map<String,Object> result=call('query',new Map<String,Object>{'soql'=>'SELECT Id,Name FROM Account WHERE Id = \''+a.Id+'\' LIMIT 1'});
        System.assertEquals(200,result.get('status'),JSON.serialize(result));
        List<Object> records=(List<Object>)((Map<String,Object>)result.get('data')).get('records');System.assertEquals(1,records.size());
        Map<String,Object> body=payload(a,'555-0101');
        result=call('upload',body);System.assertEquals(200,result.get('status'),JSON.serialize(result));
        System.assertEquals('555-0101',[SELECT Phone FROM Account WHERE Id=:a.Id].Phone);
        Map<String,Object> described=call('describe',new Map<String,Object>{'objectName'=>'Account'});
        System.assertEquals(200,described.get('status'));
        Map<String,Object> metadata=(Map<String,Object>)described.get('data');
        for(Object rawField:(List<Object>)metadata.get('fields')){Map<String,Object> field=(Map<String,Object>)rawField;if(field.get('name')=='NumberOfEmployees')System.assertEquals('int',field.get('type'));}
        List<Object> types=(List<Object>)metadata.get('recordTypes');System.assert(!types.isEmpty());
        Boolean defaultFound=false;
        for(Object rawType:types) {
            Map<String,Object> rt=(Map<String,Object>)rawType;
            System.assertNotEquals(null,rt.get('id'));System.assertEquals(rt.get('recordTypeId'),rt.get('id'));
            System.assertEquals(rt.get('name'),rt.get('label'));System.assertEquals(true,rt.get('available'));
            if(rt.get('isDefault')==true) {defaultFound=true;System.assertEquals(rt.get('id'),metadata.get('defaultRecordTypeId'));}
        }
        System.assert(defaultFound,'Editor must receive the current user default record type.');
        System.assertEquals(200,call('objects',new Map<String,Object>()).get('status'));
        System.assertEquals(200,call('access',new Map<String,Object>{'records'=>new List<Object>{new Map<String,Object>{'tempId'=>1,'sfId'=>a.Id}}}).get('status'));
      }
    }
    @IsTest static void invalidWritesStayUnchanged() {
      User actor=[SELECT Id FROM User WHERE Alias='nactrl' LIMIT 1];
      System.runAs(actor) {
        Account a=new Account(Name='Native protected test',Phone='before');insert a;
        Map<String,Object> body=payload(a,'after');
        body.put('expectedSfOrgId','00D000000000000AAA');
        System.assertEquals(400,call('upload',body).get('status'));
        body=payload(a,'after');Map<String,Object> row=(Map<String,Object>)((List<Object>)body.get('records'))[0];
        ((Map<String,Object>)row.get('loadedValues')).put('LastModifiedDate','2000-01-01T00:00:00.000Z');
        System.assertEquals(400,call('upload',body).get('status'));
        body=payload(a,'after');row=(Map<String,Object>)((List<Object>)body.get('records'))[0];
        ((Map<String,Object>)row.get('values')).put('CreatedDate','2000-01-01T00:00:00.000Z');
        System.assertEquals(400,call('upload',body).get('status'));
        body=payload(a,'after');((List<Object>)body.get('records')).add(((List<Object>)body.get('records'))[0]);
        System.assertEquals(400,call('upload',body).get('status'));
        System.assertEquals('before',[SELECT Phone FROM Account WHERE Id=:a.Id].Phone);
        System.assertEquals(400,call('query',new Map<String,Object>{'soql'=>'SELECT Id FROM Account FOR UPDATE'}).get('status'));
        System.assertEquals(400,call('query',new Map<String,Object>{'soql'=>'SELECT Id FROM OrgLoomNativeCanvas__c'}).get('status'));
        System.assertEquals(400,call('unknown',new Map<String,Object>()).get('status'));
      }
    }
    @IsTest static void recordTypePicklistsUseNativeUiApiShape() {
        User actor=[SELECT Id FROM User WHERE Alias='nactrl' LIMIT 1];
        System.runAs(actor) {
            OrgLoomNativeMetadata.testPicklists=new Map<String,Object>{'picklistFieldValues'=>new Map<String,Object>{
                'Industry'=>new Map<String,Object>{'defaultValue'=>new Map<String,Object>{'value'=>'Technology'},
                    'controllerValues'=>new Map<String,Object>{'A'=>0},'values'=>new List<Object>{new Map<String,Object>{'label'=>'Technology','value'=>'Technology','validFor'=>new List<Object>{0}}}},
                'UnknownSecret__c'=>new Map<String,Object>{'values'=>new List<Object>{'hidden'}}
            }};
            Map<String,Object> response=call('layout',new Map<String,Object>{'objectName'=>'Account'});
            System.assertEquals(200,response.get('status'),JSON.serialize(response));
            Map<String,Object> data=(Map<String,Object>)response.get('data');
            System.assertNotEquals(null,data.get('recordTypeId'));
            System.assertEquals(data.get('recordTypeId'),data.get('picklistValuesRecordTypeId'));
            Map<String,Object> fields=(Map<String,Object>)data.get('picklistValues');
            System.assert(!fields.containsKey('UnknownSecret__c'));
            Map<String,Object> industry=(Map<String,Object>)fields.get('Industry');
            System.assertEquals('Technology',industry.get('defaultValue'));
            System.assertEquals(0,((Map<String,Object>)industry.get('controllerValues')).get('A'));
        }
    }
    @IsTest static void layoutChecksRecordAndRecordTypeIdentity() {
        User actor=[SELECT Id FROM User WHERE Alias='nactrl' LIMIT 1];
        System.runAs(actor) {
            Contact c=new Contact(LastName='Layout fixture');insert c;
            System.assertEquals(400,call('layout',new Map<String,Object>{'objectName'=>'Account','recordId'=>c.Id}).get('status'));
            System.assertEquals(400,call('layout',new Map<String,Object>{'objectName'=>'Account','recordTypeId'=>c.Id}).get('status'));
            System.assertEquals(400,call('layout',new Map<String,Object>{'objectName'=>'OrgLoomNativeCanvas__c'}).get('status'));
        }
    }
    @IsTest static void deniedUserCannotReadOrUpdate() {
        Profile p=[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' LIMIT 1];
        User u=new User(ProfileId=p.Id,Username='native-mvp-'+System.now().getTime()+'@example.invalid',Email='native-mvp@example.invalid',Alias='nativeqa',LastName='Native QA',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');
        insert u;
        OrgLoomAccessFixture.grant(u,new Set<String>{'Access','soql-import'});
        System.runAs(u) {
            System.assertEquals(400,call('query',new Map<String,Object>{'soql'=>'SELECT Id FROM Account LIMIT 1'}).get('status'));
            System.assertEquals(400,call('describe',new Map<String,Object>{'objectName'=>'Account'}).get('status'));
            System.assertEquals(400,call('layout',new Map<String,Object>{'objectName'=>'Account'}).get('status'));
        }
    }
}
