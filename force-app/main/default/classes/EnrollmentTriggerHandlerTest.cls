/**
 * @description Tests for EnrollmentTriggerHandler, EnrollmentSharingService,
 * EnrollmentEmailService and the enrollment validation rules.
 */
@isTest
private class EnrollmentTriggerHandlerTest {

    @testSetup
    static void setup() {
        TestDataFactory.createOtherUser();
        TestDataFactory.createCourse('Giving Feedback');
    }

    private static Training_Session__c createSession(Integer capacity, Id trainerId, Datetime startTime) {
        Training_Session__c session = TestDataFactory.buildSession(
            [SELECT Id FROM Course__c LIMIT 1].Id,
            TestDataFactory.createVenue(capacity).Id, trainerId, startTime, 2);
        insert session;
        return session;
    }

    @isTest
    static void enrollmentIsSharedWithTrainerAndConfirmedByEmail() {
        User trainer = TestDataFactory.getOtherUser();
        Training_Session__c session = createSession(5, trainer.Id, Datetime.now().addDays(10));
        Employee__c employee = TestDataFactory.createEmployees(1, UserInfo.getUserId())[0];

        Test.startTest();
        Enrollment__c enrollment = TestDataFactory.buildEnrollment(employee.Id, session.Id);
        insert enrollment;
        Test.stopTest();

        Assert.areEqual(1, [SELECT COUNT() FROM Enrollment__Share
                            WHERE ParentId = :enrollment.Id AND UserOrGroupId = :trainer.Id
                              AND AccessLevel = 'Read'],
            'The trainer must get read access');
        Assert.areEqual(1, EnrollmentEmailService.emailsPrepared, 'One confirmation email expected');
    }

    @isTest
    static void sessionCannotExceedVenueCapacity() {
        Training_Session__c session = createSession(2, UserInfo.getUserId(), Datetime.now().addDays(10));
        List<Employee__c> employees = TestDataFactory.createEmployees(3, UserInfo.getUserId());
        List<Enrollment__c> enrollments = new List<Enrollment__c>();
        for (Employee__c employee : employees) {
            enrollments.add(TestDataFactory.buildEnrollment(employee.Id, session.Id));
        }

        List<Database.SaveResult> results = Database.insert(enrollments, false);

        Assert.isTrue(results[0].isSuccess() && results[1].isSuccess(), 'Two seats are available');
        Assert.isFalse(results[2].isSuccess(), 'The third enrollment exceeds the capacity');
        Assert.isTrue(results[2].getErrors()[0].getMessage().contains('is full'), 'Unexpected message');
        Assert.areEqual(2, [SELECT COUNT() FROM Enrollment__c WHERE Training_Session__c = :session.Id]);
    }

    @isTest
    static void cancelledSeatCanBeReused() {
        Training_Session__c session = createSession(1, UserInfo.getUserId(), Datetime.now().addDays(10));
        List<Employee__c> employees = TestDataFactory.createEmployees(2, UserInfo.getUserId());
        Enrollment__c firstEnrollment = TestDataFactory.buildEnrollment(employees[0].Id, session.Id);
        insert firstEnrollment;

        firstEnrollment.Status__c = 'Cancelled';
        update firstEnrollment;
        insert TestDataFactory.buildEnrollment(employees[1].Id, session.Id);

        // The only seat is taken again, so the first employee cannot be re-enrolled.
        firstEnrollment.Status__c = 'Enrolled';
        Assert.isFalse(Database.update(firstEnrollment, false).isSuccess(), 'Session is full again');
        Assert.areEqual(3, EnrollmentEmailService.emailsPrepared,
            'Confirmation + cancellation + confirmation');
    }

