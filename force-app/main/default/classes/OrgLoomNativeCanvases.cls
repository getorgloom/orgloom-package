// Application records/files are accessed in system mode only after explicit owner/grant
// checks. Business records remain user-mode. No method exposes raw keys or ciphertext.
public without sharing class OrgLoomNativeCanvases {
    public class CanvasException extends Exception {}
    public static Object users(Map<String,Object> body) {
        OrgLoomNativeAccess.requireAccess();
        Map<String,Boolean> caps=OrgLoomNativeAccess.capabilities();
        if(caps.get('share-canvas')!=true&&caps.get('create-slot-canvas')!=true)throw new CanvasException('Sharing or request access is required.');
        String search=(String)body.get('q');if(search==null)search='';if(search.length()>100)throw new CanvasException('Search is too long.');
        String likeValue='%'+search.replace('%','\\%').replace('_','\\_')+'%';
        Id current=UserInfo.getUserId();
        List<User> users=[SELECT Id,Name FROM User WHERE IsActive=true AND UserType='Standard' AND Name LIKE :likeValue AND Id!=:current WITH USER_MODE ORDER BY Name LIMIT 20];
        List<Object> result=new List<Object>();for(User u:users)result.add(new Map<String,Object>{'id'=>u.Id,'name'=>u.Name});
        return new Map<String,Object>{'users'=>result};
    }
    private static Object manageShares(OrgLoomNativeCanvas__c c,String op,Map<String,Object> body) {
        OrgLoomNativeAccess.requireCapability('share-canvas');
        if(c.OwnerId!=UserInfo.getUserId())throw new CanvasException('Only the canvas owner can manage access.');
        if(op=='shares'){
            List<Object> shares=new List<Object>();
            for(OrgLoomNativeGrant__c grant:[SELECT Recipient__c,Recipient__r.Name,Role__c FROM OrgLoomNativeGrant__c WHERE Canvas__c=:c.Id])shares.add(new Map<String,Object>{'sfUserId'=>grant.Recipient__c,'name'=>grant.Recipient__r.Name,'role'=>grant.Role__c});
            return new Map<String,Object>{'directShares'=>shares,'count'=>shares.size()};
        }
        Id userId=(Id)(String)body.get('recipientSfUserId');String access=(String)body.get('role');
        if(userId==c.OwnerId||!new Set<String>{'viewer','contributor','editor','none'}.contains(access))throw new CanvasException('Invalid recipient or role.');
        List<User> recipients=[SELECT Id,Name FROM User WHERE Id=:userId AND IsActive=true AND UserType='Standard' WITH USER_MODE];
        if(recipients.isEmpty())throw new CanvasException('Recipient is unavailable.');
        String key=c.Id+':'+userId;
        if(access=='none')delete [SELECT Id FROM OrgLoomNativeGrant__c WHERE Key__c=:key];
        else upsert new OrgLoomNativeGrant__c(Key__c=key,Canvas__c=c.Id,Recipient__c=userId,Role__c=access) Key__c;
        if(c.Holder__c==userId){c.SessionHash__c=null;c.Expires__c=null;c.Holder__c=null;update c;}
        OrgLoomNativeActivity.record('canvas_shared','success',c.Id,'Recipient '+userId+'; access '+access+'.');
        return new Map<String,Object>{'ok'=>true,'recipient'=>new Map<String,Object>{'name'=>recipients[0].Name},'notificationMode'=>'saved-canvases'};
    }
    private static String context(OrgLoomNativeCanvas__c c){return UserInfo.getOrganizationId()+':'+c.Id+':'+c.Revision__c;}
    private static OrgLoomNativeCanvas__c locked(Id id){return [SELECT Id,OwnerId,Title__c,FileId__c,VersionId__c,Revision__c,Holder__c,Holder__r.Name,SessionHash__c,Expires__c FROM OrgLoomNativeCanvas__c WHERE Id=:id LIMIT 1 FOR UPDATE];}
    private static String role(OrgLoomNativeCanvas__c c) {
        if(c.OwnerId==UserInfo.getUserId())return 'owner';
        List<OrgLoomNativeGrant__c> grants=[SELECT Role__c FROM OrgLoomNativeGrant__c WHERE Canvas__c=:c.Id AND Recipient__c=:UserInfo.getUserId() LIMIT 1];
        if(grants.isEmpty())throw new CanvasException('This canvas is not shared with you.');
        OrgLoomNativeAccess.requireCapability('receive-canvas');
        if(!new Set<String>{'viewer','contributor','editor'}.contains(grants[0].Role__c))throw new CanvasException('Invalid canvas access role.');
        return grants[0].Role__c;
    }
    private static String digest(String token){if(token==null||token.length()<32||token.length()>128)throw new CanvasException('Missing canvas session. Reopen the canvas.');return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256',Blob.valueOf(token)));}
    private static String acquire(OrgLoomNativeCanvas__c c,String existing,Boolean takeover,String access) {
        if(access=='viewer')return null;
        Boolean same=existing!=null&&c.Holder__c==UserInfo.getUserId()&&c.SessionHash__c==digest(existing);
        if(!same&&c.Expires__c!=null&&c.Expires__c>System.now()&&takeover!=true){
            if(c.Holder__c==UserInfo.getUserId())throw new CanvasException('OCCUPIED_SELF: You already have this canvas open in another tab or window.');
            throw new CanvasException('OCCUPIED: '+c.Holder__r.Name+' currently has this canvas open.');
        }
        String token=same?existing:EncodingUtil.convertToHex(Crypto.generateAesKey(256));
        c.Holder__c=UserInfo.getUserId();c.SessionHash__c=digest(token);c.Expires__c=System.now().addMinutes(2);update c;return token;
    }
    public static void requireSession(Id canvasId,String token,Boolean uploading) {
        OrgLoomNativeAccess.requireAccess();OrgLoomNativeCanvas__c c=locked(canvasId);String access=role(c);
        if(access=='viewer'||uploading&&access!='owner')throw new CanvasException('Only the canvas owner can upload its changes.');
        if(c.Holder__c!=UserInfo.getUserId()||c.SessionHash__c!=digest(token)||c.Expires__c==null||c.Expires__c<=System.now())throw new CanvasException('SESSION_ENDED: Another session took over, or this session expired. Reopen the canvas.');
    }
    public static void requireLocalTools(Id canvasId,String token) {
        requireSession(canvasId,token,false);
        String access=role(locked(canvasId));
        if(access!='owner'&&access!='editor')throw new CanvasException('Only canvas owners and editors can run scripts or auto-fill records.');
    }
    private static void checkEnvelope(Map<String,Object> payload) {
        if(payload==null||JSON.serialize(payload).length()>250000)throw new CanvasException('Canvas is too large for this native build (250 KB).');
        Map<String,Object> meta=(Map<String,Object>)payload.get('_meta');
        if(meta==null||meta.get('savedFrom')!=UserInfo.getOrganizationId())throw new CanvasException('Reconcile imported records to this org before saving.');
        List<Object> loaded=(List<Object>)payload.get('loadedRecords'),drafts=(List<Object>)payload.get('drafts');
        if(loaded==null||drafts==null||loaded.size()+drafts.size()>100)throw new CanvasException('Saved canvases support up to 100 records in this build.');
    }
    // Recovery is private work, never a published canvas revision. Reuse the
    // same envelope limits, projection and lease checks as saved canvases.
    public static void checkRecoveryPayload(Map<String,Object> value) { checkEnvelope(value); }
    public static Map<String,Object> recoveryContext(Id id,String token,String version) {
        OrgLoomNativeAccess.requireCapability('open-saved-canvas');
        requireSession(id,token,false);OrgLoomNativeCanvas__c c=locked(id);
        if(c.VersionId__c!=version)throw new CanvasException('RECOVERY_STALE: The saved canvas changed. Reopen it.');
        return new Map<String,Object>{'hash'=>c.SessionHash__c,'role'=>role(c)};
    }
    public static Map<String,Object> resumeRecovery(Id id,String hash,String version,String previousRole) {
        OrgLoomNativeAccess.requireCapability('open-saved-canvas');
        OrgLoomNativeCanvas__c c=locked(id);String access=role(c);
        // Expiry alone does not invalidate a draft. A release, takeover, role
        // change or newer saved revision does. Never silently regain authority.
        if(c.Holder__c!=UserInfo.getUserId()||c.SessionHash__c!=hash||c.VersionId__c!=version||access!=previousRole||access=='viewer')
            throw new CanvasException('RECOVERY_STALE: This canvas was saved, closed or taken over elsewhere. Open its latest saved version.');
        Map<String,Object> result=info(c,access);
        OrgLoomNativeProjection.View current=OrgLoomNativeProjection.project(payload(c));
        result.put('nativeNextSlotId',((Map<String,Object>)current.payload.get('_meta')).get('nativeNextSlotId'));
        result.put('partialView',current.partial);
        result.put('sessionToken',acquire(c,null,true,access));return result;
    }
    private static void checkPayload(Map<String,Object> payload) {
        checkEnvelope(payload);
        List<Object> loaded=(List<Object>)payload.get('loadedRecords'),drafts=(List<Object>)payload.get('drafts');
        Map<String,Set<Id>> ids=new Map<String,Set<Id>>();List<Object> all=new List<Object>();all.addAll(loaded);all.addAll(drafts);
        for(Object raw:all){Map<String,Object> r=(Map<String,Object>)raw;String name=(String)r.get('objectName');Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo(name);
            for(String valuesKey:new List<String>{'values','changes','originalValues'})if(r.get(valuesKey)!=null)for(String field:((Map<String,Object>)r.get(valuesKey)).keySet()){
                Schema.SObjectField f=d.fields.getMap().get(field);if(f==null||!OrgLoomNativeController.supported(f.getDescribe()))throw new CanvasException('This canvas contains a field you cannot access.');
            }
            if(r.get('loadedFromId')!=null){Id id=(Id)(String)r.get('loadedFromId');if(id.getSObjectType()!=d.getSObjectType())throw new CanvasException('Invalid record identity.');if(!ids.containsKey(name))ids.put(name,new Set<Id>());ids.get(name).add(id);}
        }
        for(String name:ids.keySet())if(OrgLoomNativeController.read(name,ids.get(name),false).size()!=ids.get(name).size())throw new CanvasException('This canvas contains records you cannot access.');
        // Fail closed for metadata snapshots too; never leak a denied field's saved default value.
        Map<String,Object> schema=(Map<String,Object>)payload.get('schema');if(schema!=null&&schema.get('objects')!=null)for(Object raw:(List<Object>)schema.get('objects')){
            Map<String,Object> objectData=(Map<String,Object>)raw;Schema.DescribeSObjectResult d=OrgLoomNativeController.objectInfo((String)objectData.get('name'));
            for(String fieldList:new List<String>{'fields','draftFields'})if(objectData.get(fieldList)!=null)for(Object rawField:(List<Object>)objectData.get(fieldList)){Map<String,Object> f=(Map<String,Object>)rawField;String field=(String)f.get('name');if(field!=null&&(!d.fields.getMap().containsKey(field)||!d.fields.getMap().get(field).getDescribe().isAccessible()))throw new CanvasException('This canvas contains metadata you cannot access.');}
        }
    }
    private static Map<String,Object> payload(OrgLoomNativeCanvas__c c) {
        ContentVersion version=[SELECT VersionData FROM ContentVersion WHERE Id=:c.VersionId__c LIMIT 1];
        return (Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeCrypto.open(version.VersionData,context(c)));
    }
    private static void store(OrgLoomNativeCanvas__c c,Map<String,Object> body) {
        // Private sink: callers validate the visible delta before merging hidden
        // contents from the existing authenticated encrypted revision.
        checkEnvelope(body);c.Revision__c=(c.Revision__c==null?0:c.Revision__c)+1;
        ContentVersion v=new ContentVersion(Title=c.Title__c,PathOnClient='canvas.orgloom.enc',VersionData=OrgLoomNativeCrypto.seal(JSON.serialize(body),context(c)));
        if(c.FileId__c!=null)v.ContentDocumentId=(Id)c.FileId__c;
        insert v;v=[SELECT Id,ContentDocumentId FROM ContentVersion WHERE Id=:v.Id];c.FileId__c=v.ContentDocumentId;c.VersionId__c=v.Id;update c;
    }
    private static Map<String,Object> info(OrgLoomNativeCanvas__c c,String access){return new Map<String,Object>{'id'=>c.Id,'title'=>c.Title__c,'ownedByMe'=>access=='owner','role'=>access,'recipientRole'=>access=='owner'?null:access,'versionId'=>c.VersionId__c};}
    public static Object handle(String op,Map<String,Object> body) {
        OrgLoomNativeAccess.requireAccess();Savepoint checkpoint=Database.setSavepoint();
        try {
            if(op=='list'){
                OrgLoomNativeAccess.requireCapability('open-saved-canvas');Set<Id> shared=new Set<Id>();for(OrgLoomNativeGrant__c g:[SELECT Canvas__c FROM OrgLoomNativeGrant__c WHERE Recipient__c=:UserInfo.getUserId()])shared.add(g.Canvas__c);
                List<Object> items=new List<Object>();for(OrgLoomNativeCanvas__c c:[SELECT Id,Title__c,OwnerId,VersionId__c FROM OrgLoomNativeCanvas__c WHERE OwnerId=:UserInfo.getUserId() OR Id IN :shared ORDER BY LastModifiedDate DESC LIMIT 100]){try{items.add(info(c,role(c)));}catch(Exception ignored){}}
                return new Map<String,Object>{'items'=>items,'canOpenOwnedCanvases'=>true};
            }
            if(op=='create'){
                OrgLoomNativeAccess.requireCapability('save-canvas');String title=(String)body.get('name');if(String.isBlank(title)||title.length()>120)throw new CanvasException('Choose a canvas name of up to 120 characters.');
                OrgLoomNativeSharedEdits.requests(null,(Map<String,Object>)body.get('payload'));
                checkPayload((Map<String,Object>)body.get('payload'));
                if(OrgLoomNativeProjection.project((Map<String,Object>)body.get('payload')).partial)throw new CanvasException('This canvas includes unavailable content.');
                OrgLoomNativeCanvas__c c=new OrgLoomNativeCanvas__c(Title__c=title,Revision__c=0);insert c;store(c,(Map<String,Object>)body.get('payload'));
                Map<String,Object> result=info(c,'owner');result.put('sessionToken',acquire(c,null,false,'owner'));
                OrgLoomNativeActivity.record('canvas_created','success',c.Id,'New canvas saved.');return result;
            }
            Id id=(Id)(String)body.get('id');OrgLoomNativeCanvas__c c=locked(id);String access=role(c),token=(String)body.get('sessionToken');
            if(op=='shares'||op=='grant')return manageShares(c,op,body);
            if(op=='delete'){
                OrgLoomNativeAccess.requireCapability('save-canvas');
                if(access!='owner')throw new CanvasException('Only the owner can delete a saved canvas.');
                if(c.Expires__c!=null&&c.Expires__c>System.now())requireSession(id,token,false);
                // Remove only this canvas and its encrypted revisions, never the
                // Salesforce business records or independent upload/Recall history.
                Id fileId=(Id)c.FileId__c;
                delete [SELECT Id FROM OrgLoomNativeGrant__c WHERE Canvas__c=:id];
                delete c;
                if(fileId!=null)delete [SELECT Id FROM ContentDocument WHERE Id=:fileId];
                OrgLoomNativeActivity.record('canvas_deleted','success',id,'Saved canvas deleted.');
                return new Map<String,Object>{'ok'=>true};
            }
            if(op=='release'){
                // A stale tab may release only its own lease, never a replacement session.
                if(c.Holder__c==UserInfo.getUserId()&&c.SessionHash__c==digest(token)){
                    c.Holder__c=null;c.SessionHash__c=null;c.Expires__c=null;update c;
                }
                return new Map<String,Object>{'ok'=>true};
            }
            if(op=='open'){
                OrgLoomNativeAccess.requireCapability('open-saved-canvas');Map<String,Object> contents=payload(c);checkEnvelope(contents);
                OrgLoomNativeProjection.View view=OrgLoomNativeProjection.project(contents);
                Map<String,Object> result=info(c,access);result.put('sessionToken',acquire(c,token,body.get('takeover')==true,access));result.put('payload',view.payload);result.put('partialView',view.partial);return result;
            }
            if(op=='heartbeat'){requireSession(id,token,false);c.Expires__c=System.now().addMinutes(2);update c;return new Map<String,Object>{'ok'=>true};}
            if(op=='fill'){
                requireSession(id,token,false);
                if(access!='contributor'&&access!='editor')throw new CanvasException('Contributor or editor access is required.');
                if(body.get('expectedVersionId')!=c.VersionId__c)throw new CanvasException('The saved canvas changed. Reopen it before submitting.');
                Map<String,Object> contents=payload(c);
                OrgLoomNativeProjection.View view=OrgLoomNativeProjection.project(contents);
                // Validate only requests that this user actually receives. Applying
                // the validated fill to the full revision preserves hidden fields.
                OrgLoomNativeProjection.validateFills(contents,view,(List<Object>)body.get('fills'));
                OrgLoomNativeRequests.apply(view.payload,(List<Object>)body.get('fills'));
                Integer submitted=OrgLoomNativeRequests.apply(contents,(List<Object>)body.get('fills'));
                store(c,contents);OrgLoomNativeActivity.record('requests_submitted','success',id,submitted+' requested changes submitted.');return new Map<String,Object>{'submitted'=>submitted,'versionId'=>c.VersionId__c};
            }
            if(op=='save'){
                OrgLoomNativeAccess.requireCapability('save-canvas');requireSession(id,token,false);
                if(access!='owner'&&access!='editor')throw new CanvasException('Contributors can only submit requested changes.');
                if(body.get('expectedVersionId')!=c.VersionId__c)throw new CanvasException('The saved canvas changed. Reopen it before saving.');
                Map<String,Object> before=payload(c),after=(Map<String,Object>)body.get('payload');
                checkPayload(after);
                OrgLoomNativeProjection.View view=OrgLoomNativeProjection.project(before);
                OrgLoomNativeSharedEdits.requests(view.payload,after);
                if(access=='editor')OrgLoomNativeSharedEdits.validate(view.payload,after);
                Map<String,Object> merged=OrgLoomNativeProjection.mergeVisible(before,view,after);
                store(c,merged);OrgLoomNativeActivity.record('canvas_saved','success',id,'Canvas revision saved.');return info(c,access);
            }
            throw new CanvasException('Unsupported canvas operation.');
        } catch(Exception e){Database.rollback(checkpoint);throw e;}
    }
}
