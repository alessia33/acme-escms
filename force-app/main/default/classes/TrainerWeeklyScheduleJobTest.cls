/**
 * @description Tests for TrainerWeeklyScheduleJob.
 */
@isTest
private class TrainerWeeklyScheduleJobTest {

    @testSetup
    static void setup() {
        Id me = UserInfo.getUserId();
        Course__c course = TestDataFactory.createCourse('Public Speaking');
        Id venueId = TestDataFactory.createVenue(5).Id;
        insert new List<Training_Session__c>{
            TestDataFactory.buildSession(course.Id, venueId, me, Datetime.now().addDays(2), 2),
            TestDataFactory.buildSession(course.Id, venueId, me, Datetime.now().addDays(4), 2),
            TestDataFactory.buildSession(course.Id, venueId, me, Datetime.now().addDays(30), 2)
        };
    }

    @isTest
    static void oneEmailPerTrainer() {
        Test.startTest();
        TrainerWeeklyScheduleJob.sendSchedules();
        Test.stopTest();
        Assert.areEqual(1, TrainerWeeklyScheduleJob.emailsPrepared,
            'One email for the trainer, listing both sessions of the next 7 days');
    }

    @isTest
    static void noEmailWhenNothingIsScheduled() {
        delete [SELECT Id FROM Training_Session__c];
        TrainerWeeklyScheduleJob.sendSchedules();
        Assert.areEqual(0, TrainerWeeklyScheduleJob.emailsPrepared, 'No sessions, no email');
    }

    @isTest
    static void jobCanBeScheduledForMondays() {
        Test.startTest();
        Id jobId = System.schedule('ACME Weekly Trainer Schedule TEST', '0 0 7 ? * MON',
            new TrainerWeeklyScheduleJob());
        Test.stopTest();
        CronTrigger cron = [SELECT CronExpression FROM CronTrigger WHERE Id = :jobId];
        Assert.areEqual('0 0 7 ? * MON', cron.CronExpression, 'Must run every Monday at 07:00');
    }
}