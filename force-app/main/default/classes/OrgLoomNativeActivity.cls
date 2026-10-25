// System-mode access is deliberate: this private application log is org-wide,
// available only after requireAdmin. No business record values are stored.
public without sharing class OrgLoomNativeActivity {
    public class ActivityException extends Exception {}
    private static final Map<String,String> ACTIONS=new Map<String,String>{
        'upload'=>'Upload to Salesforce','recall'=>'Upload recalled','canvas_created'=>'Canvas saved',
        'canvas_saved'=>'Canvas updated','canvas_deleted'=>'Canvas deleted','canvas_shared'=>'Canvas access changed',
        'requests_submitted'=>'Requests submitted','records_refreshed'=>'Records refreshed'};
    public Boolean getAllowed(){try{OrgLoomNativeAccess.requireAdmin();return true;}catch(Exception e){return false;}}
    // Called only by server operations, inside their transaction. Not a remote endpoint.
    public static void record(String action,String status,Id reference,String detail){
        OrgLoomNativeAccess.requireAccess();
        if(!ACTIONS.containsKey(action)||!new Set<String>{'success','partial','failed'}.contains(status))throw new ActivityException('Invalid activity type.');
        insert new OrgLoomNativeActivity__c(Action__c=action,Status__c=status,Reference__c=reference,Detail__c=detail);
    }
    public static void rejected(String operation){
        Map<String,String> actions=new Map<String,String>{'upload'=>'upload','uploadPlan'=>'upload','uploadGroup'=>'upload',
            'history:recall'=>'recall','canvas:create'=>'canvas_created','canvas:save'=>'canvas_saved','canvas:delete'=>'canvas_deleted',
            'canvas:grant'=>'canvas_shared','canvas:fill'=>'requests_submitted','reads:refresh'=>'records_refreshed'};
        if(!actions.containsKey(operation))return;
        // Never retain exception text, request data, or unvalidated identifiers.
        try{record(actions.get(operation),'failed',null,'Request rejected. No changes from this operation were committed.');}
        catch(Exception ignored){/* A logging failure must not mask the original rejection. */}
    }
    public static void uploaded(Id receipt,List<Object> results,List<Object> deletes){
        Integer created=0,updated=0;
        for(Object raw:results){Map<String,Object> r=(Map<String,Object>)raw;if(r.get('mode')=='create')created++;else updated++;}
        record('upload','success',receipt,created+' created; '+updated+' updated; '+deletes.size()+' deleted. One committed batch.');
    }
    public static Map<String,Object> listEvents(Map<String,Object> body){
        OrgLoomNativeAccess.requireAdmin();
        List<String> predicates=new List<String>();Map<String,Object> binds=new Map<String,Object>();
        String action=(String)body.get('action'),status=(String)body.get('status');
        if(String.isNotBlank(action)){if(!ACTIONS.containsKey(action))throw new ActivityException('Choose a valid action.');predicates.add('Action__c = :action');binds.put('action',action);}
        if(String.isNotBlank(status)){if(!new Set<String>{'success','partial','failed'}.contains(status))throw new ActivityException('Choose a valid status.');predicates.add('Status__c = :status');binds.put('status',status);}
        if(String.isNotBlank((String)body.get('userId'))){Id actor=(Id)(String)body.get('userId');if(actor.getSObjectType()!=User.SObjectType)throw new ActivityException('Choose a Salesforce user.');predicates.add('CreatedById = :actor');binds.put('actor',actor);}
        Date fromDate,toDate;
        if(String.isNotBlank((String)body.get('from')))fromDate=Date.valueOf((String)body.get('from'));
        if(String.isNotBlank((String)body.get('to')))toDate=Date.valueOf((String)body.get('to'));
        if(fromDate!=null&&toDate!=null&&fromDate>toDate)throw new ActivityException('The start date must precede the end date.');
        if(fromDate!=null){predicates.add('CreatedDate >= :startAt');binds.put('startAt',Datetime.newInstance(fromDate,Time.newInstance(0,0,0,0)));}
        if(toDate!=null){predicates.add('CreatedDate < :endAt');binds.put('endAt',Datetime.newInstance(toDate.addDays(1),Time.newInstance(0,0,0,0)));}
        if(body.get('beforeId')!=null){
            Id beforeId=(Id)(String)body.get('beforeId');if(beforeId.getSObjectType()!=OrgLoomNativeActivity__c.SObjectType)throw new ActivityException('Invalid activity cursor.');
            Datetime beforeAt=(Datetime)JSON.deserialize(JSON.serialize(body.get('beforeAt')),Datetime.class);
            if(beforeAt==null)throw new ActivityException('Invalid activity cursor.');
            predicates.add('(CreatedDate < :beforeAt OR (CreatedDate = :beforeAt AND Id < :beforeId))');binds.put('beforeId',beforeId);binds.put('beforeAt',beforeAt);
        }
        String query='SELECT Id,CreatedDate,CreatedById,CreatedBy.Name,Action__c,Status__c,Reference__c,Detail__c FROM '+OrgLoomNativeActivity__c.SObjectType.getDescribe().getName();
        if(!predicates.isEmpty())query+=' WHERE '+String.join(predicates,' AND ');
        List<OrgLoomNativeActivity__c> found=Database.queryWithBinds(query+' ORDER BY CreatedDate DESC,Id DESC LIMIT 51',binds,AccessLevel.SYSTEM_MODE);
        Boolean more=found.size()>50;if(more)found.remove(50);
        List<Object> rows=new List<Object>();for(OrgLoomNativeActivity__c row:found)rows.add(new Map<String,Object>{
            'id'=>row.Id,'when'=>row.CreatedDate,'userId'=>row.CreatedById,'user'=>row.CreatedBy.Name,'action'=>ACTIONS.get(row.Action__c),
            'status'=>row.Status__c,'reference'=>row.Reference__c,'detail'=>row.Action__c=='canvas_deleted'&&row.Status__c=='success'?'Saved canvas deleted.':row.Detail__c});
        Object cursor=more?new Map<String,Object>{'beforeId'=>found[found.size()-1].Id,'beforeAt'=>found[found.size()-1].CreatedDate}:null;
        return new Map<String,Object>{'rows'=>rows,'next'=>cursor,'actions'=>ACTIONS,'timeZone'=>UserInfo.getTimeZone().getID()};
    }
    @RemoteAction public static String invoke(String operation,String payload){
        try{
            OrgLoomNativeAccess.requireAdmin();
            if(payload==null||payload.length()>4000)throw new ActivityException('Invalid request.');
            Map<String,Object> body=(Map<String,Object>)JSON.deserializeUntyped(payload);Object data;
            if(operation=='list')data=listEvents(body);
            else if(operation=='users'){
                String search=(String)body.get('search');if(search==null)search='';if(search.length()>100)throw new ActivityException('Search is too long.');
                String term='%'+search.replace('%','\\%').replace('_','\\_')+'%';
                data=[SELECT Id,Name,Username FROM User WHERE Name LIKE :term OR Username LIKE :term ORDER BY Name,Id LIMIT 50];
            }else throw new ActivityException('Unsupported activity operation.');
            return JSON.serialize(new Map<String,Object>{'status'=>200,'data'=>data});
        }catch(Exception e){return JSON.serialize(new Map<String,Object>{'status'=>400,'data'=>new Map<String,Object>{'message'=>'Activity is unavailable. Check your administrator access and filters.'}});}
    }
}
