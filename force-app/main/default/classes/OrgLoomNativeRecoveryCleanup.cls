// Maintenance has no client entry point. Delete only expired app checkpoints
// and their encrypted documents. Salesforce recycle-bin rules still apply.
public without sharing class OrgLoomNativeRecoveryCleanup implements Schedulable, Database.Batchable<SObject> {
    @TestVisible private static String jobName='Org Loom recovery cleanup';
    public void execute(SchedulableContext sc) {Database.executeBatch(new OrgLoomNativeRecoveryCleanup(),25);}
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([SELECT Id FROM OrgLoomNativeRecovery__c WHERE Expires__c<=:System.now()]);
    }
    public void execute(Database.BatchableContext bc,List<SObject> scope) {
        Set<Id> ids=new Set<Id>();for(SObject row:scope)ids.add(row.Id);
        // Recheck under lock: a checkpoint may have been refreshed since start.
        List<OrgLoomNativeRecovery__c> expired=[SELECT Id,FileId__c FROM OrgLoomNativeRecovery__c WHERE Id IN :ids AND Expires__c<=:System.now() FOR UPDATE];
        Set<Id> files=new Set<Id>();for(OrgLoomNativeRecovery__c r:expired)if(r.FileId__c!=null)files.add((Id)r.FileId__c);
        delete [SELECT Id FROM ContentDocument WHERE Id IN :files];delete expired;
    }
    public void finish(Database.BatchableContext bc) {}
    public static void ensureScheduled() {
        // This helper is callable by Apex, but only app admins may schedule it.
        OrgLoomNativeAccess.requireAdmin();scheduleOnce();
    }
    public static void scheduleOnce() {
        String dailySchedule='0 0 2 * * ?';
        for(CronTrigger job:[SELECT Id,CronExpression FROM CronTrigger WHERE CronJobDetail.Name=:jobName AND State NOT IN ('DELETED','COMPLETE','ERROR')]) {
            if(job.CronExpression==dailySchedule)return;
            System.abortJob(job.Id);
        }
        System.schedule(jobName,dailySchedule,new OrgLoomNativeRecoveryCleanup());
    }
}
