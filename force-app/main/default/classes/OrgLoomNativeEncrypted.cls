// Encrypted Salesforce values are tab-local. Only field-name intents may be
// persisted by Org Loom; Salesforce remains responsible for masking and FLS.
public class OrgLoomNativeEncrypted {
    private static Map<String,Set<String>> cache=new Map<String,Set<String>>();
    @TestVisible private static Map<String,Set<String>> testFields;
    private static Set<String> fields(String name){
        if(Test.isRunningTest()&&testFields!=null)return testFields.containsKey(name)?testFields.get(name):new Set<String>();
        if(!cache.containsKey(name)){
            Set<String> names=new Set<String>();Schema.SObjectType type=OrgLoomNativeController.globalObjects().get(name);
            if(type!=null)for(Schema.SObjectField token:type.getDescribe().fields.getMap().values()){
                Schema.DescribeFieldResult f=token.getDescribe();
                if(f.getType()==Schema.DisplayType.ENCRYPTEDSTRING)names.add(f.getName().toLowerCase());
            }
            cache.put(name,names);
        }
        return cache.get(name);
    }
    public static Boolean isField(String name,String field){return field!=null&&fields(name).contains(field.toLowerCase());}
    public static Map<String,Object> strip(String name,Map<String,Object> values){
        Map<String,Object> result=new Map<String,Object>(values);
        for(String field:values.keySet())if(isField(name,field))result.remove(field);
        return result;
    }
    private static List<Object> items(Object value){return value==null?new List<Object>():(List<Object>)value;}
    public static Map<String,Object> canvas(Map<String,Object> source){
        Map<String,Object> result=OrgLoomNativeProjection.copy(source);
        for(String key:new List<String>{'loadedRecords','drafts'})for(Object raw:items(result.get(key))){
            Map<String,Object> row=(Map<String,Object>)raw;String name=(String)row.get('objectName');Set<String> intents=new Set<String>();
            for(Object field:items(row.get('encryptedFieldIntents')))if(isField(name,(String)field))intents.add((String)field);
            for(String valueKey:new List<String>{'values','changes','originalValues','loadedValues'})if(row.get(valueKey)!=null){
                Map<String,Object> values=(Map<String,Object>)row.get(valueKey);
                for(String field:values.keySet())if(isField(name,field)&&(valueKey=='values'||valueKey=='changes'))intents.add(field);
                row.put(valueKey,strip(name,values));
            }
            row.remove('_encryptedFieldProposals');row.remove('_encryptedFieldIntents');
            if(row.containsKey('encryptedFieldIntents')||!intents.isEmpty())row.put('encryptedFieldIntents',new List<String>(intents));
            if(row.get('slot')!=null){
                Map<String,Object> slot=(Map<String,Object>)row.get('slot');
                if(slot.get('kind')=='fields'){
                    List<Object> allowed=new List<Object>();for(Object field:items(slot.get('fields')))if(!isField(name,(String)field))allowed.add(field);
                    slot.put('fields',allowed);if(allowed.isEmpty())row.remove('slot');
                }
            }
        }
        Map<String,Object> schema=(Map<String,Object>)result.get('schema');
        if(schema!=null)for(Object raw:items(schema.get('objects'))){
            Map<String,Object> obj=(Map<String,Object>)raw;
            for(String key:new List<String>{'fields','draftFields'})for(Object rawField:items(obj.get(key))){
                Map<String,Object> field=(Map<String,Object>)rawField;
                if(isField((String)obj.get('name'),(String)field.get('name')))field.remove('defaultValue');
            }
        }
        return result;
    }
    public static Boolean explicit(Map<String,Object> row,String field){
        for(Object name:items(row.get('explicitFields')))if(String.valueOf(name).equalsIgnoreCase(field))return true;
        return false;
    }
}
