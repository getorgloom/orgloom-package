// Native adapter for the unchanged canvas graph, lookup and related-record UI.
// Every query runs in user mode. Identifier strings come from describe, never SQL input.
public with sharing class OrgLoomNativeReads {
    public class ReadException extends Exception {}
    public static List<Object> children(Schema.DescribeSObjectResult d) {
        List<Object> result=new List<Object>();
        for(Schema.ChildRelationship r:d.getChildRelationships()) {
            if(r.getField()==null || r.isDeprecatedAndHidden())continue;
            Schema.DescribeSObjectResult child=r.getChildSObject().getDescribe();
            Schema.DescribeFieldResult f=r.getField().getDescribe();
            if(!OrgLoomNativeController.available(child)||!f.isAccessible())continue;
            result.add(new Map<String,Object>{'childSObject'=>child.getName(),'field'=>f.getName(),
                'relationshipName'=>r.getRelationshipName(),'cascadeDelete'=>r.isCascadeDelete(),
                'restrictedDelete'=>r.isRestrictedDelete()});
        }
        return result;
    }
    public static Object graph(String name) {
        Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo(name);
        List<Object> parents=new List<Object>(),kids=new List<Object>();
        for(Schema.SObjectField token:d.fields.getMap().values()) {
            Schema.DescribeFieldResult f=token.getDescribe();
            if(!f.isAccessible()||f.getType()!=Schema.DisplayType.REFERENCE)continue;
            for(Schema.SObjectType t:f.getReferenceTo()) {
                Schema.DescribeSObjectResult target=t.getDescribe();
                if(OrgLoomNativeController.available(target))parents.add(new Map<String,Object>{
                    'object'=>target.getName(),'label'=>target.getLabel(),'field'=>f.getName(),'fieldLabel'=>f.getLabel(),
                    'required'=>!f.isNillable()&&!f.isDefaultedOnCreate(),'createable'=>f.isCreateable(),'updateable'=>f.isUpdateable()});
            }
        }
        for(Object raw:children(d)) {
            Map<String,Object> r=(Map<String,Object>)raw;
            Schema.DescribeSObjectResult child=OrgLoomNativeController.objectInfo((String)r.get('childSObject'));
            kids.add(new Map<String,Object>{'object'=>child.getName(),'label'=>child.getLabel(),'field'=>r.get('field'),'relationshipName'=>r.get('relationshipName')});
        }
        return new Map<String,Object>{'name'=>d.getName(),'label'=>d.getLabel(),'parents'=>parents,'children'=>kids};
    }
    private static String nameField(Schema.DescribeSObjectResult d) {
        for(Schema.SObjectField token:d.fields.getMap().values()) {
            Schema.DescribeFieldResult f=token.getDescribe();
            if(f.isNameField()&&f.isAccessible())return f.getName();
        }
        return 'Id';
    }
    private static String escapedSearch(String value) {
        if(value==null)return '';
        if(value.length()>200)throw new ReadException('Search text is too long.');
        return value.replace('\\','\\\\').replace('%','\\%').replace('_','\\_');
    }
    private static Object search(Map<String,Object> body,Boolean lookup) {
        String name=(String)body.get('objectName');
        if(lookup) {
            Schema.DescribeSObjectResult source=OrgLoomNativeController.objectInfo(name);
            Schema.SObjectField token=source.fields.getMap().get((String)body.get('fieldName'));
            if(token==null||!token.getDescribe().isAccessible()||token.getDescribe().getType()!=Schema.DisplayType.REFERENCE)throw new ReadException('Unavailable lookup field.');
            name=(String)body.get('targetApiName');Boolean valid=false;
            for(Schema.SObjectType t:token.getDescribe().getReferenceTo())if(t.getDescribe().getName()==name)valid=true;
            if(!valid)throw new ReadException('Invalid lookup target.');
        }
        Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo(name);
        String title=nameField(d),q=(String)body.get('q');
        String predicate='';Map<String,Object> binds=new Map<String,Object>();
        if(String.isNotBlank(q)) {
            List<String> terms=new List<String>();
            if(title!='Id'&&d.fields.getMap().get(title).getDescribe().isFilterable()) {
                binds.put('term','%'+escapedSearch(q)+'%');terms.add(title+' LIKE :term');
            }
            if(Pattern.matches('[A-Za-z0-9]{15}(?:[A-Za-z0-9]{3})?',q)){binds.put('recordId',(Id)q);terms.add('Id = :recordId');}
            if(terms.isEmpty())return new Map<String,Object>{'records'=>new List<Object>()};
            predicate=' WHERE ('+String.join(terms,' OR ')+')';
        }
        // Exclude the edited record before LIMIT so self-lookups cannot consume
        // a suggestion slot. Bind an Id to support both 15- and 18-character IDs.
        String sourceRecordId=lookup?(String)body.get('sourceRecordId'):null;
        if(String.isNotBlank(sourceRecordId)) {
            if(!Pattern.matches('[A-Za-z0-9]{15}(?:[A-Za-z0-9]{3})?',sourceRecordId))throw new ReadException('Invalid source record ID.');
            binds.put('sourceRecordId',(Id)sourceRecordId);
            predicate+=(String.isBlank(predicate)?' WHERE ':' AND ')+'Id != :sourceRecordId';
        }
        List<Object> records=new List<Object>();
        for(SObject r:Database.queryWithBinds('SELECT Id'+(title=='Id'?'':','+title)+' FROM '+d.getName()+predicate+' ORDER BY Id LIMIT 25',binds,AccessLevel.USER_MODE)) {
            records.add(new Map<String,Object>{'id'=>r.get('Id'),'title'=>r.get(title),'name'=>r.get(title),'apiName'=>d.getName()});
        }
        // Required Salesforce lookup filters are still enforced by DML.
        return new Map<String,Object>{'records'=>records};
    }
    private static Schema.DescribeFieldResult reference(Schema.DescribeSObjectResult d,String field,Id parent) {
        Schema.SObjectField token=d.fields.getMap().get(field);
        if(token==null)throw new ReadException('Unavailable relationship.');
        Schema.DescribeFieldResult f=token.getDescribe();
        if(!f.isAccessible()||!f.isFilterable()||f.getType()!=Schema.DisplayType.REFERENCE)throw new ReadException('Unavailable relationship.');
        Boolean valid=false;for(Schema.SObjectType t:f.getReferenceTo())if(t==parent.getSObjectType())valid=true;
        if(!valid)throw new ReadException('Record does not match the relationship.');
        Schema.DescribeSObjectResult p=OrgLoomNativeController.objectInfo(parent.getSObjectType().getDescribe().getName());
        if(Database.queryWithBinds('SELECT Id FROM '+p.getName()+' WHERE Id = :parent',new Map<String,Object>{'parent'=>parent},AccessLevel.USER_MODE).isEmpty())throw new ReadException('Related record is unavailable.');
        return f;
    }
    private static Object related(Map<String,Object> body,Boolean countOnly) {
        Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo((String)body.get('objectName'));
        Id parent=(Id)(String)body.get('id');
        Schema.DescribeFieldResult f=reference(d,(String)body.get('field'),parent);
        String predicate=' WHERE '+f.getName()+' = :parent';
        Map<String,Object> binds=new Map<String,Object>{'parent'=>parent};
        if(countOnly)return new Map<String,Object>{'count'=>Database.countQueryWithBinds('SELECT COUNT() FROM '+d.getName()+predicate,binds,AccessLevel.USER_MODE)};
        String title=nameField(d),q=(String)body.get('q');
        if(String.isNotBlank(q)&&title!='Id'&&d.fields.getMap().get(title).getDescribe().isFilterable()) {predicate+=' AND '+title+' LIKE :term';binds.put('term','%'+escapedSearch(q)+'%');}
        Integer cap=body.get('limit')==null?50:Math.max(1,Math.min(200,Integer.valueOf(String.valueOf(body.get('limit')))));
        Set<Id> ids=new Set<Id>();for(SObject r:Database.queryWithBinds('SELECT Id FROM '+d.getName()+predicate+' ORDER BY Id LIMIT '+cap,binds,AccessLevel.USER_MODE))ids.add((Id)r.get('Id'));
        return new Map<String,Object>{'records'=>OrgLoomNativeController.read(d.getName(),ids,false),'cap'=>cap,'capped'=>ids.size()==cap};
    }
    private static Object refresh(Map<String,Object> body) {
        List<Object> rows=(List<Object>)body.get('records');
        if(rows==null||rows.size()>200)throw new ReadException('Refresh at most 200 records per request.');
        Map<String,Set<Id>> groups=new Map<String,Set<Id>>();
        for(Object raw:rows){Map<String,Object> r=(Map<String,Object>)raw;String name=(String)r.get('objectName');Id id=(Id)(String)r.get('sfId');
            if(id.getSObjectType()!=OrgLoomNativeController.objectInfo(name).getSObjectType())throw new ReadException('Invalid record identity.');
            if(!groups.containsKey(name))groups.put(name,new Set<Id>());groups.get(name).add(id);
        }
        if(groups.size()>20)throw new ReadException('Refresh at most 20 object types per request.');
        Map<Id,SObject> loaded=new Map<Id,SObject>();for(String name:groups.keySet())loaded.putAll(OrgLoomNativeController.read(name,groups.get(name),false));
        List<Object> results=new List<Object>();
        for(Object raw:rows){Map<String,Object> r=(Map<String,Object>)raw;Id id=(Id)(String)r.get('sfId');results.add(new Map<String,Object>{'objectName'=>r.get('objectName'),'sfId'=>id,'tempId'=>r.get('tempId'),'ok'=>loaded.containsKey(id),'values'=>loaded.get(id),'error'=>loaded.containsKey(id)?null:'Record unavailable'});}
        OrgLoomNativeActivity.record('records_refreshed',loaded.size()==rows.size()?'success':'partial',null,loaded.size()+' of '+rows.size()+' requested records refreshed.');
        return new Map<String,Object>{'results'=>results};
    }
    public static Object handle(String op,Map<String,Object> body) {
        OrgLoomNativeAccess.requireAccess();
        if(op=='graph')return graph((String)body.get('objectName'));
        if(op=='search'||op=='lookup')return search(body,op=='lookup');
        if(op=='refresh')return refresh(body);
        if(op=='related-count'||op=='by-ref'||op=='by-ref-search')return related(body,op=='related-count');
        if(op=='counts'){
            List<Object> probes=(List<Object>)body.get('probes');if(probes==null||probes.size()>25)throw new ReadException('At most 25 relationship probes per request.');
            List<Object> counts=new List<Object>();
            for(Object raw:probes){Map<String,Object> p=(Map<String,Object>)raw;Map<String,Object> r=new Map<String,Object>{'name'=>p.get('name'),'field'=>p.get('field'),'id'=>p.get('id')};
                Map<String,Object> request=new Map<String,Object>(p);request.put('objectName',p.get('name'));
                r.put('count',((Map<String,Object>)related(request,true)).get('count'));counts.add(r);
            }
            return new Map<String,Object>{'counts'=>counts};
        }
        throw new ReadException('Unsupported record read operation.');
    }
}
