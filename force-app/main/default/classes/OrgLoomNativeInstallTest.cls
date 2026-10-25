@IsTest private class OrgLoomNativeInstallTest {
    @IsTest static void installerGrantsAreScopedAndIdempotent() {
        User u=new User(ProfileId=UserInfo.getProfileId(),Username='native-install-'+System.now().getTime()+'@example.invalid',Email='native-install@example.invalid',Alias='nainst',LastName='Native Install',TimeZoneSidKey='America/Phoenix',LocaleSidKey='en_US',EmailEncodingKey='UTF-8',LanguageLocaleKey='en_US');insert u;
        System.runAs(u){Test.testInstall(new OrgLoomNativeInstall(),null,false);}
        OrgLoomNativeInstall.assignInstaller(u.Id);
        String ns=OrgLoomNativeAccess.packageNamespace();
        System.assertEquals(1,[SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId=:u.Id AND PermissionSet.NamespacePrefix=:ns AND PermissionSet.Name IN ('OrgLoomNative_Admin')]);
        System.assertEquals(0,[SELECT COUNT() FROM OrgLoomFeatureAccess__c]);
    }
}
