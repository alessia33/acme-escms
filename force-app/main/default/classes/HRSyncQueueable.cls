/**
 * @description Sends finished courses and their participants to the external HR system.
 * Asynchronous (Queueable) because callouts cannot run inside a trigger transaction.
 * The endpoint and authentication live in the Named Credential "HR_System" - nothing is
 * hard-coded here. One POST per course; at most MAX_COURSES_PER_JOB courses per job, the
 * rest are passed to a new job (stays inside callout limits however many courses finish).
 * The result is written back to the course (HR Sync Status / Message / Date).
 */
public without sharing class HRSyncQueueable implements Queueable, Database.AllowsCallouts {

    @TestVisible
    private static final Integer MAX_COURSES_PER_JOB = 10;
    private static final String ENDPOINT = 'callout:HR_System';

    private List<Id> courseIds;

    public HRSyncQueueable(List<Id> courseIds) {
        this.courseIds = courseIds;
    }

    public void execute(QueueableContext context) {
        List<Id> current = new List<Id>();
        List<Id> remaining = new List<Id>();
        for (Integer i = 0; i < courseIds.size(); i++) {
            if (i < MAX_COURSES_PER_JOB) {
                current.add(courseIds[i]);
            } else {
                remaining.add(courseIds[i]);
            }
        }

        List<Course__c> courses = [
            SELECT Id, Name, Topic__c, Start_Date__c, End_Date__c
            FROM Course__c
            WHERE Id IN :current];

        Map<Id, List<Object>> participantsByCourse = new Map<Id, List<Object>>();
        for (Enrollment__c e : [
                SELECT Employee__r.Name, Employee__r.Email__c, Employee__r.Employee_Number__c,
                       Training_Session__r.Name, Training_Session__r.Start_Time__c,
                       Training_Session__r.End_Time__c, Training_Session__r.Course__c
                FROM Enrollment__c
                WHERE Training_Session__r.Course__c IN :current
                  AND Status__c = :EnrollmentTriggerHandler.STATUS_ENROLLED
                  AND Training_Session__r.Status__c = :TrainingSessionTriggerHandler.STATUS_SCHEDULED
                ORDER BY Employee__r.Name]) {
            Id courseId = e.Training_Session__r.Course__c;
            if (!participantsByCourse.containsKey(courseId)) {
                participantsByCourse.put(courseId, new List<Object>());
            }
            participantsByCourse.get(courseId).add(new Map<String, Object>{
                'employeeNumber' => e.Employee__r.Employee_Number__c,
                'name' => e.Employee__r.Name,
                'email' => e.Employee__r.Email__c,
                'session' => e.Training_Session__r.Name,
                'sessionStart' => e.Training_Session__r.Start_Time__c,
                'sessionEnd' => e.Training_Session__r.End_Time__c
            });
        }

        // All callouts first, then one DML (a callout is not allowed after DML).
        List<Course__c> updates = new List<Course__c>();
        for (Course__c c : courses) {
            Course__c result = new Course__c(Id = c.Id, HR_Sync_Date__c = System.now());
            try {
                List<Object> participants = participantsByCourse.containsKey(c.Id)
                    ? participantsByCourse.get(c.Id) : new List<Object>();
                HttpRequest request = new HttpRequest();
                request.setEndpoint(ENDPOINT);
                request.setMethod('POST');
                request.setHeader('Content-Type', 'application/json');
                request.setTimeout(10000);
                request.setBody(JSON.serialize(new Map<String, Object>{
                    'courseId' => c.Id,
                    'courseName' => c.Name,
                    'topic' => c.Topic__c,
                    'startDate' => c.Start_Date__c,
                    'endDate' => c.End_Date__c,
                    'participants' => participants
                }));
                HttpResponse response = new Http().send(request);
                Boolean ok = response.getStatusCode() >= 200 && response.getStatusCode() < 300;
                result.HR_Sync_Status__c = ok
                    ? CourseTriggerHandler.SYNC_SENT : CourseTriggerHandler.SYNC_FAILED;
                result.HR_Sync_Message__c = ('HTTP ' + response.getStatusCode() + ' ' + response.getStatus()
                    + ' - ' + participants.size() + ' participant record(s)').abbreviate(255);
            } catch (Exception ex) {
                result.HR_Sync_Status__c = CourseTriggerHandler.SYNC_FAILED;
                result.HR_Sync_Message__c = ('' + ex.getMessage()).abbreviate(255);
            }
            updates.add(result);
        }
        if (!updates.isEmpty()) {
            update updates;
        }
        if (!remaining.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new HRSyncQueueable(remaining));
        }
    }
}