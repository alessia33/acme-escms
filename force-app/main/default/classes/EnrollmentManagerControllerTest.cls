/**
 * @description Tests for EnrollmentManagerController (Apex behind the home page component).
 */
@isTest
private class EnrollmentManagerControllerTest {

    @testSetup
    static void setup() {
        Id me = UserInfo.getUserId();
        TestDataFactory.createOtherUser();
        Course__c course = TestDataFactory.createCourse('Conflict Resolution');
        Id venueId = TestDataFactory.createVenue(3).Id;
        insert new List<Training_Session__c>{
            TestDataFactory.buildSession(course.Id, venueId, me, Datetime.now().addDays(10), 2),
            // More than 3 months away: must not appear in the table.
            TestDataFactory.buildSession(course.Id, venueId, me, Datetime.now().addMonths(4), 2)
        };
        TestDataFactory.createEmployees(2, me);
    }

    private static Id courseId() {
        return [SELECT Id FROM Course__c LIMIT 1].Id;
    }

    private static Training_Session__c nextSession() {
        return [SELECT Id FROM Training_Session__c ORDER BY Start_Time__c LIMIT 1];
    }

    private static String toJson(Id employeeId, Id sessionId, Boolean enrolled) {
        return JSON.serialize(new List<Object>{
            new Map<String, Object>{
                'employeeId' => employeeId, 'sessionId' => sessionId, 'enrolled' => enrolled }
        });
    }

    @isTest
    static void coursesAreListedForThePicklist() {
        List<Course__c> courses = EnrollmentManagerController.getCourses();
        Assert.areEqual(1, courses.size(), 'The open course must be offered');
    }

    @isTest
    static void matrixShowsMyEmployeesAndSessionsOfNextThreeMonths() {
        List<Employee__c> employees = [SELECT Id FROM Employee__c ORDER BY Name];
        insert TestDataFactory.buildEnrollment(employees[0].Id, nextSession().Id);

        EnrollmentManagerController.Matrix matrix = EnrollmentManagerController.getMatrix(courseId());

        Assert.areEqual(1, matrix.sessions.size(), 'Only the session inside 3 months');
        Assert.areEqual(2, matrix.employees.size(), 'Both employees of the manager');
        Assert.areEqual(3, matrix.sessions[0].capacity, 'Capacity comes from the venue');
        Assert.areEqual(2, matrix.sessions[0].seatsLeft, 'One of three seats is taken');
        Assert.isFalse(matrix.sessions[0].frozen, 'Session is more than 24h away');
        Assert.areEqual(1, matrix.employees[0].enrolledSessionIds.size(), 'First employee is enrolled');
        Assert.areEqual(0, matrix.employees[1].enrolledSessionIds.size(), 'Second employee is not');
    }

    @isTest
    static void savingCreatesCancelsAndReactivatesEnrollments() {
        Id employeeId = [SELECT Id FROM Employee__c ORDER BY Name LIMIT 1].Id;
        Id sessionId = nextSession().Id;

        EnrollmentManagerController.saveChanges(toJson(employeeId, sessionId, true));
        Assert.areEqual('Enrolled', [SELECT Status__c FROM Enrollment__c].Status__c, 'Tick = enroll');

        EnrollmentManagerController.saveChanges(toJson(employeeId, sessionId, false));
        Assert.areEqual('Cancelled', [SELECT Status__c FROM Enrollment__c].Status__c, 'Untick = cancel');

        EnrollmentManagerController.saveChanges(toJson(employeeId, sessionId, true));
        Assert.areEqual('Enrolled', [SELECT Status__c FROM Enrollment__c].Status__c,
            'Tick again = the same record is reactivated, no duplicate');

        EnrollmentManagerController.saveChanges('[]');
        Assert.areEqual(1, [SELECT COUNT() FROM Enrollment__c], 'Empty change list does nothing');
    }

    @isTest
    static void ruleViolationIsReturnedAsReadableError() {
        Employee__c notMine = TestDataFactory.createEmployees(1, TestDataFactory.getOtherUser().Id)[0];
        try {
            EnrollmentManagerController.saveChanges(toJson(notMine.Id, nextSession().Id, true));
            Assert.fail('An AuraHandledException was expected');
        } catch (AuraHandledException ex) {
            Assert.isTrue(ex.getMessage().contains('employees you manage'), ex.getMessage());
        }
        Assert.areEqual(0, [SELECT COUNT() FROM Enrollment__c], 'Nothing may be saved');
    }
}