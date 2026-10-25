public with sharing class OrgLoomNativeBrowse {
    public class BrowseException extends Exception {}
    private static Schema.DescribeFieldResult field(Schema.DescribeSObjectResult d,String name) {
        Schema.SObjectField token=d.fields.getMap().get(name);
        if(token==null || !token.getDescribe().isAccessible() || !token.getDescribe().isFilterable())throw new BrowseException('Unavailable filter field.');
        return token.getDescribe();
    }
    public static Object browse(Map<String,Object> body) {
        OrgLoomNativeAccess.requireCapability('browse-records');
        String name=(String)body.get('objectName');Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo(name);
        Integer pageSize=body.get('limit')==null?25:Integer.valueOf(String.valueOf(body.get('limit'))),offset=body.get('offset')==null?0:Integer.valueOf(String.valueOf(body.get('offset')));
        pageSize=Math.max(1,Math.min(100,pageSize));if(offset<0||offset>2000)throw new BrowseException('Refine your filters to browse beyond 2,000 records.');
        List<String> predicates=new List<String>(),preview=new List<String>{'Id'};Map<String,Object> binds=new Map<String,Object>();
        Map<String,String> operators=new Map<String,String>{'equals'=>'=','notEquals'=>'!=','gt'=>'>','gte'=>'>=','lt'=>'<','lte'=>'<=','before'=>'<','after'=>'>'};
        List<Object> filters=body.get('filters')==null?new List<Object>():(List<Object>)body.get('filters');if(filters.size()>12)throw new BrowseException('Use at most 12 filters.');
        for(Object raw:filters) {
            Map<String,Object> filter=(Map<String,Object>)raw;Schema.DescribeFieldResult f=field(d,(String)filter.get('field'));String op=(String)filter.get('op'),param='v'+binds.size(),column=f.getName();
            if(op=='isNull'||op=='isNotNull'){predicates.add(column+(op=='isNull'?' = null':' != null'));continue;}
            Object value=filter.get('value');String operator=operators.get(op);
            if(op=='in'){List<String> choices=new List<String>();for(Object choice:(List<Object>)value)choices.add(String.valueOf(choice));if(choices.isEmpty()||choices.size()>100)throw new BrowseException('Invalid filter choices.');binds.put(param,choices);operator='IN';}
            else if(op=='contains'||op=='startsWith'){if(!new Set<Schema.DisplayType>{Schema.DisplayType.STRING,Schema.DisplayType.PHONE,Schema.DisplayType.EMAIL,Schema.DisplayType.URL,Schema.DisplayType.TEXTAREA}.contains(f.getType()))throw new BrowseException('This field does not support text search.');String text=String.valueOf(value).replace('\\','\\\\').replace('%','\\%').replace('_','\\_');binds.put(param,(op=='contains'?'%':'')+text+'%');operator='LIKE';}
            else if(operator!=null){if(f.getType()==Schema.DisplayType.BOOLEAN&&value instanceof String)value=Boolean.valueOf((String)value);binds.put(param,OrgLoomNativeController.convert(value,f));}
            else throw new BrowseException('Unsupported filter operator.');
            predicates.add(column+' '+operator+' :'+param);
        }
        List<String> searchFields=new List<String>();
        for(String candidate:new List<String>{'Name','Subject','CaseNumber','Email','Phone','StageName','Status'})if(d.fields.getMap().containsKey(candidate)&&d.fields.getMap().get(candidate).getDescribe().isAccessible()){preview.add(candidate);Schema.DescribeFieldResult f=d.fields.getMap().get(candidate).getDescribe();if(f.isFilterable()&&new Set<Schema.DisplayType>{Schema.DisplayType.STRING,Schema.DisplayType.EMAIL,Schema.DisplayType.PHONE}.contains(f.getType()))searchFields.add(candidate+' LIKE :search');}
        String search=(String)body.get('search');if(String.isNotBlank(search)){if(searchFields.isEmpty())throw new BrowseException('Use field filters for this object.');binds.put('search','%'+search.replace('\\','\\\\').replace('%','\\%').replace('_','\\_')+'%');predicates.add('('+String.join(searchFields,' OR ')+')');}
        String whereClause=predicates.isEmpty()?'':' WHERE '+String.join(predicates,' AND ');
        String order='Id ASC';Map<String,Object> sorting=(Map<String,Object>)body.get('sort');if(sorting!=null&&sorting.get('field')!=null){Schema.DescribeFieldResult f=field(d,(String)sorting.get('field'));if(!f.isSortable())throw new BrowseException('Field is not sortable.');order=f.getName()+('desc'==(String)sorting.get('direction')?' DESC':' ASC')+', Id ASC';}
        Integer count=Database.countQueryWithBinds('SELECT COUNT() FROM '+name+whereClause,binds,AccessLevel.USER_MODE);
        List<SObject> rows=Database.queryWithBinds('SELECT '+String.join(preview,',')+' FROM '+name+whereClause+' ORDER BY '+order+' LIMIT '+pageSize+' OFFSET '+offset,binds,AccessLevel.USER_MODE);
        return new Map<String,Object>{'count'=>count,'loadableCount'=>count,'records'=>rows,'previewFields'=>preview,'hasMore'=>count>offset+rows.size()};
    }
    public static Object load(Map<String,Object> body) {
        OrgLoomNativeAccess.requireCapability('browse-records');
        return loadIds(body);
    }
    public static Object fileLoad(Map<String,Object> body) {
        OrgLoomNativeAccess.requireCapability('bulk-edit-records');
        return loadIds(body);
    }
    private static Object loadIds(Map<String,Object> body) {
        // Browse's shared frontend expresses selected IDs as SOQL. Accept only this
        // narrow grammar, never general SOQL under the Browse capability.
        String soql=(String)body.get('soql');
        Matcher m=Pattern.compile('(?i)^\\s*SELECT\\s+Id\\s+FROM\\s+(\\w+)\\s+WHERE\\s+Id\\s+IN\\s*\\(([\'A-Za-z0-9,\\s]+)\\)\\s*(?:LIMIT\\s+\\d+)?\\s*$').matcher(soql==null?'':soql);
        if(!m.matches())throw new BrowseException('Select individual browse results to load.');
        String name=m.group(1);Set<Id> ids=new Set<Id>();for(String raw:m.group(2).split(',')){String value=raw.trim();if(!Pattern.matches('\'[A-Za-z0-9]{15}(?:[A-Za-z0-9]{3})?\'',value))throw new BrowseException('Invalid selected record.');ids.add((Id)value.substring(1,value.length()-1));}
        if(ids.size()>200)throw new BrowseException('Load at most 200 selected records at a time.');List<Object> records=new List<Object>();Integer index=0;
        for(SObject r:OrgLoomNativeController.read(name,ids,false))records.add(new Map<String,Object>{'tempId'=>++index,'objectName'=>name,'loadedFromId'=>r.get('Id'),'values'=>r});
        return new Map<String,Object>{'objectName'=>name,'records'=>records,'associations'=>new List<Object>(),'totalSize'=>records.size(),'returned'=>records.size(),'fullFields'=>true,'cap'=>200,'capped'=>false};
    }
}
