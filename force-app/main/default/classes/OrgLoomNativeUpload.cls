// Native difference: bounded, atomic user-mode DML rather than REST Composite Graph.
// No partial commit. Attempt receipts and business writes commit in the same transaction.
public with sharing class OrgLoomNativeUpload {
    public class UploadException extends Exception {}
    public static final Integer RECORD_LIMIT=200;
    public static Map<String,Object> lastErrors=new Map<String,Object>();
    private static List<String> dmlTemps=new List<String>();
    private static Database.DMLOptions options(Boolean allowDuplicates) {
        Database.DMLOptions result=new Database.DMLOptions();result.optAllOrNone=true;
        result.DuplicateRuleHeader.allowSave=allowDuplicates;
        result.DuplicateRuleHeader.runAsCurrentUser=true;
        return result;
    }
    // Stable across JSON property order and a renewed editing lease. The lease is
    // still checked on every write; it is not part of the business operation.
    private static String canonical(Object value) {
        if(value instanceof Map<String,Object>){Map<String,Object> m=(Map<String,Object>)value;List<String> names=new List<String>(m.keySet());names.sort();List<String> parts=new List<String>();for(String name:names)parts.add(JSON.serialize(name)+':'+canonical(m.get(name)));return '{'+String.join(parts,',')+'}';}
        if(value instanceof List<Object>){List<String> parts=new List<String>();for(Object item:(List<Object>)value)parts.add(canonical(item));return '['+String.join(parts,',')+']';}
        return JSON.serialize(value);
    }
    public static String fingerprint(Map<String,Object> body) {
        Map<String,Object> content=new Map<String,Object>(body);content.remove('nativeSessionToken');
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256',Blob.valueOf(canonical(content))));
    }
    private static void budget(Integer reserveQueries) {
        if(Limits.getQueries()+reserveQueries>=Limits.getLimitQueries() || Limits.getDmlStatements()+5>=Limits.getLimitDmlStatements() || Limits.getCpuTime()>Limits.getLimitCpuTime()*0.8)
            throw new UploadException('This upload approaches Salesforce transaction limits. Reduce the selected records or relationship depth. No changes were committed.');
    }
    private static String key(String attempt) {
        if(attempt==null || !Pattern.matches('[A-Za-z0-9_-]{10,80}',attempt))throw new UploadException('A valid upload attempt ID is required.');
        return UserInfo.getUserId()+':'+attempt;
    }
    public static Object receipt(String attempt) {
        OrgLoomNativeAccess.requireCapability('upload-records');
        String k=key(attempt);
        List<OrgLoomNativeAttempt__c> rows=[SELECT Results__c FROM OrgLoomNativeAttempt__c WHERE Key__c=:k AND OwnerId=:UserInfo.getUserId() LIMIT 1];
        if(rows.isEmpty())return new Map<String,Object>{'status'=>'unconfirmed','results'=>new List<Object>(),'retryableTempIds'=>new List<Object>()};
        Map<String,Object> result=(Map<String,Object>)JSON.deserializeUntyped(rows[0].Results__c);
        if(result.get('status')=='planned')return OrgLoomNativeUploadPlan.receipt(result);
        result.put('canonicalValues',hydrate((List<Object>)result.get('results')));return result;
    }
    private static Map<String,Object> hydrate(List<Object> results) {
        Map<String,Object> canonical=new Map<String,Object>();Map<String,Set<Id>> groups=new Map<String,Set<Id>>();
        for(Object raw:results){Map<String,Object> r=(Map<String,Object>)raw;if(r.get('success')!=true||r.get('id')==null)continue;String name=(String)r.get('objectName');if(!groups.containsKey(name))groups.put(name,new Set<Id>());groups.get(name).add((Id)(String)r.get('id'));}
        Map<Id,SObject> found=new Map<Id,SObject>();for(String name:groups.keySet())found.putAll(OrgLoomNativeController.read(name,groups.get(name),false));
        for(Object raw:results){Map<String,Object> r=(Map<String,Object>)raw;if(r.get('success')!=true||r.get('id')==null)continue;Id id=(Id)(String)r.get('id');if(found.containsKey(id))canonical.put(String.valueOf(r.get('tempId')),found.get(id));}
        return canonical;
    }
    private static void baseline(Map<String,Object> row,SObject current) {
        Map<String,Object> original=(Map<String,Object>)row.get('loadedValues');
        if(original==null || original.get('LastModifiedDate')==null || (Datetime)JSON.deserialize(JSON.serialize(original.get('LastModifiedDate')),Datetime.class)!=(Datetime)current.get('LastModifiedDate'))throw new UploadException('A record changed or has no baseline. Reload it before uploading.');
    }
    public static Object execute(Map<String,Object> body) {
        OrgLoomNativeAccess.requireCapability('upload-records');
        if((String)body.get('expectedSfOrgId')!=UserInfo.getOrganizationId())throw new UploadException('The Salesforce org changed.');
        if(body.get('canvasId')!=null)OrgLoomNativeCanvases.requireSession((Id)(String)body.get('canvasId'),(String)body.get('nativeSessionToken'),true);
        lastErrors.clear();dmlTemps.clear();Boolean allowDuplicates=body.get('allowDuplicates')==true;
        String attempt=(String)body.get('attemptId'),k=key(attempt);
        String digest=fingerprint(body);
        List<OrgLoomNativeAttempt__c> previous=[SELECT Digest__c FROM OrgLoomNativeAttempt__c WHERE Key__c=:k AND OwnerId=:UserInfo.getUserId() LIMIT 1];
        if(!previous.isEmpty()){if(previous[0].Digest__c!=digest)throw new UploadException('This attempt ID was already used for different changes.');return receipt(attempt);}
        OrgLoomNativeUpsert.verify(body);
        Savepoint checkpoint=Database.setSavepoint();
        try {
            OrgLoomNativeAttempt__c journal=new OrgLoomNativeAttempt__c(Key__c=k,Digest__c=digest);insert journal;
            List<Object> rawRecords=(List<Object>)body.get('records'),deletes=(List<Object>)body.get('deletes');
            if(rawRecords==null)rawRecords=new List<Object>();if(deletes==null)deletes=new List<Object>();
            if(rawRecords.size()+deletes.size()>RECORD_LIMIT || rawRecords.isEmpty()&&deletes.isEmpty())throw new UploadException('Select between 1 and '+RECORD_LIMIT+' records for an atomic native upload.');
            Set<String> skipped=new Set<String>();if(body.get('skipTempIds')!=null)for(Object v:(List<Object>)body.get('skipTempIds'))skipped.add(String.valueOf(v));
            Map<String,Map<String,Object>> pending=new Map<String,Map<String,Object>>();Map<String,Id> ids=new Map<String,Id>();Set<Id> uniqueIds=new Set<Id>();
            List<Object> results=new List<Object>(),deleted=new List<Object>();
            Map<String,Schema.DescribeSObjectResult> descriptions=new Map<String,Schema.DescribeSObjectResult>();
            Map<String,Set<Id>> readGroups=new Map<String,Set<Id>>();Map<Id,SObject> originals=new Map<Id,SObject>();
            Set<String> allTemps=new Set<String>();Map<String,Map<String,Object>> allRows=new Map<String,Map<String,Object>>();
            List<Object> everyRow=new List<Object>();everyRow.addAll(rawRecords);everyRow.addAll(deletes);
            for(Object raw:everyRow){
                Map<String,Object> r=(Map<String,Object>)raw;String t=String.valueOf(r.get('tempId')),name=(String)r.get('objectName');
                if(r.get('tempId')==null||!allTemps.add(t))throw new UploadException('Duplicate or missing canvas record identity.');
                Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo(name);descriptions.put(name,d);allRows.put(t,r);
                Object rawId=r.get('sfId')!=null?r.get('sfId'):r.get('loadedFromId');
                if(rawId!=null){Id id=(Id)String.valueOf(rawId);if(id.getSObjectType()!=d.getSObjectType()||!uniqueIds.add(id))throw new UploadException('Invalid record/object identity or duplicate Salesforce record.');ids.put(t,id);if(!readGroups.containsKey(name))readGroups.put(name,new Set<Id>());readGroups.get(name).add(id);}
            }
            if(descriptions.size()>20)throw new UploadException('Select no more than 20 object types per upload.');
            for(String name:readGroups.keySet()){budget(descriptions.size()+2);originals.putAll(OrgLoomNativeController.read(name,readGroups.get(name),true));}
            if(originals.size()!=uniqueIds.size())throw new UploadException('A selected record is unavailable. Reload before uploading.');
            for(Object raw:rawRecords){Map<String,Object> r=(Map<String,Object>)raw;String t=String.valueOf(r.get('tempId'));if(skipped.contains(t)){if(!ids.containsKey(t))throw new UploadException('A skipped draft cannot supply a relationship.');continue;}pending.put(t,r);if(ids.containsKey(t))baseline(r,originals.get(ids.get(t)));}
            Map<Id,Map<String,Object>> pendingDeletes=new Map<Id,Map<String,Object>>();
            for(Object raw:deletes){Map<String,Object> r=(Map<String,Object>)raw;Id id=ids.get(String.valueOf(r.get('tempId')));if(id==null||!descriptions.get((String)r.get('objectName')).isDeletable())throw new UploadException('Invalid or unauthorized deletion.');baseline(r,originals.get(id));pendingDeletes.put(id,r);}
            List<Object> links=body.get('associations')==null?new List<Object>():(List<Object>)body.get('associations');
            if(links.size()>2000)throw new UploadException('Too many relationships in one upload.');
            // Child fromId contains the reference field pointing to parent toId.
            Map<String,Map<String,String>> references=new Map<String,Map<String,String>>();
            for(Object raw:links){
                Map<String,Object> link=(Map<String,Object>)raw;String source=String.valueOf(link.get('fromId')),target=String.valueOf(link.get('toId')),field=(String)link.get('fieldName');
                if(!allRows.containsKey(source)||!allRows.containsKey(target)||pendingDeletes.containsKey(ids.get(source))||pendingDeletes.containsKey(ids.get(target)))throw new UploadException('Include both ends of each relationship in the upload, without deleting either end.');
                Schema.DescribeSObjectResult d=descriptions.get((String)allRows.get(source).get('objectName'));Schema.SObjectField token=d.fields.getMap().get(field);
                if(token==null)throw new UploadException('Invalid relationship field.');Schema.DescribeFieldResult f=token.getDescribe();
                if(f.getType()!=Schema.DisplayType.REFERENCE||!OrgLoomNativeController.supported(f)||!f.getReferenceTo().contains(descriptions.get((String)allRows.get(target).get('objectName')).getSObjectType()))throw new UploadException('Invalid relationship target.');
                Boolean unchanged=ids.containsKey(source)&&ids.containsKey(target)&&originals.get(ids.get(source)).get(field)==ids.get(target);
                if(!skipped.contains(source)&&!unchanged&&!(ids.containsKey(source)?f.isUpdateable():f.isCreateable()))throw new UploadException('No permission to write '+field+'.');
                if(!references.containsKey(source))references.put(source,new Map<String,String>());
                if(references.get(source).containsKey(field))throw new UploadException('A relationship field has more than one target.');references.get(source).put(field,target);
            }
            Map<String,Map<String,String>> deferred=new Map<String,Map<String,String>>();Integer depth=0;
            while(!pending.isEmpty()) {
                budget(descriptions.size()+2);if(++depth>30)throw new UploadException('The relationship graph is too deep for one native transaction.');
                List<String> readyTemps=new List<String>();
                // Prefer complete parents before children so validation rules and
                // automation see relationships on the initial insert.
                for(String t:pending.keySet()){
                    Boolean ready=true;
                    if(references.containsKey(t))for(String field:references.get(t).keySet())if(!ids.containsKey(references.get(t).get(field)))ready=false;
                    if(ready)readyTemps.add(t);
                }
                // Only a stalled cycle uses a second update for nullable references.
                if(readyTemps.isEmpty())for(String t:pending.keySet()){
                    Boolean ready=true;Schema.DescribeSObjectResult d=descriptions.get((String)pending.get(t).get('objectName'));
                    if(references.containsKey(t))for(String field:references.get(t).keySet())if(!ids.containsKey(references.get(t).get(field))&&!d.fields.getMap().get(field).getDescribe().isNillable())ready=false;
                    if(ready)readyTemps.add(t);
                }
                if(readyTemps.isEmpty())throw new UploadException('Break the cycle between required references before uploading.');
                Map<String,List<SObject>> inserts=new Map<String,List<SObject>>(),updates=new Map<String,List<SObject>>();Map<String,List<String>> insertTemps=new Map<String,List<String>>(),updateTemps=new Map<String,List<String>>();
                Map<String,Schema.SObjectField> upsertFields=new Map<String,Schema.SObjectField>();
                Map<String,String> modes=new Map<String,String>();
                for(String t:readyTemps) {
                    Map<String,Object> row=pending.get(t);
                    String name=(String)row.get('objectName');Schema.DescribeSObjectResult d=descriptions.get(name);
                    Boolean creating=row.get('loadedFromId')==null;
                    if(row.get('_csvOperation')=='update'&&creating)throw new UploadException('An update requires an existing Salesforce record ID.');
                    if(row.get('_csvOperation')!=null&&!new Set<String>{'insert','create','update','upsert'}.contains((String)row.get('_csvOperation')))throw new UploadException('Unsupported record operation.');
                    if(creating&&!d.isCreateable() || !creating&&!d.isUpdateable())throw new UploadException('No permission to write '+name+'.');
                    Id id=ids.get(t);SObject current;
                    if(!creating)current=originals.get(id);
                    Map<String,Object> values=new Map<String,Object>((Map<String,Object>)row.get('values'));
                    if(references.containsKey(t))for(String field:references.get(t).keySet()){
                        String target=references.get(t).get(field);if(ids.containsKey(target))values.put(field,ids.get(target));
                        else{if(!d.fields.getMap().get(field).getDescribe().isUpdateable())throw new UploadException('No permission to complete deferred relationship '+field+'.');values.remove(field);if(!deferred.containsKey(t))deferred.put(t,new Map<String,String>());deferred.get(t).put(field,target);}
                    }
                    SObject patch=d.getSObjectType().newSObject(id);Integer changed=0;
                    for(String field:values.keySet()) {
                        if(field=='attributes')continue;
                        Schema.SObjectField token=d.fields.getMap().get(field);if(token==null||!OrgLoomNativeController.supported(token.getDescribe()))throw new UploadException('Unavailable field: '+field);
                        Schema.DescribeFieldResult f=token.getDescribe();Object value=OrgLoomNativeController.convert(values.get(field),f);
                        // Never write a loaded/masked encrypted value back by accident.
                        if(OrgLoomNativeEncrypted.isField(name,field)&&!OrgLoomNativeEncrypted.explicit(row,field))throw new UploadException('Choose Replace or Clear for encrypted field '+f.getLabel()+' before uploading.');
                        if(!creating&&value==current.get(field))continue;
                        if(creating&&value==null)continue;
                        if(f.isCalculated()||f.isAutoNumber()||!(creating?f.isCreateable():f.isUpdateable()))throw new UploadException('No permission to write '+field+'.');
                        patch.put(field,value);changed++;
                    }
                    if(creating){
                        String batchKey=name;
                        if(row.get('_csvOperation')=='upsert'){
                            if(allowDuplicates)throw new UploadException('Duplicate overrides for new external-ID upserts are not supported by the native DML path. Resolve the duplicate or import this record as an insert.');
                            Schema.SObjectField externalField=OrgLoomNativeUpsert.field(row);batchKey+=':'+externalField.getDescribe().getName();upsertFields.put(batchKey,externalField);
                        }
                        if(!inserts.containsKey(batchKey)){inserts.put(batchKey,new List<SObject>());insertTemps.put(batchKey,new List<String>());}inserts.get(batchKey).add(patch);insertTemps.get(batchKey).add(t);
                    }
                    else if(changed>0){if(!updates.containsKey(name)){updates.put(name,new List<SObject>());updateTemps.put(name,new List<String>());}updates.get(name).add(patch);updateTemps.get(name).add(t);}
                    modes.put(t,creating?'create':changed==0&&!deferred.containsKey(t)?'unchanged':'update');
                }
                for(String name:inserts.keySet()){
                    budget(descriptions.size()+2);List<SObject> batch=inserts.get(name);dmlTemps=insertTemps.get(name);
                    if(upsertFields.containsKey(name)){
                        Database.UpsertResult[] outcomes=Database.upsert(batch,upsertFields.get(name),true,AccessLevel.USER_MODE);
                        for(Database.UpsertResult outcome:outcomes)if(!outcome.isCreated())throw new UploadException('An external ID matched a record after planning. This batch was rolled back. Review a new upload.');
                    }else Database.insert(batch,options(allowDuplicates),AccessLevel.USER_MODE);
                    for(Integer i=0;i<batch.size();i++)ids.put(insertTemps.get(name)[i],(Id)batch[i].get('Id'));
                }
                for(String name:updates.keySet()){budget(descriptions.size()+2);dmlTemps=updateTemps.get(name);Database.update(updates.get(name),options(allowDuplicates),AccessLevel.USER_MODE);}
                for(String t:readyTemps){Map<String,Object> row=pending.remove(t);results.add(new Map<String,Object>{'tempId'=>row.get('tempId'),'objectName'=>row.get('objectName'),'mode'=>modes.get(t),'id'=>ids.get(t),'success'=>true});}
            }
            Map<String,List<SObject>> deferredBatches=new Map<String,List<SObject>>();
            for(String t:deferred.keySet()){String name=(String)allRows.get(t).get('objectName');SObject patch=descriptions.get(name).getSObjectType().newSObject(ids.get(t));for(String field:deferred.get(t).keySet())patch.put(field,ids.get(deferred.get(t).get(field)));if(!deferredBatches.containsKey(name))deferredBatches.put(name,new List<SObject>());deferredBatches.get(name).add(patch);}
            for(String name:deferredBatches.keySet()){budget(descriptions.size()+2);dmlTemps=new List<String>();for(SObject patch:deferredBatches.get(name))for(String temp:ids.keySet())if(ids.get(temp)==patch.Id)dmlTemps.add(temp);Database.update(deferredBatches.get(name),options(allowDuplicates),AccessLevel.USER_MODE);}
            // Delete selected children before selected parents, including self-lookups.
            while(!pendingDeletes.isEmpty()){
                budget(descriptions.size()+2);Set<Id> parents=new Set<Id>();
                for(Id id:pendingDeletes.keySet()){SObject old=originals.get(id);for(Schema.SObjectField token:old.getSObjectType().getDescribe().fields.getMap().values()){Schema.DescribeFieldResult f=token.getDescribe();if(f.getType()==Schema.DisplayType.REFERENCE&&OrgLoomNativeController.supported(f)){Id target=(Id)old.get(f.getName());if(target!=id&&pendingDeletes.containsKey(target))parents.add(target);}}}
                Map<String,List<SObject>> batches=new Map<String,List<SObject>>();List<Id> leaves=new List<Id>();
                for(Id id:pendingDeletes.keySet())if(!parents.contains(id)){String name=(String)pendingDeletes.get(id).get('objectName');if(!batches.containsKey(name))batches.put(name,new List<SObject>());batches.get(name).add(descriptions.get(name).getSObjectType().newSObject(id));leaves.add(id);}
                if(leaves.isEmpty())throw new UploadException('Break the cycle between records selected for deletion before uploading.');
                for(String name:batches.keySet()){budget(descriptions.size()+2);dmlTemps=new List<String>();for(SObject patch:batches.get(name))dmlTemps.add(String.valueOf(pendingDeletes.get(patch.Id).get('tempId')));Database.delete(batches.get(name),true,AccessLevel.USER_MODE);}
                for(Id id:leaves){Map<String,Object> row=pendingDeletes.remove(id);deleted.add(new Map<String,Object>{'tempId'=>row.get('tempId'),'objectName'=>row.get('objectName'),'sfId'=>id,'id'=>id,'success'=>true});}
            }
            Map<String,Object> response=new Map<String,Object>{'status'=>'completed','results'=>results,'deletes'=>deleted,'instanceUrl'=>URL.getOrgDomainUrl().toExternalForm()};
            journal.Results__c=JSON.serialize(response);update journal;
            Map<String,Object> canonicalValues=hydrate(results);
            OrgLoomNativeHistory.capture(journal,results,canonicalValues,originals,allRows,references);
            OrgLoomNativeActivity.uploaded(journal.Id,results,deleted);
            response.put('canonicalValues',canonicalValues);return response;
        } catch(Exception e){
            Database.rollback(checkpoint);
            if(e instanceof DmlException){DmlException failure=(DmlException)e;for(Integer i=0;i<failure.getNumDml();i++){
                Integer index=failure.getDmlIndex(i);if(index<0||index>=dmlTemps.size())continue;
                lastErrors.put(dmlTemps[index],new Map<String,Object>{'errorCode'=>String.valueOf(failure.getDmlStatusCode(i)),'message'=>failure.getDmlMessage(i),'fields'=>failure.getDmlFieldNames(i)});
            }}
            throw e;
        }
    }
}

