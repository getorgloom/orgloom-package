@IsTest private class OrgLoomNativeLargeRecoveryTest {
    private static final String KEY='a'.repeat(64),WRITER='b'.repeat(64);
    private static Map<String,Object> call(String operation,Map<String,Object> body){
        Map<String,Object> response=(Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeController.invoke(operation,JSON.serialize(body)));
        System.assertEquals(200,response.get('status'),JSON.serialize(response));
        return (Map<String,Object>)response.get('data');
    }
    @TestSetup static void setup(){
        User u=new User(ProfileId=UserInfo.getProfileId(),Username='large-recovery-'+System.now().getTime()+'@example.invalid',Email='large-recovery@example.invalid',Alias='largerec',LastName='Large Recovery Test',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
        OrgLoomAccessFixture.grant(u,new Set<String>{'Access','save-canvas','open-saved-canvas'});
        System.runAs(u){
            List<Account> accounts=new List<Account>();for(Integer i=0;i<250;i++)accounts.add(new Account(Name='Recovery existing '+i));insert accounts;
            List<Object> loaded=new List<Object>(),drafts=new List<Object>(),links=new List<Object>();
            String detail='Recovery text '.repeat(80);
            for(Integer i=0;i<250;i++){
                loaded.add(new Map<String,Object>{'objectName'=>'Account','loadedFromId'=>accounts[i].Id,'values'=>new Map<String,Object>{'Name'=>accounts[i].Name,'Description'=>detail+i},'originalValues'=>new Map<String,Object>{'Description'=>'Original '+i},'changes'=>new Map<String,Object>{'Description'=>detail+i}});
                drafts.add(new Map<String,Object>{'objectName'=>'Account','tempId'=>i+1,'values'=>new Map<String,Object>{'Name'=>'Recovery draft '+i,'Description'=>detail+i}});
                links.add(new Map<String,Object>{'from'=>new Map<String,Object>{'kind'=>'draft','ref'=>i+1},'to'=>new Map<String,Object>{'kind'=>'loaded','ref'=>accounts[i].Id},'fieldName'=>'ParentId'});
            }
            Map<String,Object> payload=new Map<String,Object>{'_meta'=>new Map<String,Object>{'savedFrom'=>UserInfo.getOrganizationId()},'schema'=>new Map<String,Object>{'objects'=>new List<Object>()},'loadedRecords'=>loaded,'drafts'=>drafts,'associations'=>links};
            // Three copies of the text per pair exercise edited values as well as drafts.
            Integer size=JSON.serialize(payload).length();System.assert(size>800000&&size<1000000,'Representative snapshot size: '+size);
            call('recovery:write',new Map<String,Object>{'key'=>KEY,'writer'=>WRITER,'sequence'=>1,'payload'=>payload});
        }
    }
    @IsTest static void restoresLargeMixedCanvasThroughRemoting(){
        User actor=[SELECT Id FROM User WHERE Alias='largerec'];System.runAs(actor){
            Test.startTest();
            Map<String,Object> restored=call('recovery:restore',new Map<String,Object>{'key'=>KEY,'writer'=>'c'.repeat(64),'sequence'=>1});
            Test.stopTest();
            Map<String,Object> payload=(Map<String,Object>)restored.get('payload');
            System.assertEquals(false,restored.get('partialView'));
            List<Object> loaded=(List<Object>)payload.get('loadedRecords'),drafts=(List<Object>)payload.get('drafts');
            System.assertEquals(250,loaded.size());System.assertEquals(250,drafts.size());System.assertEquals(250,((List<Object>)payload.get('associations')).size());
            System.assertEquals('Original 249',((Map<String,Object>)((Map<String,Object>)loaded[249]).get('originalValues')).get('Description'));
            System.assertEquals('Recovery text '.repeat(80)+'249',((Map<String,Object>)((Map<String,Object>)drafts[249]).get('values')).get('Description'));
        }
    }
    @IsTest static void oversizeReplacementKeepsConfirmedCheckpoint(){
        User actor=[SELECT Id FROM User WHERE Alias='largerec'];System.runAs(actor){
            OrgLoomNativeRecovery__c before=[SELECT VersionId__c,Sequence__c FROM OrgLoomNativeRecovery__c WHERE Key__c=:KEY];
            String response=OrgLoomNativeController.invoke('recovery:write',JSON.serialize(new Map<String,Object>{'key'=>KEY,'writer'=>WRITER,'sequence'=>2,'payload'=>new Map<String,Object>{'padding'=>'x'.repeat(1000001)}}));
            System.assert(response.contains('1 MB'),response);
            OrgLoomNativeRecovery__c after=[SELECT VersionId__c,Sequence__c FROM OrgLoomNativeRecovery__c WHERE Key__c=:KEY];
            System.assertEquals(before.VersionId__c,after.VersionId__c);System.assertEquals(before.Sequence__c,after.Sequence__c);
        }
    }
}
