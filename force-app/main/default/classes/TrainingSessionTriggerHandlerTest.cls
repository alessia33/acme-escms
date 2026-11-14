/**
 * @description Tests for TrainingSessionTriggerHandler and the session validation rules.
 */
@isTest
private class TrainingSessionTriggerHandlerTest {

    @testSetup
    static void setup() {
        TestDataFactory.createOtherUser();
        TestDataFactory.createVenue(5);
        TestDataFactory.createCourse('Active Listening');
    }

    private static Id courseId() {
        return [SELECT Id FROM Course__c LIMIT 1].Id;
    }

    private static Id venueId() {
        return [SELECT Id FROM Venue__c LIMIT 1].Id;
    }

    @isTest
    static void ownerFollowsTrainer() {
        User other = TestDataFactory.getOtherUser();
        Training_Session__c session = TestDataFactory.buildSession(
            courseId(), venueId(), other.Id, Datetime.now().addDays(10), 2);
        insert session;

        session = [SELECT OwnerId FROM Training_Session__c WHERE Id = :session.Id];
        Assert.areEqual(other.Id, session.OwnerId, 'The trainer must own the session');
    }

    @isTest
    static void trainerCannotTeachOverlappingSessions() {
        Datetime startTime = Datetime.now().addDays(10);
        Id me = UserInfo.getUserId();
        insert TestDataFactory.buildSession(courseId(), venueId(), me, startTime, 2);

        Database.SaveResult overlapping = Database.insert(
            TestDataFactory.buildSession(courseId(), venueId(), me, startTime.addHours(1), 2), false);
        Assert.isFalse(overlapping.isSuccess(), 'Overlapping session must be rejected');
        Assert.isTrue(overlapping.getErrors()[0].getMessage().contains('overlapping'), 'Unexpected message');

        // Back-to-back is allowed, and so is another trainer at the same time.
        Database.SaveResult backToBack = Database.insert(
            TestDataFactory.buildSession(courseId(), venueId(), me, startTime.addHours(2), 2), false);
        Assert.isTrue(backToBack.isSuccess(), 'Back-to-back sessions do not overlap');
        Database.SaveResult otherTrainer = Database.insert(
            TestDataFactory.buildSession(
                courseId(), venueId(), TestDataFactory.getOtherUser().Id, startTime, 2), false);
        Assert.isTrue(otherTrainer.isSuccess(), 'Another trainer may teach at the same time');
    }

    @isTest
    static void overlapIsDetectedInsideOneBulkSave() {
        Datetime startTime = Datetime.now().addDays(12);
        Id me = UserInfo.getUserId();
        List<Training_Session__c> sessions = new List<Training_Session__c>{
            TestDataFactory.buildSession(courseId(), venueId(), me, startTime, 2),
            TestDataFactory.buildSession(courseId(), venueId(), me, startTime.addMinutes(30), 2)
        };
        List<Database.SaveResult> results = Database.insert(sessions, false);
        Assert.isTrue(results[0].isSuccess(), 'First session is valid');
        Assert.isFalse(results[1].isSuccess(), 'Second session overlaps the first one');
    }

    @isTest
    static void movingSessionOntoAnotherIsBlocked() {
        Datetime startTime = Datetime.now().addDays(10);
        Id me = UserInfo.getUserId();
        insert TestDataFactory.buildSession(courseId(), venueId(), me, startTime, 2);
        Training_Session__c secondSession = TestDataFactory.buildSession(
            courseId(), venueId(), me, startTime.addDays(1), 2);
        insert secondSession;

        secondSession.Start_Time__c = startTime.addHours(1);
        secondSession.End_Time__c = startTime.addHours(3);
        Assert.isFalse(Database.update(secondSession, false).isSuccess(), 'Update must be rejected');
    }

    @isTest
    static void cancellingSessionCancelsEnrollments() {
        Id me = UserInfo.getUserId();
        Training_Session__c session = TestDataFactory.buildSession(
            courseId(), venueId(), me, Datetime.now().addDays(10), 2);
        insert session;
        List<Employee__c> employees = TestDataFactory.createEmployees(2, me);
        insert new List<Enrollment__c>{
            TestDataFactory.buildEnrollment(employees[0].Id, session.Id),
            TestDataFactory.buildEnrollment(employees[1].Id, session.Id)
        };

        Test.startTest();
        session.Status__c = 'Cancelled';
        update session;
        Test.stopTest();

        Assert.areEqual(2, [SELECT COUNT() FROM Enrollment__c
                            WHERE Training_Session__c = :session.Id AND Status__c = 'Cancelled'],
            'All enrollments of a cancelled session must be cancelled');
    }

    @isTest
    static void sessionIsFrozen24HoursBeforeStart() {
        Training_Session__c session = TestDataFactory.buildSession(
            courseId(), venueId(), UserInfo.getUserId(), Datetime.now().addHours(3), 1);
        insert session;

        session.Status__c = 'Cancelled';
        Assert.isFalse(Database.update(session, false).isSuccess(),
            'Validation rule Freeze_24h_Before_Start must block the change');
    }

    @isTest
    static void changingTrainerMovesEnrollmentSharing() {
        Id me = UserInfo.getUserId();
        User other = TestDataFactory.getOtherUser();
        Training_Session__c session = TestDataFactory.buildSession(
            courseId(), venueId(), me, Datetime.now().addDays(10), 2);
        insert session;
        Employee__c employee = TestDataFactory.createEmployees(1, me)[0];
        Enrollment__c enrollment = TestDataFactory.buildEnrollment(employee.Id, session.Id);
        insert enrollment;

        session.Trainer__c = other.Id;
        update session;

        Assert.areEqual(1, [SELECT COUNT() FROM Enrollment__Share
                            WHERE ParentId = :enrollment.Id AND UserOrGroupId = :other.Id],
            'The new trainer must get access to the enrollment');
    }
}