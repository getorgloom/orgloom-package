// Native-only private, encrypted checkpoints. System-mode access is limited to
// the current OwnerId; an identifier never grants access. No business DML here.
public without sharing class OrgLoomNativeRecovery {
    public class RecoveryException extends Exception {}
    private static String digest(String value) {
        if(value==null||!Pattern.matches('[a-f0-9]{64}',value))throw new RecoveryException('Invalid recovery identifier.');
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256',Blob.valueOf(value)));
    }
    private static String context(OrgLoomNativeRecovery__c r) {return UserInfo.getOrganizationId()+':recovery:'+r.OwnerId+':'+r.Key__c+':'+r.Sequence__c;}
    private static void removeFile(OrgLoomNativeRecovery__c r) {
        if(r.FileId__c!=null)delete [SELECT Id FROM ContentDocument WHERE Id=:r.FileId__c];
        r.FileId__c=null;r.VersionId__c=null;
    }
    public static Object handle(String op,Map<String,Object> body) {
        OrgLoomNativeAccess.requireAccess();Savepoint sp=Database.setSavepoint();
        try {return dispatch(op,body);}catch(Exception e){Database.rollback(sp);throw e;}
    }
    private static Object dispatch(String op,Map<String,Object> body) {
        String key=(String)body.get('key');digest(key);
        List<OrgLoomNativeRecovery__c> found=[SELECT Id,OwnerId,Key__c,WriterHash__c,Sequence__c,CanvasId__c,CanvasVersion__c,CanvasSessionHash__c,Role__c,FileId__c,VersionId__c,Expires__c,SavedAt__c,Status__c FROM OrgLoomNativeRecovery__c WHERE Key__c=:key AND OwnerId=:UserInfo.getUserId() LIMIT 1 FOR UPDATE];
        OrgLoomNativeRecovery__c r=found.isEmpty()?null:found[0];
        if(op=='peek'){
            Boolean available=r!=null&&r.Status__c=='active'&&r.Expires__c>System.now();
            Boolean stale=available&&r.CanvasId__c!=null&&!OrgLoomNativeCanvases.recoveryIsCurrent((Id)r.CanvasId__c,r.CanvasSessionHash__c,r.CanvasVersion__c,r.Role__c);
            return new Map<String,Object>{'available'=>available&&!stale,'stale'=>stale,'savedAt'=>r?.SavedAt__c,'sequence'=>r?.Sequence__c,'canvasId'=>r?.CanvasId__c};
        }
        if(!new Set<String>{'write','restore','discard'}.contains(op))throw new RecoveryException('Unknown recovery operation.');
        if(r!=null&&(r.Status__c!='active'||r.Expires__c<=System.now()))throw new RecoveryException('RECOVERY_STALE: This recovery draft expired or was discarded.');
        String writer=digest((String)body.get('writer'));
        if(op=='restore') {
            if(r==null)throw new RecoveryException('Recovery draft is unavailable.');
            if(r.Sequence__c!=Decimal.valueOf(String.valueOf(body.get('sequence'))))throw new RecoveryException('RECOVERY_STALE: The other tab has newer changes. Reload before restoring.');
            Map<String,Object> result=new Map<String,Object>();
            if(r.CanvasId__c!=null){
                result=OrgLoomNativeCanvases.resumeRecovery((Id)r.CanvasId__c,r.CanvasSessionHash__c,r.CanvasVersion__c,r.Role__c);
                r.CanvasSessionHash__c=EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256',Blob.valueOf((String)result.get('sessionToken'))));
            }
            ContentVersion file=[SELECT VersionData FROM ContentVersion WHERE Id=:r.VersionId__c LIMIT 1];
            Map<String,Object> payload=(Map<String,Object>)JSON.deserializeUntyped(OrgLoomNativeCrypto.open(file.VersionData,context(r)));
            OrgLoomNativeCanvases.checkRecoveryPayload(payload);
            OrgLoomNativeProjection.View view=OrgLoomNativeProjection.project(payload);
            if(result.get('nativeNextSlotId')!=null){
                Map<String,Object> meta=(Map<String,Object>)view.payload.get('_meta');
                meta.put('nativeNextSlotId',Math.max(Decimal.valueOf(String.valueOf(meta.get('nativeNextSlotId'))),Decimal.valueOf(String.valueOf(result.get('nativeNextSlotId')))));
            }
            result.put('payload',view.payload);result.put('partialView',view.partial||result.get('partialView')==true);result.put('savedAt',r.SavedAt__c);
            // Claiming rotates the in-memory writer capability. A copied tab
            // cannot keep checkpointing over the resumed session.
            r.WriterHash__c=writer;update r;return result;
        }
        Boolean reviewedDiscard=op=='discard'&&body.get('reviewed')==true&&r!=null&&r.Sequence__c==Decimal.valueOf(String.valueOf(body.get('sequence')));
        if(r!=null&&r.WriterHash__c!=writer&&!reviewedDiscard)throw new RecoveryException('RECOVERY_STALE: This recovery draft is active in another tab.');
        if(op=='discard') {
            // Keep a small tombstone until cleanup so a delayed write cannot
            // recreate a discarded checkpoint. Payload/file are removed now.
            if(r==null){r=new OrgLoomNativeRecovery__c(Key__c=key,WriterHash__c=writer,OwnerId=UserInfo.getUserId());}
            removeFile(r);r.Status__c='cleared';r.Expires__c=System.now().addHours(24);upsert r;return new Map<String,Object>{'ok'=>true};
        }
        Map<String,Object> payload=(Map<String,Object>)body.get('payload');
        OrgLoomNativeCanvases.checkRecoveryPayload(payload);
        String canvasId=(String)body.get('canvasId'),version=(String)body.get('versionId');
        Map<String,Object> binding=canvasId==null?null:OrgLoomNativeCanvases.recoveryContext((Id)canvasId,(String)body.get('sessionToken'),version);
        if(r==null){
            if([SELECT COUNT() FROM OrgLoomNativeRecovery__c WHERE OwnerId=:UserInfo.getUserId() AND Status__c='active' AND Expires__c>:System.now()]>=10)throw new RecoveryException('Recovery supports up to 10 active tabs. Close and discard unused drafts.');
            r=new OrgLoomNativeRecovery__c(Key__c=key,WriterHash__c=writer,Sequence__c=0,OwnerId=UserInfo.getUserId());
        }else if(r.CanvasId__c!=canvasId||r.CanvasVersion__c!=version)throw new RecoveryException('RECOVERY_STALE: The canvas changed since this checkpoint.');
        Decimal sequence=Decimal.valueOf(String.valueOf(body.get('sequence')));
        if(sequence<=r.Sequence__c)throw new RecoveryException('RECOVERY_STALE: A newer checkpoint already exists.');
        // Discard inaccessible content before writing and recheck again on restore.
        OrgLoomNativeProjection.View view=OrgLoomNativeProjection.project(payload);
        r.Sequence__c=sequence;r.CanvasId__c=canvasId;r.CanvasVersion__c=version;r.CanvasSessionHash__c=binding==null?null:(String)binding.get('hash');r.Role__c=binding==null?'owner':(String)binding.get('role');
        ContentVersion file=new ContentVersion(Title='Org Loom recovery',PathOnClient='recovery.orgloom.enc',SharingPrivacy='P',SharingOption='R',VersionData=OrgLoomNativeCrypto.seal(JSON.serialize(view.payload),context(r)));
        insert file;file=[SELECT Id,ContentDocumentId FROM ContentVersion WHERE Id=:file.Id];
        // Replace atomically with a new document, not accumulating file versions.
        removeFile(r);r.FileId__c=file.ContentDocumentId;r.VersionId__c=file.Id;r.SavedAt__c=System.now();r.Expires__c=System.now().addHours(24);r.Status__c='active';upsert r;
        return new Map<String,Object>{'savedAt'=>r.SavedAt__c,'sequence'=>r.Sequence__c,'partialView'=>view.partial};
    }
}
