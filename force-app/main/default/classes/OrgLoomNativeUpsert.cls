// Native upserts resolve during planning, then revalidate before DML. Only record
// identities and modification timestamps enter the durable plan, never match values.
public with sharing class OrgLoomNativeUpsert {
    private static List<Object> records(Map<String,Object> body) {
        return body.get('records')==null?new List<Object>():(List<Object>)body.get('records');
    }
    public static Schema.SObjectField field(Map<String,Object> row) {
        Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo((String)row.get('objectName'));
        Schema.SObjectField token=d.fields.getMap().get((String)row.get('_csvExternalIdField'));
        if(token==null)throw new OrgLoomNativeUpload.UploadException('Choose an external ID field for upsert.');
        Schema.DescribeFieldResult f=token.getDescribe();
        if(!OrgLoomNativeController.supported(f)||!f.isFilterable()||!(f.isExternalId()||f.isIdLookup())||f.getName()=='Id')
            throw new OrgLoomNativeUpload.UploadException('Upsert requires an accessible external ID or ID lookup field.');
        Map<String,Object> values=(Map<String,Object>)row.get('values');
        if(values==null||values.get(f.getName())==null||String.isBlank(String.valueOf(values.get(f.getName()))))
            throw new OrgLoomNativeUpload.UploadException('Every upsert record needs a nonempty external ID value.');
        return token;
    }
    private static String valueKey(Object value,Schema.DescribeFieldResult f) {
        String result=String.valueOf(value);return f.isCaseSensitive()?result:result.toLowerCase();
    }
    private static Map<String,Object> matches(Map<String,Object> body) {
        Map<String,List<Map<String,Object>>> groups=new Map<String,List<Map<String,Object>>>();
        Map<String,Schema.DescribeFieldResult> fields=new Map<String,Schema.DescribeFieldResult>();
        Set<String> unique=new Set<String>();
        for(Object raw:records(body)) {
            Map<String,Object> row=(Map<String,Object>)raw;if(row.get('_csvOperation')!='upsert')continue;
            Schema.DescribeFieldResult f=field(row).getDescribe();String batchKey=row.get('objectName')+':'+f.getName();
            Object value=OrgLoomNativeController.convert(((Map<String,Object>)row.get('values')).get(f.getName()),f);
            if(!unique.add(batchKey+':'+valueKey(value,f)))throw new OrgLoomNativeUpload.UploadException('The upload contains the same external ID more than once.');
            if(!groups.containsKey(batchKey))groups.put(batchKey,new List<Map<String,Object>>());groups.get(batchKey).add(row);fields.put(batchKey,f);
        }
        if(groups.size()>20)throw new OrgLoomNativeUpload.UploadException('Use no more than 20 object/external-ID combinations per upload.');
        Map<String,Object> result=new Map<String,Object>();
        for(String batchKey:groups.keySet()) {
            Schema.DescribeFieldResult f=fields.get(batchKey);List<String> texts=new List<String>();List<Decimal> numbers=new List<Decimal>();
            Boolean numeric=new Set<Schema.DisplayType>{Schema.DisplayType.INTEGER,Schema.DisplayType.DOUBLE,Schema.DisplayType.CURRENCY,Schema.DisplayType.PERCENT}.contains(f.getType());
            for(Map<String,Object> row:groups.get(batchKey)){Object value=((Map<String,Object>)row.get('values')).get(f.getName());if(numeric)numbers.add(Decimal.valueOf(String.valueOf(value)));else texts.add(String.valueOf(value));}
            String name=(String)groups.get(batchKey)[0].get('objectName');
            List<SObject> found=Database.queryWithBinds('SELECT Id,LastModifiedDate,'+f.getName()+' FROM '+name+' WHERE '+f.getName()+' IN :keys LIMIT 501',new Map<String,Object>{'keys'=>numeric?(Object)numbers:(Object)texts},AccessLevel.USER_MODE);
            if(found.size()>500)throw new OrgLoomNativeUpload.UploadException('Too many external ID matches. Use a unique field.');
            Map<String,SObject> byKey=new Map<String,SObject>();
            for(SObject record:found){String matchKey=valueKey(record.get(f.getName()),f);if(byKey.containsKey(matchKey))throw new OrgLoomNativeUpload.UploadException('An external ID matches more than one record. Resolve the duplicates first.');byKey.put(matchKey,record);}
            for(Map<String,Object> row:groups.get(batchKey)) {
                Object value=OrgLoomNativeController.convert(((Map<String,Object>)row.get('values')).get(f.getName()),f);
                SObject matched=byKey.get(valueKey(value,f));
                result.put(String.valueOf(row.get('tempId')),new Map<String,Object>{'id'=>matched==null?null:matched.Id,'modified'=>matched==null?null:matched.get('LastModifiedDate')});
            }
        }
        return result;
    }
    public static Map<String,Object> resolve(Map<String,Object> body) {return restore(body,matches(body));}
    public static Map<String,Object> restore(Map<String,Object> body,Map<String,Object> resolutions) {
        Map<String,Object> copy=(Map<String,Object>)JSON.deserializeUntyped(JSON.serialize(body));
        for(Object raw:records(copy)) {
            Map<String,Object> row=(Map<String,Object>)raw;if(row.get('_csvOperation')!='upsert')continue;
            Map<String,Object> match=(Map<String,Object>)resolutions.get(String.valueOf(row.get('tempId')));
            if(match==null)throw new OrgLoomNativeUpload.UploadException('Missing upsert resolution. Review a new upload.');
            if(row.get('loadedFromId')!=null&&String.valueOf(row.get('loadedFromId'))!=String.valueOf(match.get('id')))
                throw new OrgLoomNativeUpload.UploadException('The external ID no longer identifies the loaded record.');
            row.put('_nativeUpsert',match);row.put('loadedFromId',match.get('id'));
            if(match.get('id')!=null)row.put('loadedValues',new Map<String,Object>{'LastModifiedDate'=>match.get('modified')});
        }
        return copy;
    }
    public static Map<String,Object> resolutions(Map<String,Object> body) {
        Map<String,Object> result=new Map<String,Object>();for(Object raw:records(body)){Map<String,Object> row=(Map<String,Object>)raw;if(row.get('_csvOperation')=='upsert')result.put(String.valueOf(row.get('tempId')),row.get('_nativeUpsert'));}return result;
    }
    public static void verify(Map<String,Object> body) {
        Map<String,Object> fresh=matches(body),planned=resolutions(body);
        if(OrgLoomNativeUpload.fingerprint(fresh)!=OrgLoomNativeUpload.fingerprint(planned))
            throw new OrgLoomNativeUpload.UploadException('An external ID match changed after planning. Review a new upload; no changes were committed.');
    }
}

