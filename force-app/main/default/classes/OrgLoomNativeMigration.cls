public with sharing class OrgLoomNativeMigration {
    public class MigrationException extends Exception {}
    public static Object matchRecords(Map<String,Object> body) {
        OrgLoomNativeAccess.requireCapability('bulk-edit-records');
        String name=(String)body.get('objectName');Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo(name);
        Schema.SObjectField token=d.fields.getMap().get((String)body.get('keyField'));
        if(token==null||!OrgLoomNativeController.supported(token.getDescribe())||!token.getDescribe().isFilterable())throw new MigrationException('Unavailable match field.');
        Schema.DescribeFieldResult field=token.getDescribe();
        if(!new Set<Schema.DisplayType>{Schema.DisplayType.STRING,Schema.DisplayType.EMAIL,Schema.DisplayType.PHONE,Schema.DisplayType.URL,Schema.DisplayType.TEXTAREA,Schema.DisplayType.INTEGER,Schema.DisplayType.DOUBLE,Schema.DisplayType.CURRENCY,Schema.DisplayType.PERCENT}.contains(field.getType()))throw new MigrationException('Choose a text or number match field. Source record IDs cannot identify destination records.');
        List<Object> input=(List<Object>)body.get('values');if(input==null||input.isEmpty()||input.size()>100)throw new MigrationException('Match between 1 and 100 values.');
        List<String> textValues=new List<String>();List<Decimal> numberValues=new List<Decimal>();List<Integer> integerValues=new List<Integer>();
        Boolean numeric=new Set<Schema.DisplayType>{Schema.DisplayType.INTEGER,Schema.DisplayType.DOUBLE,Schema.DisplayType.CURRENCY,Schema.DisplayType.PERCENT}.contains(field.getType());
        for(Object raw:input){String value=String.valueOf(raw);if(value.length()>255)throw new MigrationException('Match values are too long.');if(field.getType()==Schema.DisplayType.INTEGER)integerValues.add(Integer.valueOf(value));else if(numeric)numberValues.add(Decimal.valueOf(value));else textValues.add(value);}
        Map<String,Object> binds=new Map<String,Object>{'values'=>field.getType()==Schema.DisplayType.INTEGER?(Object)integerValues:numeric?(Object)numberValues:(Object)textValues};
        String title='Id';for(Schema.SObjectField f:d.fields.getMap().values())if(f.getDescribe().isNameField()&&f.getDescribe().isAccessible())title=f.getDescribe().getName();
        Set<String> columns=new Set<String>{'Id',field.getName(),title};
        List<SObject> found=Database.queryWithBinds('SELECT '+String.join(new List<String>(columns),',')+' FROM '+d.getName()+' WHERE '+field.getName()+' IN :values LIMIT 501',binds,AccessLevel.USER_MODE);
        if(found.size()>500)throw new MigrationException('Too many destination matches. Choose a more specific match field.');
        Map<String,Object> candidates=new Map<String,Object>();
        for(SObject row:found){String value=String.valueOf(row.get(field.getName()));if(!candidates.containsKey(value))candidates.put(value,new List<Object>());((List<Object>)candidates.get(value)).add(new Map<String,Object>{'id'=>row.Id,'label'=>row.get(title),'details'=>new List<Object>()});}
        return new Map<String,Object>{'candidatesByValue'=>candidates};
    }
}
