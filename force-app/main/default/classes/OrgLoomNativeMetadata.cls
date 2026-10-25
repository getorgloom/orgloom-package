public with sharing class OrgLoomNativeMetadata {
    public class MetadataException extends Exception {}
    @TestVisible private static Map<String,Object> testPicklists;
    public static Object layout(Map<String,Object> body) {
        OrgLoomNativeAccess.requireAccess();
        String name=(String)body.get('objectName');
        Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo(name);
        String rt=(String)body.get('recordTypeId');
        if(body.get('recordId')!=null) {
            Id id=(Id)(String)body.get('recordId');
            if(id.getSObjectType()!=d.getSObjectType())throw new MetadataException('Invalid layout record.');
            List<SObject> records=OrgLoomNativeController.read(name,new Set<Id>{id},false);
            if(records.isEmpty())throw new MetadataException('Record unavailable.');
            if(rt==null&&d.fields.getMap().containsKey('RecordTypeId'))rt=(String)records[0].get('RecordTypeId');
        }
        if(rt==null)for(Schema.RecordTypeInfo info:d.getRecordTypeInfos())if(info.isDefaultRecordTypeMapping())rt=info.getRecordTypeId();
        Schema.RecordTypeInfo selected=rt==null?null:d.getRecordTypeInfosById().get((Id)rt);
        if(selected==null||!selected.isAvailable()||!selected.isActive())throw new MetadataException('Record type is unavailable.');
        Map<String,Object> result=new Map<String,Object>{'available'=>false,'sections'=>new List<Object>(),'recordTypeId'=>rt,
            'reason'=>'Using accessible fields because a Salesforce page layout is unavailable in this view.'};
        Map<String,Object> raw;
        try {
            raw=Test.isRunningTest()&&testPicklists!=null?testPicklists:(Map<String,Object>)JSON.deserializeUntyped(JSON.serialize(ConnectApi.RecordUi.getPicklistValuesByRecordType(name,rt)));
        } catch(Exception e) {
            // UI API supports fewer objects than Apex describe. Do not invent
            // record-type choices using the unfiltered global picklist.
            result.put('picklistUnavailable',true);return result;
        }
        Map<String,Object> values=(Map<String,Object>)raw.get('picklistFieldValues'),filtered=new Map<String,Object>();
        if(values!=null)for(String field:values.keySet()) {
            Schema.SObjectField token=d.fields.getMap().get(field);
            if(token==null||!OrgLoomNativeController.supported(token.getDescribe()))continue;
            Map<String,Object> entry=new Map<String,Object>((Map<String,Object>)values.get(field));
            Map<String,Object> defaultValue=(Map<String,Object>)entry.get('defaultValue');
            entry.put('defaultValue',defaultValue==null?null:defaultValue.get('value'));
            entry.remove('url');entry.remove('eTag');filtered.put(field,entry);
        }
        result.put('picklistValues',filtered);result.put('picklistValuesRecordTypeId',rt);return result;
    }
}
