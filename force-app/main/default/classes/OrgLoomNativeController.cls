global with sharing class OrgLoomNativeController {
    private static Map<String,Schema.SObjectType> catalog;
    public static Map<String,Schema.SObjectType> globalObjects() {
        if(catalog==null)catalog=Schema.getGlobalDescribe();
        return catalog;
    }
    // Native difference: discover record-backed objects using the running user's
    // describe. Internal app storage and settings are never canvas data sources.
    public static Boolean available(Schema.DescribeSObjectResult d) {
        String name=d.getName().toLowerCase();
        return d.isAccessible() && d.isQueryable() && !d.isDeprecatedAndHidden()
            && !d.isCustomSetting() && d.fields.getMap().containsKey('Id')
            && !name.contains('orgloomnative') && !name.endsWith('orgloomfeatureaccess__c') && !name.endsWith('__mdt') && !name.endsWith('__e') && !name.endsWith('__b');
    }
    private class NativeRequestException extends Exception {}
    public String getIdentityJson() {
        return JSON.serialize(identity());
    }
    public String getRequestedCanvas() {
        String id=ApexPages.currentPage().getParameters().get('openCanvas');
        return id!=null&&Pattern.matches('[a-zA-Z0-9]{15,18}',id)?id:'';
    }
    @AuraEnabled(cacheable=true)
    public static Map<String,String> hostConfig() {
        OrgLoomNativeAccess.requireAccess();
        return new Map<String,String>{'visualforceOrigin'=>'https://'+System.DomainCreator.getVisualforceHostname(OrgLoomNativeAccess.packageNamespace()),
            'launchPath'=>Page.OrgLoomNativeLaunch.getUrl()};
    }
    private static Map<String,Object> identity() {
        Organization org = [SELECT Name, IsSandbox, OrganizationType FROM Organization LIMIT 1];
        Boolean testOrg = org.IsSandbox || org.OrganizationType == 'Developer Edition';
        return new Map<String,Object>{'orgId'=>UserInfo.getOrganizationId(),'userId'=>UserInfo.getUserId(),
            'displayName'=>UserInfo.getName(),'timeZone'=>UserInfo.getTimeZone().getID(),'orgName'=>org.Name,
            'testOrg'=>testOrg,'instanceUrl'=>URL.getOrgDomainUrl().toExternalForm(),'lightningOrigin'=>'https://'+System.DomainCreator.getLightningHostname(),
            'canvasTabName'=>OrgLoomNativeAccess.qualifiedName('OrgLoomNativeCanvas')};
    }
    public static Schema.DescribeSObjectResult objectInfo(String name) {
        Schema.SObjectType token=globalObjects().get(name);
        if(token==null)throw new NativeRequestException('Object is unavailable.');
        Schema.DescribeSObjectResult d=token.getDescribe();
        if (!available(d)) throw new NativeRequestException('This object is unavailable or you do not have read access.');
        return d;
    }
    public static Boolean supported(Schema.DescribeFieldResult f) {
        return f.isAccessible() && !new Set<String>{'ADDRESS','LOCATION','BASE64','ENCRYPTEDSTRING','ANYTYPE','COMPLEXVALUE'}.contains(String.valueOf(f.getType()));
    }
    private static Boolean editable(Schema.DescribeFieldResult f) {
        return supported(f) && f.isUpdateable() && !f.isCalculated() && !f.isAutoNumber();
    }
    private static List<String> fields(String name) {
        List<String> result=new List<String>();
        for(Schema.SObjectField token:objectInfo(name).fields.getMap().values()) if(supported(token.getDescribe())) result.add(token.getDescribe().getName());
        result.sort();
        return result;
    }
    public static Map<String,Object> describe(String name) {
        Schema.DescribeSObjectResult d=objectInfo(name);
        List<Object> fs=new List<Object>();
        for(Schema.SObjectField token:d.fields.getMap().values()) {
            Schema.DescribeFieldResult f=token.getDescribe();
            if(!supported(f))continue;
            List<String> targets=new List<String>();for(Schema.SObjectType t:f.getReferenceTo())if(available(t.getDescribe()))targets.add(t.getDescribe().getName());
            List<Object> picks=new List<Object>();
            for(Schema.PicklistEntry p:f.getPicklistValues())if(p.isActive())picks.add(new Map<String,Object>{'label'=>p.getLabel(),'value'=>p.getValue(),'active'=>true,'defaultValue'=>p.isDefaultValue()});
            fs.add(new Map<String,Object>{'name'=>f.getName(),'label'=>f.getLabel(),'type'=>f.getType()==Schema.DisplayType.INTEGER?'int':String.valueOf(f.getType()).toLowerCase(),
                'nameField'=>f.isNameField(),'createable'=>f.isCreateable()&&!f.isCalculated()&&!f.isAutoNumber(),'updateable'=>editable(f),'nillable'=>f.isNillable(),
                'calculated'=>f.isCalculated(),'autoNumber'=>f.isAutoNumber(),'required'=>!f.isNillable()&&!f.isDefaultedOnCreate()&&!f.isAutoNumber()&&f.isCreateable(),'filterable'=>f.isFilterable(),
                'sortable'=>f.isSortable(),'externalId'=>f.isExternalId(),'idLookup'=>f.isIdLookup(),'unique'=>f.isUnique(),'referenceTo'=>targets,'relationshipName'=>f.getRelationshipName(),
                'dependentPicklist'=>f.isDependentPicklist(),'controllerName'=>f.getController()==null?null:f.getController().getDescribe().getName(),
                'restrictedPicklist'=>f.isRestrictedPicklist(),'precision'=>f.getPrecision(),'scale'=>f.getScale(),
                'defaultedOnCreate'=>f.isDefaultedOnCreate(),'picklistValues'=>picks,'length'=>f.getLength()});
        }
        List<Object> types=new List<Object>();String defaultType;
        for(Schema.RecordTypeInfo r:d.getRecordTypeInfos())if(r.isAvailable() && r.isActive()) {
            if(r.isDefaultRecordTypeMapping())defaultType=r.getRecordTypeId();
            // Preserve raw describe keys and the shared editor's normalized keys.
            types.add(new Map<String,Object>{'id'=>r.getRecordTypeId(),'recordTypeId'=>r.getRecordTypeId(),
                'name'=>r.getName(),'label'=>r.getName(),'developerName'=>r.getDeveloperName(),'available'=>true,
                'isDefault'=>r.isDefaultRecordTypeMapping(),'defaultRecordTypeMapping'=>r.isDefaultRecordTypeMapping(),'master'=>r.isMaster()});
        }
        return new Map<String,Object>{'name'=>name,'label'=>d.getLabel(),'labelPlural'=>d.getLabelPlural(),'fields'=>fs,
            'createable'=>d.isCreateable(),'updateable'=>d.isUpdateable(),'deletable'=>d.isDeletable(),'recordTypeInfos'=>types,'recordTypes'=>types,'defaultRecordTypeId'=>defaultType,'childRelationships'=>OrgLoomNativeReads.children(d)};
    }
    public static List<SObject> read(String name, Set<Id> ids, Boolean lockRows) {
        String q='SELECT '+String.join(fields(name),',')+' FROM '+name+' WHERE Id IN :ids'+(lockRows?' FOR UPDATE':'');
        return Database.queryWithBinds(q,new Map<String,Object>{'ids'=>ids},AccessLevel.USER_MODE);
    }
    public static Object convert(Object value, Schema.DescribeFieldResult f) {
        if(value==null)return null;
        String kind=String.valueOf(f.getType());
        if(kind=='DATE')return Date.valueOf(String.valueOf(value));
        if(kind=='DATETIME')return JSON.deserialize(JSON.serialize(value),Datetime.class);
        if(kind=='BOOLEAN')return (Boolean)value;
        if(new Set<String>{'CURRENCY','DOUBLE','INTEGER','PERCENT','LONG'}.contains(kind))return Decimal.valueOf(String.valueOf(value));
        return String.valueOf(value);
    }
    private static Object access(Map<String,Object> body) {
        List<Object> records=(List<Object>)body.get('records');
        if(records.size()>200)throw new NativeRequestException('At most 200 access checks.');
        Set<Id> ids=new Set<Id>();for(Object raw:records)ids.add((Id)(String)((Map<String,Object>)raw).get('sfId'));
        Map<Id,UserRecordAccess> rights=new Map<Id,UserRecordAccess>();
        Id uid=UserInfo.getUserId();
        for(UserRecordAccess r:[SELECT RecordId,HasReadAccess,HasEditAccess,HasDeleteAccess FROM UserRecordAccess WHERE UserId=:uid AND RecordId IN :ids])rights.put(r.RecordId,r);
        List<Object> results=new List<Object>();
        for(Object raw:records) {Map<String,Object> row=(Map<String,Object>)raw;UserRecordAccess r=rights.get((Id)(String)row.get('sfId'));
            results.add(new Map<String,Object>{'tempId'=>row.get('tempId'),'sfId'=>row.get('sfId'),'access'=>new Map<String,Object>{'checked'=>true,'hasReadAccess'=>r!=null&&r.HasReadAccess,'hasEditAccess'=>r!=null&&r.HasEditAccess,'hasDeleteAccess'=>r!=null&&r.HasDeleteAccess}});}
        return new Map<String,Object>{'results'=>results};
    }
    @RemoteAction
    // Global is required by Visualforce remoting inside the Lightning iframe.
    // Authorization remains inside this entry point, before dispatch.
    global static String invoke(String operation, String payload) {
        Savepoint sp;
        try {
            OrgLoomNativeAccess.requireAccess();
            if(payload==null || payload.length()>500000)throw new NativeRequestException('Invalid request size.');
            Map<String,Object> body=(Map<String,Object>)JSON.deserializeUntyped(payload);Object data;
            if(operation=='capabilities')data=new Map<String,Object>{'capabilities'=>OrgLoomNativeAccess.capabilities(),'admin'=>OrgLoomNativeAccess.isAdmin(),'edition'=>'team'};
            else if(operation=='objects') {
                List<Object> result=new List<Object>();
                List<String> names=new List<String>(globalObjects().keySet());names.sort();
                for(String name:names) {Schema.DescribeSObjectResult d=globalObjects().get(name).getDescribe();if(available(d))result.add(new Map<String,Object>{'name'=>d.getName(),'label'=>d.getLabel(),'labelPlural'=>d.getLabelPlural(),'custom'=>d.isCustom(),'queryable'=>true,'createable'=>d.isCreateable(),'updateable'=>d.isUpdateable(),'deletable'=>d.isDeletable()});}
                data=result;
            } else if(operation=='describe')data=describe((String)body.get('objectName'));
            else if(operation=='layout')data=OrgLoomNativeMetadata.layout(body);
            else if(operation.startsWith('reads:'))data=OrgLoomNativeReads.handle(operation.substring(6),body);
            else if(operation=='access')data=access(body);
            else if(operation=='query')data=OrgLoomNativeQuery.run(body);
            else if(operation=='capabilityCheck') {
                String capability=(String)body.get('capability');OrgLoomNativeAccess.requireCapability(capability);
                if(new Set<String>{'run-script','auto-fill-records'}.contains(capability)&&body.get('canvasId')!=null)
                    OrgLoomNativeCanvases.requireLocalTools((Id)(String)body.get('canvasId'),(String)body.get('sessionToken'));
                data=new Map<String,Object>{'allowed'=>true};
            }
            else if(operation=='browse')data=OrgLoomNativeBrowse.browse(body);
            else if(operation=='browseLoad')data=OrgLoomNativeBrowse.load(body);
            else if(operation=='fileLoad')data=OrgLoomNativeBrowse.fileLoad(body);
            else if(operation=='shareUsers')data=OrgLoomNativeCanvases.users(body);
            else if(operation=='migrationMatch')data=OrgLoomNativeMigration.matchRecords(body);
            else if(operation=='history:list')data=OrgLoomNativeHistory.listBatches(body);
            else if(operation=='history:preflight')data=OrgLoomNativeHistory.preflight((Id)(String)body.get('id'));
            else if(operation=='history:recall')data=OrgLoomNativeHistory.recall((Id)(String)body.get('id'),body);
            else if(operation=='history:forget')data=OrgLoomNativeHistory.forget((Id)(String)body.get('id'));
            else if(operation=='loadRecordLink') {
                OrgLoomNativeAccess.requireCapability('browse-records');
                Id id=(Id)(String)body.get('recordId');String name=id.getSObjectType().getDescribe().getName();objectInfo(name);
                List<SObject> rows=read(name,new Set<Id>{id},false);if(rows.isEmpty())throw new NativeRequestException('Record unavailable.');
                data=new Map<String,Object>{'objectName'=>name,'records'=>new List<Object>{new Map<String,Object>{'tempId'=>1,'objectName'=>name,'loadedFromId'=>id,'values'=>rows[0]}},'associations'=>new List<Object>(),'totalSize'=>1,'fullFields'=>true};
            }
            else if(operation=='record') {String name=(String)body.get('objectName');Id id=(Id)(String)body.get('recordId');if(id.getSObjectType()!=objectInfo(name).getSObjectType())throw new NativeRequestException('Invalid object identity.');List<SObject> rows=read(name,new Set<Id>{id},false);if(rows.isEmpty())throw new NativeRequestException('Record unavailable.');data=rows[0];}
            else if(operation=='upload')data=OrgLoomNativeUpload.execute(body);
            else if(operation=='uploadPlan')data=OrgLoomNativeUploadPlan.plan(body);
            else if(operation=='uploadGroup')data=OrgLoomNativeUploadPlan.execute(body);
            else if(operation=='uploadReceipt')data=OrgLoomNativeUpload.receipt((String)body.get('attemptId'));
            else if(operation=='uploadRecovery')data=OrgLoomNativeUploadPlan.recover((String)body.get('attemptId'));
            else if(operation.startsWith('canvas:'))data=OrgLoomNativeCanvases.handle(operation.substring(7),body);
            else if(operation.startsWith('recovery:'))data=OrgLoomNativeRecovery.handle(operation.substring(9),body);
            else throw new NativeRequestException('Unsupported native MVP operation.');
            return JSON.serialize(new Map<String,Object>{'status'=>200,'data'=>data});
        } catch(Exception e) {
            if(sp!=null)Database.rollback(sp);
            OrgLoomNativeActivity.rejected(operation);
            return JSON.serialize(new Map<String,Object>{'status'=>400,'data'=>new Map<String,Object>{'error'=>'native-request-rejected','message'=>e.getMessage()}});
        }
    }
}
