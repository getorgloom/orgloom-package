public with sharing class OrgLoomNativeRequests {
    public class RequestException extends Exception {}
    public static void requireRecordEdit(Id id,Boolean deleting) {
        requireRecordEdits(new Set<Id>{id},deleting?new Set<Id>{id}:new Set<Id>());
    }
    public static void requireRecordEdits(Set<Id> ids,Set<Id> deleting) {
        if(ids.isEmpty())return;
        if(ids.size()>200)throw new RequestException('Too many records to validate.');
        Id userId=UserInfo.getUserId();
        Set<Id> found=new Set<Id>();
        for(UserRecordAccess access:[SELECT RecordId,HasEditAccess,HasDeleteAccess FROM UserRecordAccess WHERE UserId=:userId AND RecordId IN :ids]){
            if(!(deleting.contains(access.RecordId)?access.HasDeleteAccess:access.HasEditAccess))throw new RequestException('Salesforce does not permit changes to this record.');
            found.add(access.RecordId);
        }
        if(found.size()!=ids.size())throw new RequestException('Salesforce does not permit changes to this record.');
    }
    // Native difference: exclusive access lets us merge contributions directly
    // into one encrypted revision, without a live-state or contribution service.
    public static Integer apply(Map<String,Object> payload,List<Object> fills) {
        if(fills==null||fills.isEmpty()||fills.size()>100)throw new RequestException('Submit between 1 and 100 requests.');
        List<Object> loaded=(List<Object>)payload.get('loadedRecords'),drafts=(List<Object>)payload.get('drafts');
        Map<String,Map<String,Object>> slots=new Map<String,Map<String,Object>>();
        List<Object> records=new List<Object>();records.addAll(loaded);records.addAll(drafts);
        for(Object raw:records){Map<String,Object> row=(Map<String,Object>)raw,slot=(Map<String,Object>)row.get('slot');if(slot!=null&&slot.get('slotId')!=null)slots.put(String.valueOf(slot.get('slotId')),row);}
        Set<String> seen=new Set<String>();Map<String,Set<Id>> referenceIds=new Map<String,Set<Id>>();
        Map<String,Map<String,Object>> completed=new Map<String,Map<String,Object>>();
        Map<String,Set<String>> replacedFields=new Map<String,Set<String>>();
        Set<Id> editedIds=new Set<Id>();
        for(Object raw:fills) {
            Map<String,Object> fill=(Map<String,Object>)raw;String slotId=String.valueOf(fill.get('slotId'));
            if(!seen.add(slotId)||!slots.containsKey(slotId))throw new RequestException('Request no longer exists or was submitted twice. Reload the canvas.');
            Map<String,Object> row=slots.get(slotId),slot=(Map<String,Object>)row.get('slot');
            if(slot.get('assigneeSfUserId')!=null&&(Id)(String)slot.get('assigneeSfUserId')!=UserInfo.getUserId())throw new RequestException('This request is assigned to another user.');
            Boolean whole=slot.get('kind')!='fields',existing=row.get('loadedFromId')!=null;
            String name=(String)row.get('objectName');Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo(name);
            Map<String,Object> incoming=(Map<String,Object>)fill.get('values');if(incoming==null||incoming.isEmpty())throw new RequestException('Enter the requested information first.');
            if(whole&&!existing&&incoming.get('Id')!=null){
                Id selected=(Id)(String)incoming.get('Id');
                if(selected.getSObjectType()!=d.getSObjectType())throw new RequestException('The selected record has the wrong object type.');
                if(OrgLoomNativeController.read(name,new Set<Id>{selected},false).isEmpty())throw new RequestException('The selected record is unavailable.');
                for(Object other:loaded)if(other!=row&&((Map<String,Object>)other).get('loadedFromId')==selected)throw new RequestException('That record is already on this canvas.');
                // An existing-record choice is identity only. Never trust the
                // browser's accompanying fields as changes or saved baselines.
                row.put('loadedFromId',selected);row.remove('values');row.remove('changes');row.remove('originalValues');row.remove('tempId');row.remove('slot');
                if(drafts.contains(row)){drafts.remove(drafts.indexOf(row));loaded.add(row);}
                completed.put(slotId,new Map<String,Object>{'kind'=>'loaded','ref'=>selected});
                continue;
            }
            if(existing)editedIds.add((Id)(String)row.get('loadedFromId'));
            if(!(existing?d.isUpdateable():d.isCreateable()))throw new RequestException('Salesforce does not permit this record operation.');
            Set<String> allowed=new Set<String>();if(!whole&&slot.get('fields')!=null)for(Object field:(List<Object>)slot.get('fields'))allowed.add((String)field);
            String key=existing?'changes':'values';Map<String,Object> changes=row.get(key)==null?new Map<String,Object>():new Map<String,Object>((Map<String,Object>)row.get(key));
            for(String field:incoming.keySet()) {
                if(!whole&&!allowed.contains(field))throw new RequestException('Only requested fields can be submitted.');
                Schema.SObjectField token=d.fields.getMap().get(field);
                if(token==null||!OrgLoomNativeController.supported(token.getDescribe()))throw new RequestException('A submitted field is unavailable.');
                Schema.DescribeFieldResult f=token.getDescribe();
                if(!(existing?f.isUpdateable():f.isCreateable())||f.isCalculated()||f.isAutoNumber())throw new RequestException('A submitted field is read-only.');
                Object value=OrgLoomNativeController.convert(incoming.get(field),f);
                if(value!=null&&f.getType()==Schema.DisplayType.REFERENCE){
                    Id target=(Id)String.valueOf(value);
                    if(!f.getReferenceTo().contains(target.getSObjectType()))throw new RequestException('Invalid relationship target.');
                    String targetName=target.getSObjectType().getDescribe().getName();
                    if(!referenceIds.containsKey(targetName))referenceIds.put(targetName,new Set<Id>());referenceIds.get(targetName).add(target);
                }
                changes.put(field,value);
            }
            row.put(key,changes);
            Set<String> changedRelationships=new Set<String>();
            if(fill.get('relationshipFields')!=null)for(Object field:(List<Object>)fill.get('relationshipFields')){
                if(!incoming.containsKey((String)field))throw new RequestException('Missing relationship value.');changedRelationships.add((String)field);
            }
            replacedFields.put(slotId,changedRelationships);
            if(whole){
                row.remove('slot');
                if(!existing&&row.get('tempId')==null){row.put('tempId','request-'+slotId);loaded.remove(loaded.indexOf(row));drafts.add(row);}
                completed.put(slotId,new Map<String,Object>{'kind'=>existing?'loaded':'draft','ref'=>existing?row.get('loadedFromId'):row.get('tempId')});
            }
        }
        requireRecordEdits(editedIds,new Set<Id>());
        if(referenceIds.size()>20)throw new RequestException('Too many relationship target objects.');
        for(String name:referenceIds.keySet())if(OrgLoomNativeController.read(name,referenceIds.get(name),false).size()!=referenceIds.get(name).size())throw new RequestException('A referenced record is unavailable.');
        List<Object> links=new List<Object>();
        if(payload.get('associations')!=null)for(Object raw:(List<Object>)payload.get('associations')){
            Map<String,Object> link=(Map<String,Object>)raw,source=(Map<String,Object>)link.get('from');
            String fromSlot=source!=null&&source.get('kind')=='slot'?String.valueOf(source.get('ref')):null;
            if(fromSlot!=null&&replacedFields.containsKey(fromSlot)&&replacedFields.get(fromSlot).contains((String)link.get('fieldName')))continue;
            for(String key:new List<String>{'from','to'}){Map<String,Object> endpoint=(Map<String,Object>)link.get(key);if(endpoint!=null&&endpoint.get('kind')=='slot'&&completed.containsKey(String.valueOf(endpoint.get('ref'))))link.put(key,completed.get(String.valueOf(endpoint.get('ref'))));}
            links.add(link);
        }
        payload.put('associations',links);return seen.size();
    }
}