    @isTest
    static void employeeCannotAttendOverlappingSessions() {
        Datetime startTime = Datetime.now().addDays(10);
        Training_Session__c firstSession = createSession(5, UserInfo.getUserId(), startTime);
        Training_Session__c overlapping = createSession(
            5, TestDataFactory.getOtherUser().Id, startTime.addHours(1));
        Employee__c employee = TestDataFactory.createEmployees(1, UserInfo.getUserId())[0];
        insert TestDataFactory.buildEnrollment(employee.Id, firstSession.Id);

        Database.SaveResult result = Database.insert(
            TestDataFactory.buildEnrollment(employee.Id, overlapping.Id), false);
        Assert.isFalse(result.isSuccess(), 'Overlapping enrollment must be rejected');
        Assert.isTrue(result.getErrors()[0].getMessage().contains('overlaps'), 'Unexpected message');

        Database.SaveResult duplicate = Database.insert(
            TestDataFactory.buildEnrollment(employee.Id, firstSession.Id), false);
        Assert.isFalse(duplicate.isSuccess(), 'Duplicate enrollment must be rejected');
        Assert.isTrue(duplicate.getErrors()[0].getMessage().contains('already enrolled'),
            'Unexpected message');
    }

    @isTest
    static void onlyTheManagerOfTheEmployeeCanEnroll() {
        Training_Session__c session = createSession(5, UserInfo.getUserId(), Datetime.now().addDays(10));
        Employee__c notMine = TestDataFactory.createEmployees(1, TestDataFactory.getOtherUser().Id)[0];

        Database.SaveResult result = Database.insert(
            TestDataFactory.buildEnrollment(notMine.Id, session.Id), false);
        Assert.isFalse(result.isSuccess(), 'Only the manager may enroll the employee');
        Assert.isTrue(result.getErrors()[0].getMessage().contains('employees you manage'),
            'Unexpected message');
    }

    @isTest
    static void cancelledSessionIsClosedForEnrollment() {
        Training_Session__c session = createSession(5, UserInfo.getUserId(), Datetime.now().addDays(10));
        session.Status__c = 'Cancelled';
        update session;
        Employee__c employee = TestDataFactory.createEmployees(1, UserInfo.getUserId())[0];

        Database.SaveResult result = Database.insert(
            TestDataFactory.buildEnrollment(employee.Id, session.Id), false);
        Assert.isFalse(result.isSuccess(), 'A cancelled session accepts no enrollments');
    }

    @isTest
    static void enrollmentIsFrozen24HoursBeforeStart() {
        Training_Session__c session = createSession(5, UserInfo.getUserId(), Datetime.now().addHours(3));
        Employee__c employee = TestDataFactory.createEmployees(1, UserInfo.getUserId())[0];

        Database.SaveResult result = Database.insert(
            TestDataFactory.buildEnrollment(employee.Id, session.Id), false);
        Assert.isFalse(result.isSuccess(),
            'Validation rule Freeze_24h_Before_Start must block the enrollment');
    }

    @isTest
    static void employeeAndSessionCannotBeChanged() {
        Training_Session__c session = createSession(5, UserInfo.getUserId(), Datetime.now().addDays(10));
        List<Employee__c> employees = TestDataFactory.createEmployees(2, UserInfo.getUserId());
        Enrollment__c enrollment = TestDataFactory.buildEnrollment(employees[0].Id, session.Id);
        insert enrollment;

        enrollment.Employee__c = employees[1].Id;
        Assert.isFalse(Database.update(enrollment, false).isSuccess(),
            'Validation rule Employee_And_Session_Locked must block the change');
    }

    @isTest
    static void twoHundredEnrollmentsInOneSave() {
        Training_Session__c session = createSession(200, UserInfo.getUserId(), Datetime.now().addDays(10));
        List<Enrollment__c> enrollments = new List<Enrollment__c>();
        for (Employee__c employee : TestDataFactory.createEmployees(200, UserInfo.getUserId())) {
            enrollments.add(TestDataFactory.buildEnrollment(employee.Id, session.Id));
        }

        Test.startTest();
        insert enrollments;
        Test.stopTest();

        Assert.areEqual(200, [SELECT COUNT() FROM Enrollment__c
                              WHERE Training_Session__c = :session.Id AND Status__c = 'Enrolled'],
            'Bulk insert must succeed inside governor limits');
    }
}