// Only the uploader can read application receipts. Business record reads below
// always go through the current user's USER_MODE read path.
public without sharing class OrgLoomNativeHistory {
    public class HistoryException extends Exception {}
    private static String context(Id id){return UserInfo.getOrganizationId()+':upload-recall:'+id;}
    private static Boolean sameTime(Object left,Object right){
        if(left==null||right==null)return left==null&&right==null;
        Datetime leftTime=(Datetime)JSON.deserialize(JSON.serialize(left),Datetime.class),rightTime=(Datetime)JSON.deserialize(JSON.serialize(right),Datetime.class);
        return leftTime.getTime()==rightTime.getTime();
    }
    @TestVisible private static Boolean sameFieldValue(Object left,Object right,Schema.DescribeFieldResult field){
        if(left==null||right==null)return left==null&&right==null;
        // SOQL returns a Datetime; encrypted JSON history returns an ISO string.
        // Compare instants, preserving milliseconds, rather than timezone formatting.
        if(field.getType()==Schema.DisplayType.DATETIME){
            try{return sameTime(left,right);}catch(Exception e){return false;}
        }
        return JSON.serialize(left)==JSON.serialize(right);
    }
    private static Map<String,Object> asMap(Object value){return (Map<String,Object>)JSON.deserializeUntyped(JSON.serialize(value));}
    public static void capture(OrgLoomNativeAttempt__c journal,List<Object> results,Map<String,Object> after,Map<Id,SObject> originals,Map<String,Map<String,Object>> rows,Map<String,Map<String,String>> links){
        List<Object> records=new List<Object>();
        for(Object raw:results){
            Map<String,Object> result=(Map<String,Object>)raw;String mode=(String)result.get('mode');if(mode!='create'&&mode!='update')continue;
            String temp=String.valueOf(result.get('tempId')),name=(String)result.get('objectName');Id id=(Id)String.valueOf(result.get('id'));
            if(!after.containsKey(temp))throw new HistoryException('Could not capture upload history. No changes were committed.');
            Map<String,Object> current=OrgLoomNativeEncrypted.strip(name,asMap(after.get(temp))),before=new Map<String,Object>(),uploaded=new Map<String,Object>();
            if(mode=='update'){
                Set<String> fields=new Set<String>(((Map<String,Object>)rows.get(temp).get('values')).keySet());if(links.containsKey(temp))fields.addAll(links.get(temp).keySet());
                Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo(name);
                for(String field:fields){Schema.SObjectField token=d.fields.getMap().get(field);if(token==null)continue;Schema.DescribeFieldResult f=token.getDescribe();
                    if(!OrgLoomNativeEncrypted.isField(name,field)&&OrgLoomNativeController.supported(f)&&f.isUpdateable()&&!f.isCalculated()&&!f.isAutoNumber()){
                        Object old=originals.get(id).get(field),value=current.get(field);
                        if(!sameFieldValue(old,value,f)){before.put(field,old);uploaded.put(field,value);}
                    }
                }
            }
            records.add(new Map<String,Object>{'sfId'=>id,'objectName'=>name,'mode'=>mode,'before'=>before,'after'=>uploaded,'lastModifiedDate'=>current.get('LastModifiedDate'),'createdValues'=>mode=='create'?current:null});
        }
        String serialized=JSON.serialize(new Map<String,Object>{'records'=>records});
        if(serialized.length()>500000)throw new HistoryException('Encrypted upload history exceeds 500 KB. Upload fewer records. No changes were committed.');
        ContentVersion file=new ContentVersion(Title='Org Loom encrypted upload history',PathOnClient='upload-recall.orgloom.enc',VersionData=OrgLoomNativeCrypto.seal(serialized,context(journal.Id)));
        insert file;journal.RecallVersion__c=file.Id;update journal;
    }
    private static OrgLoomNativeAttempt__c owned(Id id){
        List<OrgLoomNativeAttempt__c> found=[SELECT Id,OwnerId,CreatedDate,Results__c,RecallVersion__c,RecallResult__c,Hidden__c FROM OrgLoomNativeAttempt__c WHERE Id=:id AND OwnerId=:UserInfo.getUserId() LIMIT 1 FOR UPDATE];
        if(found.isEmpty()||found[0].RecallVersion__c==null)throw new HistoryException('Upload history is unavailable.');return found[0];
    }
    private static Map<String,Object> snapshot(OrgLoomNativeAttempt__c journal){
        ContentVersion file=[SELECT VersionData FROM ContentVersion WHERE Id=:journal.RecallVersion__c];
        return (Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeCrypto.open(file.VersionData,context(journal.Id)));
    }
    private static Map<String,Object> info(OrgLoomNativeAttempt__c journal){
        Map<String,Object> receipt=(Map<String,Object>)JSON.deserializeUntyped(journal.Results__c);List<Object> records=(List<Object>)receipt.get('results'),deleted=(List<Object>)receipt.get('deletes');
        String status='uploaded';if(journal.RecallResult__c!=null)status=(String)((Map<String,Object>)JSON.deserializeUntyped(journal.RecallResult__c)).get('status');
        return new Map<String,Object>{'id'=>journal.Id,'createdAt'=>journal.CreatedDate.getTime(),'preUploadCapturedAt'=>journal.CreatedDate.getTime(),'status'=>status,'recordCount'=>records.size()+deleted.size(),'insertedCount'=>records.size(),'deletedCount'=>deleted.size(),'instanceUrl'=>URL.getOrgDomainUrl().toExternalForm()};
    }
    public static Object listBatches(Map<String,Object> body){
        OrgLoomNativeAccess.requireCapability('view-activity-history');
        Integer offset=body.get('offset')==null?0:Integer.valueOf(String.valueOf(body.get('offset')));if(offset<0||offset>2000)throw new HistoryException('Invalid history offset.');
        List<OrgLoomNativeAttempt__c> found=[SELECT Id,CreatedDate,Results__c,RecallResult__c FROM OrgLoomNativeAttempt__c WHERE OwnerId=:UserInfo.getUserId() AND RecallVersion__c!=null AND Hidden__c=false ORDER BY CreatedDate DESC,Id DESC LIMIT 16 OFFSET :offset];
        Boolean more=found.size()>15;if(more)found.remove(15);List<Object> batches=new List<Object>();for(OrgLoomNativeAttempt__c journal:found)batches.add(info(journal));
        return new Map<String,Object>{'batches'=>batches,'pagination'=>new Map<String,Object>{'hasMore'=>more,'nextOffset'=>offset+found.size()}};
    }
    public static Object forget(Id id){OrgLoomNativeAccess.requireCapability('view-activity-history');OrgLoomNativeAttempt__c journal=owned(id);journal.Hidden__c=true;update journal;return new Map<String,Object>{'ok'=>true};}
    private static Map<Id,SObject> current(List<Object> records,Boolean lockRows){
        Map<String,Set<Id>> groups=new Map<String,Set<Id>>();for(Object raw:records){Map<String,Object> r=(Map<String,Object>)raw;String name=(String)r.get('objectName');OrgLoomNativeController.objectInfo(name);if(!groups.containsKey(name))groups.put(name,new Set<Id>());groups.get(name).add((Id)(String)r.get('sfId'));}
        Map<Id,SObject> found=new Map<Id,SObject>();for(String name:groups.keySet())found.putAll(OrgLoomNativeController.read(name,groups.get(name),lockRows));return found;
    }
    private static String token(Id id,Map<Id,SObject> found){return OrgLoomNativeUpload.fingerprint(new Map<String,Object>{'batch'=>id,'current'=>asMap(found)});}
    private static Boolean creationChanged(Map<String,Object> record,SObject live){
        String name=(String)record.get('objectName');
        return record.get('createdValues')!=null?OrgLoomNativeUpload.fingerprint(OrgLoomNativeEncrypted.strip(name,asMap(live)))!=OrgLoomNativeUpload.fingerprint(OrgLoomNativeEncrypted.strip(name,(Map<String,Object>)record.get('createdValues'))):!sameTime(live.get('LastModifiedDate'),record.get('lastModifiedDate'));
    }
    public static Object preflight(Id id){
        OrgLoomNativeAccess.requireCapability('recall-upload');OrgLoomNativeAttempt__c journal=owned(id);List<Object> records=(List<Object>)snapshot(journal).get('records');Map<Id,SObject> found=current(records,false);
        List<Object> clean=new List<Object>(),drifted=new List<Object>(),unverified=new List<Object>(),review=new List<Object>();Integer changedCount=0;
        Map<String,Object> completed=completion(journal);
        for(Object raw:records){
            Map<String,Object> record=(Map<String,Object>)raw;Id sfId=(Id)(String)record.get('sfId');String name=(String)record.get('objectName');
            SObject live=found.get(sfId);Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo(name);
            Map<String,Object> label=new Map<String,Object>{'sfId'=>sfId,'objectName'=>name,'objectLabel'=>d.getLabel(),'recordName'=>sfId};
            if(live==null){label.put('probeError','Record is deleted or no longer accessible');unverified.add(label);continue;}
            for(Schema.SObjectField f:d.fields.getMap().values())if(f.getDescribe().isNameField()&&OrgLoomNativeController.supported(f.getDescribe()))label.put('recordName',live.get(f.getDescribe().getName()));
            if(record.get('mode')=='create'){
                if(completed.containsKey(String.valueOf(sfId)))continue;
                if(!d.isDeletable()){label.put('probeError','Salesforce does not permit deletion');unverified.add(label);continue;}
                if(!creationChanged(record,live))clean.add(label);else drifted.add(label);
            }else{
                List<Object> sameFields=new List<Object>(),changedFields=new List<Object>();Map<String,Object> prior=(Map<String,Object>)record.get('before'),uploaded=(Map<String,Object>)record.get('after');
                for(String field:prior.keySet()){
                    if(completed.containsKey(sfId+':'+field)||OrgLoomNativeEncrypted.isField(name,field))continue;
                    Schema.SObjectField f=d.fields.getMap().get(field);if(f==null||!OrgLoomNativeController.supported(f.getDescribe())||!f.getDescribe().isUpdateable())continue;
                    Object value=live.get(field);Map<String,Object> detail=new Map<String,Object>{'fieldName'=>field,'prior'=>prior.get(field),'uploaded'=>uploaded.get(field),'current'=>value};
                    if(sameFieldValue(value,uploaded.get(field),f.getDescribe()))sameFields.add(detail);else{changedFields.add(detail);changedCount++;}
                }
                label.put('clean',sameFields);label.put('drifted',changedFields);review.add(label);
            }
        }
        return new Map<String,Object>{'batch'=>info(journal),'clean'=>clean,'drifted'=>drifted,'unverified'=>unverified,'alreadyDeleted'=>new List<Object>(),'cascadeConflicts'=>new List<Object>(),'valueDrift'=>new Map<String,Object>{'records'=>review,'summary'=>new Map<String,Object>{'driftedFieldCount'=>changedCount}},'nativeReviewToken'=>token(id,found)};
    }
    private static Map<String,Object> completion(OrgLoomNativeAttempt__c journal){
        if(journal.RecallResult__c==null)return new Map<String,Object>();Map<String,Object> result=(Map<String,Object>)JSON.deserializeUntyped(journal.RecallResult__c);return result.get('completed')==null?new Map<String,Object>():(Map<String,Object>)result.get('completed');
    }
    private static Set<Id> idSet(Object raw){Set<Id> result=new Set<Id>();if(raw!=null)for(Object id:(List<Object>)raw)result.add((Id)(String)id);return result;}
    private static void checkDependents(Set<Id> selected,Map<Id,SObject> found){
        Map<String,Set<Id>> groups=new Map<String,Set<Id>>();for(Id id:selected){String name=id.getSObjectType().getDescribe().getName();if(!groups.containsKey(name))groups.put(name,new Set<Id>());groups.get(name).add(id);}
        // This system-mode existence check cannot reveal child values. It blocks
        // deletion if it would cascade or unlink ANY record outside the selection,
        // including records hidden from the uploader. DML still uses USER_MODE.
        for(String name:groups.keySet()){
            List<String> relationships=new List<String>();
            for(Schema.ChildRelationship child:OrgLoomNativeController.objectInfo(name).getChildRelationships())if(child.getRelationshipName()!=null&&child.getChildSObject().getDescribe().isQueryable()&&!child.isDeprecatedAndHidden())relationships.add(child.getRelationshipName());
            for(Integer i=0;i<relationships.size();i+=15){
                if(Limits.getQueries()>75||Limits.getAggregateQueries()+15>=Limits.getLimitAggregateQueries())throw new HistoryException('Too many related objects to verify safely. Recall a smaller selection or delete these records manually.');
                List<String> columns=new List<String>{'Id'};for(Integer j=i;j<Math.min(i+15,relationships.size());j++)columns.add('(SELECT Id FROM '+relationships[j]+' LIMIT '+(selected.size()+1)+')');
                List<SObject> parents;
                try{parents=Database.queryWithBinds('SELECT '+String.join(columns,',')+' FROM '+name+' WHERE Id IN :parents',new Map<String,Object>{'selected'=>selected,'parents'=>groups.get(name)},AccessLevel.SYSTEM_MODE);}
                catch(Exception e){throw new HistoryException('Salesforce could not verify every related object. Recall field changes separately; delete these records manually.'+(Test.isRunningTest()?' '+e.getMessage():''));}
                for(SObject parent:parents)for(Integer j=i;j<Math.min(i+15,relationships.size());j++)if(parent.getSObjects(relationships[j])!=null)for(SObject child:parent.getSObjects(relationships[j]))if(!selected.contains(child.Id))throw new HistoryException('A selected record has related records outside this Recall selection. Include its newly created children or leave it in Salesforce.');
            }
        }
    }
    public static Object recall(Id id,Map<String,Object> body){
        OrgLoomNativeAccess.requireCapability('recall-upload');Savepoint checkpoint=Database.setSavepoint();
        try{
            OrgLoomNativeAttempt__c journal=owned(id);String requestDigest=OrgLoomNativeUpload.fingerprint(body);
            if(journal.RecallResult__c!=null){Map<String,Object> last=(Map<String,Object>)JSON.deserializeUntyped(journal.RecallResult__c);if(last.get('requestDigest')==requestDigest)return last.get('response');}
            List<Object> records=(List<Object>)snapshot(journal).get('records');Map<Id,SObject> found=current(records,true);
            if(body.get('nativeReviewToken')!=token(id,found))throw new HistoryException('This Recall review is no longer current. No Salesforce records were changed. Open Upload History, select this upload, and start Recall again to review the latest values.');
            Map<String,Object> completed=completion(journal);Set<Id> skip=idSet(body.get('skipSfIds')),force=idSet(body.get('forceDeleteSfIds')),deleting=new Set<Id>();
            Map<String,Map<String,Object>> history=new Map<String,Map<String,Object>>();for(Object raw:records){Map<String,Object> r=(Map<String,Object>)raw;history.put((String)r.get('sfId'),r);}
            for(Id forced:force)if(!history.containsKey(forced)||history.get(forced).get('mode')!='create')throw new HistoryException('Invalid deletion selection.');
            for(Object raw:records){Map<String,Object> record=(Map<String,Object>)raw;Id sfId=(Id)(String)record.get('sfId');if(record.get('mode')!='create'||skip.contains(sfId)||completed.containsKey(String.valueOf(sfId)))continue;
                SObject live=found.get(sfId);if(live==null)continue;
                Boolean drift=creationChanged(record,live);
                if(drift&&!force.contains(sfId))throw new HistoryException('A created record changed after upload. Review and explicitly select its deletion.');
                deleting.add(sfId);
            }
            Integer forcedFieldCount=0;Map<Id,SObject> patches=new Map<Id,SObject>();Set<String> selectedFields=new Set<String>();
            for(String selection:new List<String>{'revertSelections','forceRevertSelections'})if(body.get(selection)!=null)for(Object raw:(List<Object>)body.get(selection)){
                Map<String,Object> chosen=(Map<String,Object>)raw;Id sfId=(Id)(String)chosen.get('sfId');Map<String,Object> record=history.get(sfId);
                if(record==null||record.get('mode')!='update'||!found.containsKey(sfId))throw new HistoryException('Invalid or unavailable update selection.');
                Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo((String)record.get('objectName'));
                for(Object fieldRaw:(List<Object>)chosen.get('fields')){
                    Boolean forced=selection=='forceRevertSelections';Map<String,Object> forceField=forced?(Map<String,Object>)fieldRaw:null;String field=forced?(String)forceField.get('fieldName'):(String)fieldRaw,key=sfId+':'+field;
                    Map<String,Object> before=(Map<String,Object>)record.get('before'),after=(Map<String,Object>)record.get('after');Schema.SObjectField fieldToken=d.fields.getMap().get(field);
                    if(OrgLoomNativeEncrypted.isField((String)record.get('objectName'),field)||!before.containsKey(field)||!selectedFields.add(key)||completed.containsKey(key)||fieldToken==null||!OrgLoomNativeController.supported(fieldToken.getDescribe())||!fieldToken.getDescribe().isUpdateable())throw new HistoryException('A selected field is unavailable for Recall.');
                    Schema.DescribeFieldResult f=fieldToken.getDescribe();Object live=found.get(sfId).get(field),expected=OrgLoomNativeController.convert(forced?forceField.get('expectedCurrent'):after.get(field),f);
                    if(f.getType()==Schema.DisplayType.DATETIME?!sameFieldValue(live,expected,f):live!=expected)throw new HistoryException('A field changed since review. Review it again before overriding.');
                    if(forced)forcedFieldCount++;
                    if(!patches.containsKey(sfId))patches.put(sfId,d.getSObjectType().newSObject(sfId));patches.get(sfId).put(field,OrgLoomNativeController.convert(before.get(field),f));
                }
            }
            if(deleting.isEmpty()&&patches.isEmpty())throw new HistoryException('Select at least one eligible record or field.');
            if(!deleting.isEmpty())checkDependents(deleting,found);
            Map<String,List<SObject>> updates=new Map<String,List<SObject>>();for(SObject patch:patches.values()){String name=patch.getSObjectType().getDescribe().getName();if(!updates.containsKey(name))updates.put(name,new List<SObject>());updates.get(name).add(patch);}
            for(String name:updates.keySet())Database.update(updates.get(name),true,AccessLevel.USER_MODE);
            List<Object> results=new List<Object>();Set<Id> pending=new Set<Id>(deleting);
            while(!pending.isEmpty()){
                Set<Id> parents=new Set<Id>();for(Id sfId:pending){SObject live=found.get(sfId);for(Schema.SObjectField field:live.getSObjectType().getDescribe().fields.getMap().values()){Schema.DescribeFieldResult f=field.getDescribe();if(f.getType()==Schema.DisplayType.REFERENCE&&OrgLoomNativeController.supported(f)){Id target=(Id)live.get(f.getName());if(target!=sfId&&pending.contains(target))parents.add(target);}}}
                Map<String,List<SObject>> batches=new Map<String,List<SObject>>();Set<Id> leaves=new Set<Id>();for(Id sfId:pending)if(!parents.contains(sfId)){String name=sfId.getSObjectType().getDescribe().getName();if(!batches.containsKey(name))batches.put(name,new List<SObject>());batches.get(name).add(sfId.getSObjectType().newSObject(sfId));leaves.add(sfId);}
                if(leaves.isEmpty())throw new HistoryException('Break the relationship cycle before recalling these creations.');
                for(String name:batches.keySet())Database.delete(batches.get(name),true,AccessLevel.USER_MODE);
                for(Id sfId:leaves){completed.put(sfId,true);results.add(new Map<String,Object>{'sfId'=>sfId,'success'=>true});}pending.removeAll(leaves);
            }
            for(String key:selectedFields)completed.put(key,true);
            Boolean remaining=false;for(Map<String,Object> r:history.values())if(r.get('mode')=='create'){if(!completed.containsKey((String)r.get('sfId')))remaining=true;}else for(String field:((Map<String,Object>)r.get('before')).keySet())if(!completed.containsKey(r.get('sfId')+':'+field))remaining=true;
            List<Object> reverted=new List<Object>();for(Id sfId:patches.keySet())reverted.add(new Map<String,Object>{'sfId'=>sfId,'success'=>true,'fields'=>new List<String>(patches.get(sfId).getPopulatedFieldsAsMap().keySet())});
            String status=remaining?'recall_partial':'recalled';Map<String,Object> response=new Map<String,Object>{'results'=>results,'revertResults'=>reverted,'revertedFieldCount'=>selectedFields.size(),'forcedRevertedFieldCount'=>forcedFieldCount,'revertedRecordCount'=>patches.size(),'status'=>status};
            journal.RecallResult__c=JSON.serialize(new Map<String,Object>{'status'=>status,'completed'=>completed,'requestDigest'=>requestDigest,'response'=>response});update journal;
            OrgLoomNativeActivity.record('recall',remaining?'partial':'success',journal.Id,results.size()+' created records removed; '+patches.size()+' records reverted; '+selectedFields.size()+' fields restored.');
            return response;
        }catch(Exception e){Database.rollback(checkpoint);throw e;}
    }
}
