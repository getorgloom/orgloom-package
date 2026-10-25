// Native difference: a durable manifest coordinates separate remoting transactions.
// Only identifiers and payload digests are stored, never submitted field values.
public with sharing class OrgLoomNativeUploadPlan {
    private static String key(String attempt) {
        if(attempt==null||!Pattern.matches('[A-Za-z0-9_-]{10,80}',attempt))throw new OrgLoomNativeUpload.UploadException('A valid upload attempt ID is required.');
        return UserInfo.getUserId()+':'+attempt;
    }
    private static void authorize(Map<String,Object> body) {
        OrgLoomNativeAccess.requireCapability('upload-records');
        if(body.get('expectedSfOrgId')!=UserInfo.getOrganizationId())throw new OrgLoomNativeUpload.UploadException('The Salesforce org changed.');
        if(body.get('canvasId')!=null)OrgLoomNativeCanvases.requireSession((Id)(String)body.get('canvasId'),(String)body.get('nativeSessionToken'),true);
    }
    private static List<Object> items(Map<String,Object> body,String field){return body.get(field)==null?new List<Object>():(List<Object>)body.get(field);}
    private static void connect(Map<String,Set<String>> edges,String a,String b){if(a!=null&&b!=null){edges.get(a).add(b);edges.get(b).add(a);}}
    public static Object plan(Map<String,Object> body) {
        authorize(body);String attempt=(String)body.get('attemptId'),k=key(attempt),digest=OrgLoomNativeUpload.fingerprint(body);
        List<OrgLoomNativeAttempt__c> old=[SELECT Digest__c,Results__c FROM OrgLoomNativeAttempt__c WHERE Key__c=:k AND OwnerId=:UserInfo.getUserId() LIMIT 1];
        if(!old.isEmpty()&&old[0].Digest__c!=digest)throw new OrgLoomNativeUpload.UploadException('This attempt ID was already used for different changes.');
        if(!old.isEmpty()){
            Map<String,Object> saved=(Map<String,Object>)JSON.deserializeUntyped(old[0].Results__c);
            if(saved.get('status')!='planned')throw new OrgLoomNativeUpload.UploadException('This attempt already has a different receipt.');
            if(saved.get('closed')==true)throw new OrgLoomNativeUpload.UploadException('This upload was closed during recovery. Review a new upload for remaining changes.');
            if(saved.get('upserts')!=null)body=OrgLoomNativeUpsert.restore(body,(Map<String,Object>)saved.get('upserts'));
            // Reconstruct from the persisted manifest, not changed/deleted live
            // records. Replay must work after earlier batches have committed.
            List<Object> resumed=new List<Object>();
            for(Object item:(List<Object>)saved.get('groups')){Map<String,Object> entry=(Map<String,Object>)item;Set<String> members=new Set<String>();for(String kind:new List<String>{'records','deletes'})for(Object raw:(List<Object>)entry.get(kind))members.add(String.valueOf(((Map<String,Object>)raw).get('tempId')));
                Map<String,Object> batchPayload=new Map<String,Object>(body);batchPayload.put('attemptId',entry.get('attemptId'));
                for(String kind:new List<String>{'records','deletes'}){List<Object> selected=new List<Object>();for(Object raw:items(body,kind))if(members.contains(String.valueOf(((Map<String,Object>)raw).get('tempId'))))selected.add(raw);batchPayload.put(kind,selected);}
                List<Object> selectedLinks=new List<Object>();for(Object raw:items(body,'associations'))if(members.contains(String.valueOf(((Map<String,Object>)raw).get('fromId'))))selectedLinks.add(raw);batchPayload.put('associations',selectedLinks);batchPayload.put('skipTempIds',entry.get('skips'));
                if(OrgLoomNativeUpload.fingerprint(batchPayload)!=entry.get('digest'))throw new OrgLoomNativeUpload.UploadException('The planned changes were modified.');resumed.add(batchPayload);
            }
            return new Map<String,Object>{'groups'=>resumed,'recordLimit'=>500,'atomicLimit'=>OrgLoomNativeUpload.RECORD_LIMIT};
        }
        body=OrgLoomNativeUpsert.resolve(body);
        List<Object> records=items(body,'records'),deletes=items(body,'deletes'),links=items(body,'associations');
        List<Object> rows=new List<Object>();rows.addAll(records);rows.addAll(deletes);
        if(rows.isEmpty()||rows.size()>500||links.size()>5000)throw new OrgLoomNativeUpload.UploadException('Select between 1 and 500 records for a native upload.');
        Map<String,Set<String>> edges=new Map<String,Set<String>>();Map<String,Map<String,Object>> byTemp=new Map<String,Map<String,Object>>();Map<Id,String> byId=new Map<Id,String>();
        Map<String,Schema.DescribeSObjectResult> descriptions=new Map<String,Schema.DescribeSObjectResult>();Map<String,Set<Id>> readGroups=new Map<String,Set<Id>>();List<String> order=new List<String>();
        for(Object raw:rows){Map<String,Object> row=(Map<String,Object>)raw;String temp=String.valueOf(row.get('tempId')),name=(String)row.get('objectName');
            if(row.get('tempId')==null||byTemp.containsKey(temp))throw new OrgLoomNativeUpload.UploadException('Duplicate or missing canvas record identity.');
            Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo(name);descriptions.put(name,d);byTemp.put(temp,row);edges.put(temp,new Set<String>());order.add(temp);
            Object rawId=row.get('sfId')!=null?row.get('sfId'):row.get('loadedFromId');
            if(rawId!=null){Id id=(Id)String.valueOf(rawId);if(byId.containsKey(id)||id.getSObjectType()!=d.getSObjectType())throw new OrgLoomNativeUpload.UploadException('Invalid or duplicate Salesforce record identity.');byId.put(id,temp);if(!readGroups.containsKey(name))readGroups.put(name,new Set<Id>());readGroups.get(name).add(id);}
        }
        if(descriptions.size()>20)throw new OrgLoomNativeUpload.UploadException('Select no more than 20 object types per upload.');
        for(Object raw:links){Map<String,Object> link=(Map<String,Object>)raw;String a=String.valueOf(link.get('fromId')),b=String.valueOf(link.get('toId'));if(!edges.containsKey(a)||!edges.containsKey(b))throw new OrgLoomNativeUpload.UploadException('Include both ends of each relationship.');connect(edges,a,b);}
        // Current references and submitted references both constrain grouping. A
        // cleared lookup must stay atomic with deletion of its former parent.
        Map<Id,SObject> current=new Map<Id,SObject>();for(String name:readGroups.keySet())current.putAll(OrgLoomNativeController.read(name,readGroups.get(name),false));
        if(current.size()!=byId.size())throw new OrgLoomNativeUpload.UploadException('A selected record is unavailable.');
        for(String temp:order){Map<String,Object> row=byTemp.get(temp);Map<String,Object> values=row.get('values')==null?new Map<String,Object>():(Map<String,Object>)row.get('values');
            Object rawId=row.get('sfId')!=null?row.get('sfId'):row.get('loadedFromId');SObject before=rawId==null?null:current.get((Id)String.valueOf(rawId));
            for(Schema.SObjectField token:descriptions.get((String)row.get('objectName')).fields.getMap().values()){Schema.DescribeFieldResult f=token.getDescribe();if(f.getType()!=Schema.DisplayType.REFERENCE||!OrgLoomNativeController.supported(f))continue;
                if(before!=null)connect(edges,temp,byId.get((Id)before.get(f.getName())));
                if(values.get(f.getName())!=null){Id target=(Id)String.valueOf(values.get(f.getName()));connect(edges,temp,byId.get(target));}
            }
        }
        List<Set<String>> batches=new List<Set<String>>();Set<String> seen=new Set<String>(),batch=new Set<String>();
        for(String seed:order){if(seen.contains(seed))continue;Set<String> component=new Set<String>();List<String> queue=new List<String>{seed};
            for(Integer i=0;i<queue.size();i++){String t=queue[i];if(!seen.add(t))continue;component.add(t);for(String neighbor:edges.get(t))if(!seen.contains(neighbor))queue.add(neighbor);}
            if(component.size()>OrgLoomNativeUpload.RECORD_LIMIT)throw new OrgLoomNativeUpload.UploadException('A connected group exceeds the native atomic limit of 200 records. Select fewer related records before uploading.');
            if(batch.size()+component.size()>OrgLoomNativeUpload.RECORD_LIMIT){batches.add(batch);batch=new Set<String>();}batch.addAll(component);
        }
        if(!batch.isEmpty())batches.add(batch);
        List<Object> groups=new List<Object>(),manifest=new List<Object>();Integer index=0;
        for(Set<String> members:batches){Map<String,Object> batchPayload=new Map<String,Object>(body);String child='native-'+EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256',Blob.valueOf(attempt+':'+index)));
            batchPayload.put('attemptId',child);List<Object> selected=new List<Object>(),removed=new List<Object>(),relationships=new List<Object>(),skips=new List<Object>(),identities=new List<Object>(),deleteIdentities=new List<Object>();
            for(Object raw:records){Map<String,Object> row=(Map<String,Object>)raw;if(members.contains(String.valueOf(row.get('tempId')))){selected.add(raw);identities.add(new Map<String,Object>{'tempId'=>row.get('tempId'),'objectName'=>row.get('objectName')});}}
            for(Object raw:deletes){Map<String,Object> row=(Map<String,Object>)raw;if(members.contains(String.valueOf(row.get('tempId')))){removed.add(raw);deleteIdentities.add(new Map<String,Object>{'tempId'=>row.get('tempId'),'objectName'=>row.get('objectName'),'sfId'=>row.get('sfId')});}}
            for(Object raw:links)if(members.contains(String.valueOf(((Map<String,Object>)raw).get('fromId'))))relationships.add(raw);
            for(Object raw:items(body,'skipTempIds'))if(members.contains(String.valueOf(raw)))skips.add(raw);
            batchPayload.put('records',selected);batchPayload.put('deletes',removed);batchPayload.put('associations',relationships);batchPayload.put('skipTempIds',skips);
            groups.add(batchPayload);manifest.add(new Map<String,Object>{'attemptId'=>child,'digest'=>OrgLoomNativeUpload.fingerprint(batchPayload),'records'=>identities,'deletes'=>deleteIdentities,'skips'=>skips});index++;
        }
        Map<String,Object> stored=new Map<String,Object>{'status'=>'planned','groups'=>manifest,'upserts'=>OrgLoomNativeUpsert.resolutions(body)};
        if(old.isEmpty())insert new OrgLoomNativeAttempt__c(Key__c=k,Digest__c=digest,Results__c=JSON.serialize(stored));
        else if(old[0].Results__c!=JSON.serialize(stored))throw new OrgLoomNativeUpload.UploadException('The upload plan changed. Check its receipt before starting another attempt.');
        return new Map<String,Object>{'groups'=>groups,'recordLimit'=>500,'atomicLimit'=>OrgLoomNativeUpload.RECORD_LIMIT};
    }
    public static Object execute(Map<String,Object> request) {
        Map<String,Object> body=(Map<String,Object>)request.get('payload');authorize(body);String rootKey=key((String)request.get('rootAttemptId'));
        // Serializes retries and batches belonging to this plan without retaining
        // a lock across browser requests. Every transaction checks the canvas lease.
        List<OrgLoomNativeAttempt__c> roots=[SELECT Results__c FROM OrgLoomNativeAttempt__c WHERE Key__c=:rootKey AND OwnerId=:UserInfo.getUserId() LIMIT 1 FOR UPDATE];
        if(roots.isEmpty())throw new OrgLoomNativeUpload.UploadException('Upload plan unavailable.');
        Map<String,Object> stored=(Map<String,Object>)JSON.deserializeUntyped(roots[0].Results__c);List<Object> groups=(List<Object>)stored.get('groups');Integer index=Integer.valueOf(String.valueOf(request.get('index')));
        if(stored.get('closed')==true)throw new OrgLoomNativeUpload.UploadException('This upload was closed during recovery. No more batches can run.');
        if(groups==null||index<0||index>=groups.size())throw new OrgLoomNativeUpload.UploadException('Invalid upload group.');
        Map<String,Object> batchPayload=(Map<String,Object>)groups[index];String digest=OrgLoomNativeUpload.fingerprint(body);
        if(batchPayload.get('attemptId')!=body.get('attemptId')||batchPayload.get('digest')!=digest)throw new OrgLoomNativeUpload.UploadException('The planned changes were modified. Review a new upload.');
        try{return OrgLoomNativeUpload.execute(body);}
        catch(Exception e){
            // execute rolls back its own savepoint before this failure receipt is
            // written. Keep record values and Salesforce error text out of storage.
            Map<String,Object> failure=new Map<String,Object>{'status'=>'completed','results'=>failures((List<Object>)batchPayload.get('records'),(List<Object>)batchPayload.get('skips')),'deletes'=>failures((List<Object>)batchPayload.get('deletes'),new List<Object>()),'instanceUrl'=>URL.getOrgDomainUrl().toExternalForm()};
            // Preserve actionable codes for retry/recovery without persisting Salesforce
            // messages, which can contain record values or matching-record details.
            for(String kind:new List<String>{'results','deletes'})for(Object raw:(List<Object>)failure.get(kind)){
                Map<String,Object> row=(Map<String,Object>)raw,details=(Map<String,Object>)OrgLoomNativeUpload.lastErrors.get(String.valueOf(row.get('tempId')));
                if(details!=null){row.put('errorCode',details.get('errorCode'));row.put('fields',details.get('fields'));row.put('error','Salesforce rejected this record. Its atomic batch was rolled back.');}
                else {row.put('errorCode',OrgLoomNativeUpload.lastErrors.isEmpty()?'NATIVE_BATCH_ROLLED_BACK':'ALL_OR_NONE_OPERATION_ROLLED_BACK');row.put('error','This atomic batch was rolled back. None of its changes were saved.');}
            }
            String childKey=key((String)batchPayload.get('attemptId'));List<OrgLoomNativeAttempt__c> existing=[SELECT Id FROM OrgLoomNativeAttempt__c WHERE Key__c=:childKey AND OwnerId=:UserInfo.getUserId() LIMIT 1];
            // Never overwrite a committed receipt if a later hydration read failed.
            if(!existing.isEmpty())throw e;
            OrgLoomNativeAttempt__c failedAttempt=new OrgLoomNativeAttempt__c(Key__c=childKey,Digest__c=digest,Results__c=JSON.serialize(failure));insert failedAttempt;
            OrgLoomNativeActivity.record('upload','failed',failedAttempt.Id,'One batch was rolled back. None of its changes were committed.');
            // Detailed diagnostics go only to the current authorized caller.
            for(String kind:new List<String>{'results','deletes'})for(Object raw:(List<Object>)failure.get(kind)){
                Map<String,Object> row=(Map<String,Object>)raw,details=(Map<String,Object>)OrgLoomNativeUpload.lastErrors.get(String.valueOf(row.get('tempId')));
                String message=details==null?e.getMessage():(String)details.get('message');
                row.put('error',message+' This batch was rolled back.');
                row.put('errors',new List<Object>{new Map<String,Object>{'errorCode'=>row.get('errorCode')==null?'NATIVE_BATCH_ROLLED_BACK':row.get('errorCode'),'message'=>message+' This batch was rolled back.'}});
            }
            return failure;
        }
    }
    private static List<Object> failures(List<Object> rows,List<Object> skips){Set<String> excluded=new Set<String>();for(Object raw:skips)excluded.add(String.valueOf(raw));List<Object> result=new List<Object>();for(Object raw:rows){Map<String,Object> row=new Map<String,Object>((Map<String,Object>)raw);if(excluded.contains(String.valueOf(row.get('tempId'))))continue;row.put('success',false);row.put('errors',new List<Object>{new Map<String,Object>{'errorCode'=>'NATIVE_BATCH_ROLLED_BACK','message'=>'Salesforce rejected this atomic batch. None of its changes were saved.'}});result.add(row);}return result;}
    public static Object recover(String attempt) {
        OrgLoomNativeAccess.requireCapability('upload-records');String rootKey=key(attempt);
        // Serialize against an in-flight group, then seal the plan. Queued late
        // requests cannot execute after this point. Only now is an absent receipt
        // proof that its records can safely be included in a new attempt.
        List<OrgLoomNativeAttempt__c> roots=[SELECT Results__c FROM OrgLoomNativeAttempt__c WHERE Key__c=:rootKey AND OwnerId=:UserInfo.getUserId() LIMIT 1 FOR UPDATE];
        if(roots.isEmpty())return OrgLoomNativeUpload.receipt(attempt);
        Map<String,Object> stored=(Map<String,Object>)JSON.deserializeUntyped(roots[0].Results__c);
        if(stored.get('status')!='planned')return OrgLoomNativeUpload.receipt(attempt);
        stored.put('closed',true);roots[0].Results__c=JSON.serialize(stored);update roots;
        return receipt(stored);
    }
    public static Object receipt(Map<String,Object> plan) {
        List<Object> groups=(List<Object>)plan.get('groups');Set<String> keys=new Set<String>();for(Object raw:groups)keys.add(key((String)((Map<String,Object>)raw).get('attemptId')));
        Map<String,Map<String,Object>> found=new Map<String,Map<String,Object>>();for(OrgLoomNativeAttempt__c row:[SELECT Key__c,Results__c FROM OrgLoomNativeAttempt__c WHERE Key__c IN :keys AND OwnerId=:UserInfo.getUserId()])found.put(row.Key__c,(Map<String,Object>)JSON.deserializeUntyped(row.Results__c));
        List<Object> results=new List<Object>(),deletes=new List<Object>(),retryable=new List<Object>();
        for(Map<String,Object> child:found.values()){for(Object raw:(List<Object>)child.get('results')){Map<String,Object> row=(Map<String,Object>)raw;results.add(row);if(row.get('success')!=true)retryable.add(row.get('tempId'));}deletes.addAll((List<Object>)child.get('deletes'));}
        if(plan.get('closed')==true)for(Object raw:groups){Map<String,Object> entry=(Map<String,Object>)raw;if(found.containsKey(key((String)entry.get('attemptId'))))continue;
            List<Object> absent=failures((List<Object>)entry.get('records'),(List<Object>)entry.get('skips')),absentDeletes=failures((List<Object>)entry.get('deletes'),new List<Object>());
            for(Object row:absent)retryable.add(((Map<String,Object>)row).get('tempId'));results.addAll(absent);deletes.addAll(absentDeletes);
            List<Object> absentRows=new List<Object>();absentRows.addAll(absent);absentRows.addAll(absentDeletes);
            for(Object row:absentRows)((Map<String,Object>)row).put('errors',new List<Object>{new Map<String,Object>{'errorCode'=>'NATIVE_BATCH_NOT_COMMITTED','message'=>'This batch did not commit and its upload plan is closed. Review a new upload to retry these changes.'}});
        }
        return new Map<String,Object>{'status'=>plan.get('closed')==true||found.size()==keys.size()?'completed':'unconfirmed','results'=>results,'deletes'=>deletes,'retryableTempIds'=>retryable,'instanceUrl'=>URL.getOrgDomainUrl().toExternalForm()};
    }
}
