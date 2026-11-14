/**
 * @description Starts the HR integration when a course is finished.
 *  - Before save: a course that becomes Completed gets HR Sync Status = Pending.
 *  - After save:  every course that just became "Completed + Pending" is handed to
 *                 HRSyncQueueable (callouts are not allowed directly inside a trigger).
 * Retry: an admin sets HR Sync Status back to Pending on a Completed course.
 */
public with sharing class CourseTriggerHandler {

    public static final String STATUS_COMPLETED = 'Completed';
    public static final String SYNC_PENDING = 'Pending';
    public static final String SYNC_SENT = 'Sent';
    public static final String SYNC_FAILED = 'Failed';

    public static void handle(System.TriggerOperation operation, List<Course__c> newList,
                              Map<Id, Course__c> oldMap) {
        switch on operation {
            when BEFORE_INSERT, BEFORE_UPDATE {
                flagCompletedCourses(newList, oldMap);
            }
            when AFTER_INSERT, AFTER_UPDATE {
                enqueueHrSync(newList, oldMap);
            }
        }
    }

    private static void flagCompletedCourses(List<Course__c> newList, Map<Id, Course__c> oldMap) {
        for (Course__c c : newList) {
            Course__c old = oldMap == null ? null : oldMap.get(c.Id);
            if (c.Status__c == STATUS_COMPLETED && (old == null || old.Status__c != STATUS_COMPLETED)) {
                c.HR_Sync_Status__c = SYNC_PENDING;
                c.HR_Sync_Message__c = null;
            }
        }
    }

    private static void enqueueHrSync(List<Course__c> newList, Map<Id, Course__c> oldMap) {
        List<Id> courseIds = new List<Id>();
        for (Course__c c : newList) {
            Course__c old = oldMap == null ? null : oldMap.get(c.Id);
            Boolean isPending = c.Status__c == STATUS_COMPLETED && c.HR_Sync_Status__c == SYNC_PENDING;
            Boolean wasPending = old != null && old.Status__c == STATUS_COMPLETED
                && old.HR_Sync_Status__c == SYNC_PENDING;
            if (isPending && !wasPending) {
                courseIds.add(c.Id);
            }
        }
        // One job for the whole batch, and only if the transaction may still enqueue one.
        if (!courseIds.isEmpty() && Limits.getQueueableJobs() < Limits.getLimitQueueableJobs()) {
            System.enqueueJob(new HRSyncQueueable(courseIds));
        }
    }
}