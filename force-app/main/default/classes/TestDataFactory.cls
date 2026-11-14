/**
 * @description Creates test data for all ACME ESCMS unit tests.
 * Tests never rely on records that exist in the org. The user running the tests plays
 * "the manager" and "the trainer"; one extra user plays "another manager / trainer".
 */
@isTest
public class TestDataFactory {

    public static final String OTHER_USER_LASTNAME = 'AcmeTestOther';

    public class TestDataException extends Exception {}

    /** @description Inserts a second user who holds the ACME Trainer and ACME Manager permission sets. */
    public static User createOtherUser() {
        User other;
        // runAs avoids the "mixed DML" error (users + normal records in one transaction).
        System.runAs(new User(Id = UserInfo.getUserId())) {
            other = insertUser();
            List<PermissionSetAssignment> assignments = new List<PermissionSetAssignment>();
            for (PermissionSet ps : [SELECT Id FROM PermissionSet
                                     WHERE Name IN ('ACME_Trainer', 'ACME_Manager')]) {
                assignments.add(new PermissionSetAssignment(AssigneeId = other.Id, PermissionSetId = ps.Id));
            }
            insert assignments;
        }
        return other;
    }

    public static User getOtherUser() {
        return [SELECT Id FROM User WHERE LastName = :OTHER_USER_LASTNAME AND IsActive = true LIMIT 1];
    }

    private static User insertUser() {
        // Try the Salesforce Platform license first, then the Salesforce license.
        Map<String, Id> profileIds = new Map<String, Id>();
        for (Profile p : [SELECT Id, Name FROM Profile
                          WHERE Name IN ('Standard Platform User', 'Standard User')]) {
            profileIds.put(p.Name, p.Id);
        }
        for (String profileName : new List<String>{ 'Standard Platform User', 'Standard User' }) {
            if (!profileIds.containsKey(profileName)) {
                continue;
            }
            User u = new User(
                LastName = OTHER_USER_LASTNAME,
                Alias = 'acmeoth',
                Email = 'acme.other@example.com',
                Username = 'acme.other.' + Datetime.now().getTime() + '@example.com',
                ProfileId = profileIds.get(profileName),
                TimeZoneSidKey = 'Europe/London',
                LocaleSidKey = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US');
            if (Database.insert(u, false).isSuccess()) {
                return u;
            }
        }
        throw new TestDataException('No free Salesforce Platform or Salesforce user license. '
            + 'Deactivate one demo user (Setup > Users) and run the tests again.');
    }

    public static Venue__c createVenue(Integer capacity) {
        Venue__c venue = new Venue__c(Name = 'Test Room ' + capacity, Capacity__c = capacity);
        insert venue;
        return venue;
    }

    public static Course__c createCourse(String name) {
        Course__c course = new Course__c(
            Name = name,
            Topic__c = 'Communication',
            Start_Date__c = Date.today().addDays(-30),
            End_Date__c = Date.today().addMonths(6),
            Status__c = 'Active');
        insert course;
        return course;
    }

    /** @description Builds (does not insert) a Scheduled session. */
    public static Training_Session__c buildSession(Id courseId, Id venueId, Id trainerId,
                                                   Datetime startTime, Integer durationHours) {
        return new Training_Session__c(
            Course__c = courseId,
            Venue__c = venueId,
            Trainer__c = trainerId,
            Start_Time__c = startTime,
            End_Time__c = startTime.addHours(durationHours),
            Status__c = 'Scheduled');
    }

    public static List<Employee__c> createEmployees(Integer howMany, Id managerId) {
        List<Employee__c> employees = new List<Employee__c>();
        for (Integer i = 0; i < howMany; i++) {
            employees.add(new Employee__c(
                Name = 'Test Employee ' + i,
                Email__c = 'test.employee' + i + '@example.com',
                Manager__c = managerId,
                OwnerId = managerId));
        }
        insert employees;
        return employees;
    }

    /** @description Builds (does not insert) an active enrollment. */
    public static Enrollment__c buildEnrollment(Id employeeId, Id sessionId) {
        return new Enrollment__c(
            Employee__c = employeeId, Training_Session__c = sessionId, Status__c = 'Enrolled');
    }
}