// Native difference: no live shared state. Project the encrypted revision for the
// current user, then merge only that user's visible edits under the canvas lease.
public with sharing class OrgLoomNativeProjection {
    public class View {
        public Map<String,Object> payload;
        public Boolean partial=false;
        public Map<String,Set<String>> frozen=new Map<String,Set<String>>();
    }
    private static final Set<String> ROW_KEYS=new Set<String>{'loadedFromId','tempId','canvasRecordId','objectName','x','y','values','changes','originalValues','slot','pendingDelete','uploadRecovery','encryptedFieldIntents'};
    private static Map<String,Object> asMap(Object value){return value==null?new Map<String,Object>():(Map<String,Object>)value;}
    private static List<Object> items(Object value){return value==null?new List<Object>():(List<Object>)value;}
    public static Map<String,Object> copy(Map<String,Object> value){return (Map<String,Object>)JSON.deserializeUntyped(JSON.serialize(value));}
    private static String hash(Object value){return OrgLoomNativeUpload.fingerprint(new Map<String,Object>{'value'=>value});}
    private static Map<String,Object> only(Map<String,Object> value,Set<String> keys){Map<String,Object> out=new Map<String,Object>();for(String key:keys)if(value.containsKey(key))out.put(key,value.get(key));return out;}
    public static String identity(Map<String,Object> row){
        if(row.get('loadedFromId')!=null)return 'loaded:'+row.get('loadedFromId');
        if(row.get('tempId')!=null)return 'draft:'+row.get('tempId');
        if(asMap(row.get('slot')).get('slotId')!=null)return 'slot:'+asMap(row.get('slot')).get('slotId');
        throw new OrgLoomNativeCanvases.CanvasException('A canvas record has no identity.');
    }
    private static Map<String,Map<String,Object>> rows(Map<String,Object> payload){
        Map<String,Map<String,Object>> out=new Map<String,Map<String,Object>>();
        for(String key:new List<String>{'loadedRecords','drafts'})for(Object raw:items(payload.get(key))){Map<String,Object> row=asMap(raw);String id=identity(row);if(out.containsKey(id))fail();out.put(id,row);}
        return out;
    }
    private static Schema.DescribeSObjectResult describe(String name){
        Schema.SObjectType token=OrgLoomNativeController.globalObjects().get(name);
        return token!=null&&OrgLoomNativeController.available(token.getDescribe())?token.getDescribe():null;
    }
    private static Schema.DescribeFieldResult field(String name,String fieldName){
        Schema.DescribeSObjectResult d=describe(name);Schema.SObjectField token=d==null?null:d.fields.getMap().get(fieldName);
        return token!=null&&OrgLoomNativeController.supported(token.getDescribe())?token.getDescribe():null;
    }
    private static Id recordId(Object value){try{return value==null?null:Id.valueOf(String.valueOf(value));}catch(Exception ignored){return null;}}
    private static void collect(Map<String,Set<Id>> grouped,Object value){
        Id id=recordId(value);if(id==null)return;String name=id.getSObjectType().getDescribe().getName();
        if(describe(name)==null)return;if(!grouped.containsKey(name))grouped.put(name,new Set<Id>());grouped.get(name).add(id);
    }
    private static Set<Id> readable(Map<String,Object> payload){
        Map<String,Set<Id>> grouped=new Map<String,Set<Id>>();
        for(Map<String,Object> row:rows(payload).values()){
            collect(grouped,row.get('loadedFromId'));String name=(String)row.get('objectName');
            for(String key:new List<String>{'values','changes','originalValues'})for(String f:asMap(row.get(key)).keySet()){
                Schema.DescribeFieldResult d=field(name,f);if(d!=null&&d.getType()==Schema.DisplayType.REFERENCE)collect(grouped,asMap(row.get(key)).get(f));
            }
        }
        for(Object raw:items(asMap(payload.get('schema')).get('objects'))){Map<String,Object> obj=asMap(raw);
            for(String key:new List<String>{'fields','draftFields'})for(Object fraw:items(obj.get(key))){Map<String,Object> f=asMap(fraw);Schema.DescribeFieldResult d=field((String)obj.get('name'),(String)f.get('name'));if(d!=null&&d.getType()==Schema.DisplayType.REFERENCE)collect(grouped,f.get('defaultValue'));}
        }
        if(grouped.size()>20)throw new OrgLoomNativeCanvases.CanvasException('Saved canvases support at most 20 referenced object types.');
        Set<Id> allowed=new Set<Id>();
        for(String name:grouped.keySet()){
            try{for(SObject row:Database.queryWithBinds('SELECT Id FROM '+name+' WHERE Id IN :ids',new Map<String,Object>{'ids'=>grouped.get(name)},AccessLevel.USER_MODE))allowed.add(row.Id);}
            catch(QueryException ignored){/* Unsupported or revoked access: fail closed for that object. */}
        }
        return allowed;
    }
    private static Boolean valueAllowed(String name,String f,Object value,Set<Id> allowed){
        Schema.DescribeFieldResult d=field(name,f);if(d==null)return false;
        if(d.getType()!=Schema.DisplayType.REFERENCE||value==null||value=='')return true;
        Id id=recordId(value);return id!=null&&d.getReferenceTo().contains(id.getSObjectType())&&allowed.contains(id);
    }
    private static String endpoint(Object raw){Map<String,Object> e=asMap(raw);return e.get('kind')+':'+e.get('ref');}
    private static Map<String,String> aliases(Map<String,Map<String,Object>> source){
        Map<String,String> result=new Map<String,String>();for(String key:source.keySet()){
            result.put(key,key);Object slot=asMap(source.get(key).get('slot')).get('slotId');if(slot!=null){String slotKey='slot:'+slot;if(result.containsKey(slotKey)&&result.get(slotKey)!=key)fail();result.put(slotKey,key);}
        }return result;
    }
    public static View project(Map<String,Object> source){
        View view=new View();Map<String,Object> full=copy(source);Set<Id> allowed=readable(full);
        view.payload=only(full,new Set<String>{'_meta','schema','loadedRecords','drafts','associations'});
        view.payload.put('_meta',only(asMap(full.get('_meta')),new Set<String>{'app','version','savedFrom','savedBy','savedByName'}));
        Map<String,Map<String,Object>> originals=rows(full),visible=new Map<String,Map<String,Object>>();
        // Reserve request identifiers without returning hidden request contents.
        // The pinned client otherwise advances its counter from visible slots only.
        Decimal nextSlot=1;
        for(Map<String,Object> row:originals.values())if(asMap(row.get('slot')).get('slotId')!=null){
            Decimal slot=Decimal.valueOf(String.valueOf(asMap(row.get('slot')).get('slotId')));nextSlot=Math.max(nextSlot,slot+1);
        }
        asMap(view.payload.get('_meta')).put('nativeNextSlotId',nextSlot);
        for(String key:new List<String>{'loadedRecords','drafts'}){
            List<Object> result=new List<Object>();
            for(Object raw:items(full.get(key))){Map<String,Object> row=asMap(raw);String id=identity(row),name=(String)row.get('objectName');
                if(describe(name)==null||(row.get('loadedFromId')!=null&&!allowed.contains(recordId(row.get('loadedFromId'))))){view.partial=true;continue;}
                Map<String,Object> next=only(row,ROW_KEYS);view.frozen.put(id,new Set<String>());
                for(String valueKey:new List<String>{'values','changes','originalValues'})if(row.containsKey(valueKey)){
                    Map<String,Object> values=new Map<String,Object>();
                    for(String f:asMap(row.get(valueKey)).keySet())if(valueAllowed(name,f,asMap(row.get(valueKey)).get(f),allowed))values.put(f,asMap(row.get(valueKey)).get(f));else{view.partial=true;view.frozen.get(id).add(f);}
                    next.put(valueKey,values);
                }
                // Unsupported encrypted field intents must not reveal field names.
                if(next.containsKey('encryptedFieldIntents')){List<Object> fs=new List<Object>();for(Object f:items(next.get('encryptedFieldIntents')))if(field(name,(String)f)!=null)fs.add(f);else view.partial=true;next.put('encryptedFieldIntents',fs);}
                result.add(next);visible.put(id,next);
            }view.payload.put(key,result);
        }
        Map<String,String> allAliases=aliases(originals),visibleAliases=aliases(visible);List<Object> links=new List<Object>();
        for(Object raw:items(full.get('associations'))){Map<String,Object> link=asMap(raw);String sourceKey=visibleAliases.get(endpoint(link.get('from'))),targetKey=visibleAliases.get(endpoint(link.get('to')));String f=(String)link.get('fieldName');
            if(sourceKey!=null&&targetKey!=null&&field((String)visible.get(sourceKey).get('objectName'),f)!=null)links.add(only(link,new Set<String>{'from','to','fieldName'}));
            else{view.partial=true;if(sourceKey!=null)view.frozen.get(sourceKey).add(f);}
        }view.payload.put('associations',links);
        for(String id:visible.keySet()){
            Map<String,Object> next=visible.get(id);String name=(String)next.get('objectName');
            for(String key:new List<String>{'values','changes','originalValues'})for(String f:view.frozen.get(id))asMap(next.get(key)).remove(f);
            if(next.get('slot')!=null){Map<String,Object> slot=only(asMap(next.get('slot')),new Set<String>{'slotId','kind','fields','assigneeSfUserId','assigneeName','assigneeEmail','createdAt','origin','description','instructions','label','createdBySfUserId','unavailableFieldCount'});
                if(slot.get('kind')=='fields'){
                    List<Object> fs=new List<Object>();for(Object f:items(slot.get('fields')))if(field(name,(String)f)!=null&&!view.frozen.get(id).contains((String)f))fs.add(f);
                    if(fs.size()!=items(slot.get('fields')).size()){view.partial=true;slot.remove('instructions');slot.remove('description');slot.remove('label');}
                    slot.put('fields',fs);if(fs.isEmpty())next.remove('slot');else next.put('slot',slot);
                }else next.put('slot',slot);
            }
        }
        // Filtering an entire field request can remove a slot endpoint.
        visibleAliases=aliases(visible);List<Object> validLinks=new List<Object>();
        for(Object raw:links){Map<String,Object> link=asMap(raw);String sourceKey=visibleAliases.get(endpoint(link.get('from'))),targetKey=visibleAliases.get(endpoint(link.get('to')));
            if(sourceKey!=null&&targetKey!=null)validLinks.add(raw);else{view.partial=true;String original=allAliases.get(endpoint(link.get('from')));if(view.frozen.containsKey(original))view.frozen.get(original).add((String)link.get('fieldName'));}
        }view.payload.put('associations',validLinks);
        for(String id:visible.keySet())for(String key:new List<String>{'values','changes','originalValues'})for(String f:view.frozen.get(id))asMap(visible.get(id).get(key)).remove(f);
        List<Object> objects=new List<Object>();Map<Integer,Integer> indices=new Map<Integer,Integer>();Integer oldIndex=0;
        for(Object raw:items(asMap(full.get('schema')).get('objects'))){Map<String,Object> obj=asMap(raw);String name=(String)obj.get('name');
            if(describe(name)==null){view.partial=true;oldIndex++;continue;}
            Map<String,Object> next=only(obj,new Set<String>{'name','label','idx','addedFromIdx','addedVia','worldPos','fields','draftFields'});
            indices.put(oldIndex++,objects.size());next.put('idx',objects.size());
            for(String key:new List<String>{'fields','draftFields'})if(obj.containsKey(key)){
                List<Object> fs=new List<Object>();for(Object fraw:items(obj.get(key))){Map<String,Object> f=asMap(fraw);
                    if(!valueAllowed(name,(String)f.get('name'),f.get('defaultValue'),allowed)){view.partial=true;continue;}fs.add(f);
                }next.put(key,fs);
            }objects.add(next);
        }
        for(Object raw:objects){Map<String,Object> obj=asMap(raw);Object parent=obj.get('addedFromIdx');if(parent!=null){Integer mapped=indices.get(Integer.valueOf(String.valueOf(parent)));obj.put('addedFromIdx',mapped);if(mapped==null){obj.put('addedVia',null);view.partial=true;}}}
        view.payload.put('schema',new Map<String,Object>{'objects'=>objects});return view;
    }
    private static void fail(){throw new OrgLoomNativeCanvases.CanvasException('The submitted canvas includes unavailable content or conflicting identities. Reopen it before saving.');}
    // Hidden map members survive; a client may neither replace nor remove them.
    private static Map<String,Object> mergeMap(Map<String,Object> full,Map<String,Object> visible,Map<String,Object> proposed){
        Map<String,Object> result=new Map<String,Object>(full);
        for(String key:proposed.keySet())if(full.containsKey(key)&&!visible.containsKey(key))fail();
        for(String key:visible.keySet())if(!proposed.containsKey(key))result.remove(key);
        result.putAll(proposed);return result;
    }
    private static List<Object> mergeFields(List<Object> full,List<Object> visible,List<Object> proposed){
        Map<String,Map<String,Object>> all=new Map<String,Map<String,Object>>(),shown=new Map<String,Map<String,Object>>();
        for(Object raw:full)all.put((String)asMap(raw).get('name'),asMap(raw));for(Object raw:visible)shown.put((String)asMap(raw).get('name'),asMap(raw));
        List<Object> result=new List<Object>();Set<String> seen=new Set<String>();
        for(Object raw:proposed){Map<String,Object> f=asMap(raw);String name=(String)f.get('name');if(!seen.add(name)||all.containsKey(name)&&!shown.containsKey(name))fail();result.add(f);}
        for(String name:all.keySet())if(!shown.containsKey(name))result.add(all.get(name));return result;
    }
    public static Map<String,Object> mergeVisible(Map<String,Object> full,View view,Map<String,Object> submitted){
        View candidate=project(submitted);if(candidate.partial)fail();Map<String,Object> after=candidate.payload;
        Map<String,Map<String,Object>> all=rows(full),shown=rows(view.payload),proposed=rows(after);
        Map<String,String> allAliases=aliases(all);Set<String> protectedRows=new Set<String>(),hiddenLinks=new Set<String>();
        Set<String> shownLinks=new Set<String>();for(Object raw:items(view.payload.get('associations')))shownLinks.add(hash(raw));
        for(Object raw:items(full.get('associations')))if(!shownLinks.contains(hash(raw))){hiddenLinks.add(hash(raw));for(String key:new List<String>{'from','to'}){String id=allAliases.get(endpoint(asMap(raw).get(key)));if(id!=null)protectedRows.add(id);}}
        Map<String,Object> result=copy(full);result.put('_meta',after.get('_meta'));
        Map<String,Map<String,Object>> merged=new Map<String,Map<String,Object>>();
        for(String id:proposed.keySet()){
            Map<String,Object> next=proposed.get(id),old=all.get(id),before=shown.get(id);
            if(old!=null&&before==null)fail();
            if(old==null){merged.put(id,next);continue;}
            if(old.get('objectName')!=next.get('objectName'))fail();
            Map<String,Object> row=new Map<String,Object>(next);
            for(String key:new List<String>{'values','changes','originalValues'}){
                for(String f:view.frozen.get(id))if(asMap(next.get(key)).containsKey(f))fail();
                Map<String,Object> values=mergeMap(asMap(old.get(key)),asMap(before.get(key)),asMap(next.get(key)));
                if(!values.isEmpty()||next.containsKey(key))row.put(key,values);
            }
            Map<String,Object> oldSlot=asMap(old.get('slot')),shownSlot=asMap(before.get('slot')),newSlot=asMap(next.get('slot'));
            if(!oldSlot.isEmpty()&&shownSlot.isEmpty()){if(!newSlot.isEmpty())fail();row.put('slot',oldSlot);}
            else if(oldSlot.get('kind')=='fields'){
                List<Object> hidden=new List<Object>();for(Object f:items(oldSlot.get('fields')))if(!items(shownSlot.get('fields')).contains(f))hidden.add(f);
                if(!hidden.isEmpty()){
                    if(!newSlot.isEmpty()&&(newSlot.get('slotId')!=shownSlot.get('slotId')||newSlot.get('kind')!='fields'))fail();
                    Map<String,Object> slot=new Map<String,Object>(oldSlot);
                    if(!newSlot.isEmpty())for(String key:newSlot.keySet()){
                        // The shared restorer adds null description/label defaults;
                        // these cannot overwrite notes withheld from this view.
                        if(oldSlot.containsKey(key)&&!shownSlot.containsKey(key)){if(newSlot.get(key)!=null)fail();continue;}
                        slot.put(key,newSlot.get(key));
                    }
                    List<Object> fs=new List<Object>();fs.addAll(items(newSlot.get('fields')));for(Object f:hidden){if(fs.contains(f))fail();fs.add(f);}slot.put('fields',fs);row.put('slot',slot);
                }
            }
            // Unknown stored extensions are never surfaced or deleted by another client.
            for(String key:old.keySet())if(!ROW_KEYS.contains(key))row.put(key,old.get(key));
            merged.put(id,row);
        }
        for(String id:all.keySet())if(!proposed.containsKey(id)){
            if(!shown.containsKey(id)||hash(all.get(id))!=hash(shown.get(id))||protectedRows.contains(id))merged.put(id,all.get(id));
        }
        for(String key:new List<String>{'loadedRecords','drafts'}){
            List<Object> records=new List<Object>();Set<String> added=new Set<String>();
            for(Object raw:items(after.get(key))){String id=identity(asMap(raw));records.add(merged.get(id));added.add(id);}
            for(Object raw:items(full.get(key))){String id=identity(asMap(raw));if(merged.containsKey(id)&&!proposed.containsKey(id)&&added.add(id))records.add(merged.get(id));}
            result.put(key,records);
        }
        List<Object> links=new List<Object>();Map<String,String> nextAliases=aliases(merged);
        for(Object raw:items(after.get('associations'))){Map<String,Object> link=asMap(raw);String sourceKey=nextAliases.get(endpoint(link.get('from'))),targetKey=nextAliases.get(endpoint(link.get('to')));
            if(sourceKey==null||targetKey==null||!proposed.containsKey(sourceKey)||!proposed.containsKey(targetKey))fail();
            if(view.frozen.containsKey(sourceKey)&&view.frozen.get(sourceKey).contains((String)link.get('fieldName')))fail();links.add(raw);
        }
        for(Object raw:items(full.get('associations')))if(hiddenLinks.contains(hash(raw)))links.add(raw);result.put('associations',links);
        // Schema objects can have repeated names. Match each visible occurrence in order.
        List<Object> oldObjects=items(asMap(full.get('schema')).get('objects')),visibleObjects=items(asMap(view.payload.get('schema')).get('objects')),newObjects=items(asMap(after.get('schema')).get('objects'));
        List<Object> objects=new List<Object>();Set<Integer> used=new Set<Integer>();Map<Integer,Integer> oldToNew=new Map<Integer,Integer>();
        for(Object raw:newObjects){Map<String,Object> next=asMap(raw);Integer match;
            for(Integer i=0;i<oldObjects.size();i++)if(!used.contains(i)&&asMap(oldObjects[i]).get('name')==next.get('name')){match=i;break;}
            if(match!=null){used.add(match);oldToNew.put(match,objects.size());Map<String,Object> old=asMap(oldObjects[match]),before;
                // Find the corresponding visible occurrence via its original index.
                Integer vi=0;for(Integer i=0;i<match;i++)if(describe((String)asMap(oldObjects[i]).get('name'))!=null)vi++;
                if(vi>=visibleObjects.size())fail();before=asMap(visibleObjects[vi]);
                for(String key:new List<String>{'fields','draftFields'})if(old.containsKey(key)||next.containsKey(key))next.put(key,mergeFields(items(old.get(key)),items(before.get(key)),items(next.get(key))));
            }objects.add(next);
        }
        // Keep omitted schema entries with hidden data and remap their parent
        // indexes after the visible and hidden entries have been combined.
        for(Integer i=0;i<oldObjects.size();i++)if(!used.contains(i)){
            Map<String,Object> old=asMap(oldObjects[i]);Boolean preserve=describe((String)old.get('name'))==null;
            Integer vi=0;for(Integer j=0;j<i;j++)if(describe((String)asMap(oldObjects[j]).get('name'))!=null)vi++;
            Map<String,Object> before=preserve||vi>=visibleObjects.size()?new Map<String,Object>():asMap(visibleObjects[vi]);
            for(String key:new List<String>{'fields','draftFields'})if(items(old.get(key)).size()!=items(before.get(key)).size())preserve=true;
            if(preserve){oldToNew.put(i,objects.size());old.put('idx',objects.size());objects.add(old);}
        }
        for(Integer originalIndex:oldToNew.keySet()){
            Map<String,Object> old=asMap(oldObjects[originalIndex]),next=asMap(objects[oldToNew.get(originalIndex)]);Object parent=old.get('addedFromIdx');
            if(parent==null)continue;Integer pi=Integer.valueOf(String.valueOf(parent));
            // Restore withheld schema relationships after reindexing the merged list.
            if(!used.contains(originalIndex)||(pi>=0&&pi<oldObjects.size()&&describe((String)asMap(oldObjects[pi]).get('name'))==null)){
                next.put('addedFromIdx',oldToNew.get(pi));next.put('addedVia',oldToNew.containsKey(pi)?old.get('addedVia'):null);
            }
        }
        result.put('schema',new Map<String,Object>{'objects'=>objects});return result;
    }
    public static void validateFills(Map<String,Object> full,View view,List<Object> fills){
        Map<String,Map<String,Object>> all=rows(full),shown=rows(view.payload);Map<String,String> slotAliases=aliases(shown);
        for(Object raw:items(fills)){
            Map<String,Object> fill=asMap(raw);String id=slotAliases.get('slot:'+fill.get('slotId'));if(id==null)fail();
            for(String f:asMap(fill.get('values')).keySet())if(view.frozen.get(id).contains(f))fail();
            for(Object f:items(fill.get('relationshipFields')))if(view.frozen.get(id).contains((String)f))fail();
            if(asMap(fill.get('values')).get('Id')!=null&&hash(all.get(id))!=hash(shown.get(id)))throw new OrgLoomNativeCanvases.CanvasException('This request has hidden content. Ask its owner to choose an existing record, or fill the visible fields to create a new one.');
        }
    }
}
