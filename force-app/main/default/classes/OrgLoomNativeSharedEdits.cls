public with sharing class OrgLoomNativeSharedEdits {
    private static String identity(Map<String,Object> row){return row.get('loadedFromId')!=null?'loaded:'+row.get('loadedFromId'):row.get('tempId')!=null?'draft:'+row.get('tempId'):'slot:'+((Map<String,Object>)row.get('slot')).get('slotId');}
    private static Map<String,Map<String,Object>> rows(Map<String,Object> payload){
        Map<String,Map<String,Object>> result=new Map<String,Map<String,Object>>();
        for(String key:new List<String>{'loadedRecords','drafts'})if(payload.get(key)!=null)for(Object raw:(List<Object>)payload.get(key)){Map<String,Object> row=(Map<String,Object>)raw;String id=identity(row);if(result.containsKey(id))throw new OrgLoomNativeCanvases.CanvasException('Duplicate canvas record.');result.put(id,row);}
        return result;
    }
    private static String digest(Object value){return OrgLoomNativeUpload.fingerprint(new Map<String,Object>{'value'=>value});}
    public static void requests(Map<String,Object> before,Map<String,Object> after) {
        Map<String,Object> oldSlots=new Map<String,Object>(),newSlots=new Map<String,Object>();
        if(before!=null)for(Map<String,Object> row:rows(before).values())if(row.get('slot')!=null)oldSlots.put(identity(row),row.get('slot'));
        for(Map<String,Object> row:rows(after).values())if(row.get('slot')!=null)newSlots.put(identity(row),row.get('slot'));
        if(digest(oldSlots)!=digest(newSlots))OrgLoomNativeAccess.requireCapability('create-slot-canvas');
    }
    public static void validate(Map<String,Object> before,Map<String,Object> after) {
        Map<String,Map<String,Object>> original=rows(before),proposed=rows(after);
        Set<Id> editedIds=new Set<Id>(),deletedIds=new Set<Id>();
        Map<String,Set<Id>> referenceIds=new Map<String,Set<Id>>();
        Integer changedRecords=0;
        for(String id:proposed.keySet()) {
            Map<String,Object> row=proposed.get(id),old=original.get(id);String name=(String)row.get('objectName');
            if(old!=null&&old.get('objectName')!=name)throw new OrgLoomNativeCanvases.CanvasException('A record object cannot be changed.');
            Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo(name);
            Boolean existing=row.get('loadedFromId')!=null,changed=false;
            for(String key:new List<String>{'changes','values'}) {
                Map<String,Object> current=row.get(key)==null?new Map<String,Object>():(Map<String,Object>)row.get(key);
                Map<String,Object> previous=old==null||old.get(key)==null?new Map<String,Object>():(Map<String,Object>)old.get(key);
                Set<String> fields=new Set<String>(current.keySet());fields.addAll(previous.keySet());
                for(String field:fields)if(digest(current.get(field))!=digest(previous.get(field))) {
                    changed=true;Schema.SObjectField token=d.fields.getMap().get(field);
                    if(token==null)throw new OrgLoomNativeCanvases.CanvasException('Unknown field.');
                    Schema.DescribeFieldResult f=token.getDescribe();
                    if(!OrgLoomNativeController.supported(f)||!(existing?f.isUpdateable():f.isCreateable())||f.isCalculated()||f.isAutoNumber())throw new OrgLoomNativeCanvases.CanvasException('You cannot change '+field+'.');
                    Object value=OrgLoomNativeController.convert(current.get(field),f);
                    if(value!=null&&f.getType()==Schema.DisplayType.REFERENCE){
                        Id target=(Id)String.valueOf(value);
                        if(!f.getReferenceTo().contains(target.getSObjectType()))throw new OrgLoomNativeCanvases.CanvasException('Invalid relationship target.');
                        String targetName=target.getSObjectType().getDescribe().getName();
                        if(!referenceIds.containsKey(targetName))referenceIds.put(targetName,new Set<Id>());
                        referenceIds.get(targetName).add(target);
                    }
                }
            }
            Boolean deleting=row.get('pendingDelete')==true&&(old==null||old.get('pendingDelete')!=true);
            if(changed||deleting){
                if(++changedRecords>50)throw new OrgLoomNativeCanvases.CanvasException('Save at most 50 changed records at a time in a shared canvas.');
                if(existing){editedIds.add((Id)(String)row.get('loadedFromId'));if(deleting)deletedIds.add((Id)(String)row.get('loadedFromId'));}
                else if(!d.isCreateable())throw new OrgLoomNativeCanvases.CanvasException('You cannot create this object.');
            }
        }
        // Relationship edits can change a field even when no values map changed.
        Map<String,Object> oldLinks=new Map<String,Object>(),newLinks=new Map<String,Object>();
        if(before.get('associations')!=null)for(Object link:(List<Object>)before.get('associations'))oldLinks.put(digest(link),link);
        if(after.get('associations')!=null)for(Object link:(List<Object>)after.get('associations'))newLinks.put(digest(link),link);
        List<Object> changes=new List<Object>();
        for(String key:newLinks.keySet())if(!oldLinks.containsKey(key))changes.add(newLinks.get(key));
        for(String key:oldLinks.keySet())if(!newLinks.containsKey(key))changes.add(oldLinks.get(key));
        for(Object raw:changes){
            Map<String,Object> link=(Map<String,Object>)raw,endpoint=(Map<String,Object>)link.get('from');String ref=endpoint.get('kind')+':'+endpoint.get('ref');
            Map<String,Object> row=proposed.get(ref);
            if(row==null)row=original.get(ref);
            if(row==null&&endpoint.get('kind')=='slot')for(Map<String,Object> candidate:proposed.values()){Map<String,Object> slot=(Map<String,Object>)candidate.get('slot');if(slot!=null&&String.valueOf(slot.get('slotId'))==String.valueOf(endpoint.get('ref')))row=candidate;}
            if(row==null)throw new OrgLoomNativeCanvases.CanvasException('Unknown relationship source.');
            Schema.SObjectField token=OrgLoomNativeController.objectInfo((String)row.get('objectName')).fields.getMap().get((String)link.get('fieldName'));
            Boolean existing=row.get('loadedFromId')!=null;
            if(token==null||!(existing?token.getDescribe().isUpdateable():token.getDescribe().isCreateable()))throw new OrgLoomNativeCanvases.CanvasException('You cannot change this relationship.');
            if(existing)editedIds.add((Id)(String)row.get('loadedFromId'));
        }
        OrgLoomNativeRequests.requireRecordEdits(editedIds,deletedIds);
        if(referenceIds.size()>20)throw new OrgLoomNativeCanvases.CanvasException('Too many relationship target objects.');
        for(String name:referenceIds.keySet())if(OrgLoomNativeController.read(name,referenceIds.get(name),false).size()!=referenceIds.get(name).size())throw new OrgLoomNativeCanvases.CanvasException('A referenced record is unavailable.');
    }
}
