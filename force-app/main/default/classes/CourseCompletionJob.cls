/**
 * @description Runs every night. Marks courses whose End Date has passed as Completed.
 * CourseTrigger then sends them to the HR system. Batch Apex is used so that any number
 * of courses can be processed; a scope of 10 matches HRSyncQueueable.MAX_COURSES_PER_JOB.
 * Schedule once from Execute Anonymous:
 *   System.schedule('ACME Daily Course Completion', '0 0 1 * * ?', new CourseCompletionJob());
 * "without sharing": a system job that must process every course.
 */
public without sharing class CourseCompletionJob implements Database.Batchable<SObject>, Schedulable {

    public void execute(SchedulableContext context) {
        Database.executeBatch(new CourseCompletionJob(), 10);
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator([
            SELECT Id, Status__c
            FROM Course__c
            WHERE End_Date__c < TODAY AND Status__c IN ('Planned', 'Active')]);
    }

    public void execute(Database.BatchableContext context, List<Course__c> scope) {
        for (Course__c c : scope) {
            c.Status__c = CourseTriggerHandler.STATUS_COMPLETED;
        }
        update scope;
    }

    public void finish(Database.BatchableContext context) {
        System.debug(LoggingLevel.INFO, 'CourseCompletionJob finished.');
    }
}