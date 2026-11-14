/**
 * @description Tests for CourseTriggerHandler, HRSyncQueueable and CourseCompletionJob.
 * The HR system is replaced by a mock: unit tests never make real callouts.
 */
@isTest
private class CourseHRSyncTest {

    private class HRSystemMock implements HttpCalloutMock {
        private Integer statusCode;
        public HRSystemMock(Integer statusCode) {
            this.statusCode = statusCode;
        }
        public HttpResponse respond(HttpRequest request) {
            lastRequestBody = request.getBody();
            HttpResponse response = new HttpResponse();
            response.setStatusCode(statusCode);
            response.setStatus(statusCode == 200 ? 'OK' : 'Server Error');
            response.setBody('{"received":true}');
            return response;
        }
    }

    private static String lastRequestBody;

    @testSetup
    static void setup() {
        Id me = UserInfo.getUserId();
        Course__c course = TestDataFactory.createCourse('Negotiation Basics');
        Training_Session__c session = TestDataFactory.buildSession(
            course.Id, TestDataFactory.createVenue(5).Id, me, Datetime.now().addDays(10), 2);
        insert session;
        Employee__c employee = TestDataFactory.createEmployees(1, me)[0];
        insert TestDataFactory.buildEnrollment(employee.Id, session.Id);
    }

    private static Course__c getCourse() {
        return [SELECT Id, Status__c, HR_Sync_Status__c, HR_Sync_Message__c, HR_Sync_Date__c
                FROM Course__c LIMIT 1];
    }

    @isTest
    static void completedCourseIsSentToHr() {
        Test.setMock(HttpCalloutMock.class, new HRSystemMock(200));
        Course__c course = getCourse();

        Test.startTest();
        course.Status__c = 'Completed';
        update course;
        Assert.areEqual(1, Limits.getQueueableJobs(), 'Completing a course must enqueue the HR job');
        Test.stopTest();

        course = getCourse();
        Assert.areEqual('Sent', course.HR_Sync_Status__c, course.HR_Sync_Message__c);
        Assert.isNotNull(course.HR_Sync_Date__c, 'Sync date must be stamped');
    }

    @isTest
    static void payloadContainsCourseAndParticipants() {
        Test.setMock(HttpCalloutMock.class, new HRSystemMock(200));
        Course__c course = getCourse();

        Test.startTest();
        new HRSyncQueueable(new List<Id>{ course.Id }).execute(null);
        Test.stopTest();

        Assert.isTrue(lastRequestBody.contains('Negotiation Basics'), 'Payload must contain the course');
        Assert.isTrue(lastRequestBody.contains('Test Employee 0'), 'Payload must contain the participant');
        Assert.areEqual('Sent', getCourse().HR_Sync_Status__c, 'Result must be written to the course');
    }

    @isTest
    static void hrErrorIsRecordedOnTheCourse() {
        Test.setMock(HttpCalloutMock.class, new HRSystemMock(500));
        Course__c course = getCourse();

        Test.startTest();
        new HRSyncQueueable(new List<Id>{ course.Id }).execute(null);
        Test.stopTest();

        course = getCourse();
        Assert.areEqual('Failed', course.HR_Sync_Status__c, 'A 500 answer must be stored as Failed');
        Assert.isTrue(course.HR_Sync_Message__c.contains('500'), 'The HTTP status must be recorded');
    }

    @isTest
    static void failedSyncCanBeRetried() {
        Test.setMock(HttpCalloutMock.class, new HRSystemMock(200));
        Course__c course = getCourse();
        course.Status__c = 'Completed';
        update course;
        course.HR_Sync_Status__c = 'Failed'; // simulate the result of a failed run
        update course;

        Test.startTest();
        course.HR_Sync_Status__c = 'Pending'; // what an admin does to retry
        update course;
        Assert.areEqual(1, Limits.getQueueableJobs(), 'Setting Pending again must enqueue a new job');
        Test.stopTest();

        Assert.areEqual('Sent', getCourse().HR_Sync_Status__c, 'The retry must send the course');
    }

    @isTest
    static void batchCompletesCoursesThatHaveEnded() {
        Test.setMock(HttpCalloutMock.class, new HRSystemMock(200));
        Course__c ended = new Course__c(
            Name = 'Ended Course', Topic__c = 'Communication', Status__c = 'Active',
            Start_Date__c = Date.today().addDays(-20), End_Date__c = Date.today().addDays(-1));
        insert ended;
        CourseCompletionJob job = new CourseCompletionJob();
        Assert.isNotNull(job.start(null), 'The batch must return a query locator');

        Test.startTest();
        job.execute(null, [SELECT Id, Status__c FROM Course__c WHERE Id = :ended.Id]);
        Test.stopTest();
        job.finish(null);

        ended = [SELECT Status__c, HR_Sync_Status__c FROM Course__c WHERE Id = :ended.Id];
        Assert.areEqual('Completed', ended.Status__c, 'Ended courses must be completed');
        Assert.areEqual('Sent', ended.HR_Sync_Status__c, 'Completed courses must be sent to HR');
    }

    @isTest
    static void jobCanBeScheduled() {
        Test.startTest();
        Id jobId = System.schedule('ACME Daily Course Completion TEST', '0 0 1 * * ?',
            new CourseCompletionJob());
        Test.stopTest();
        Assert.isNotNull(jobId, 'The job must be scheduled');
    }
}