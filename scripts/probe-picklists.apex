String rt=String.valueOf(Account.SObjectType.getDescribe().getRecordTypeInfos()[0].getRecordTypeId());
Object values=ConnectApi.RecordUi.getPicklistValuesByRecordType('Account',rt);
System.debug('PICKLIST_SHAPE '+JSON.serialize(values));
