/**
 * @description Apex controller of the enrollmentManager Lightning Web Component shown on the
 * ACME ESCMS home page.
 * Security: "with sharing" + WITH USER_MODE + "as user" DML, so the manager only reads and
 * writes what their permissions and record sharing allow (they only see employees they own).
 * The single exception is the seat counter, which must count enrollments of ALL managers and
 * therefore lives in a small "without sharing" inner class that returns numbers only.
 */
public with sharing class EnrollmentManagerController {

    public class Matrix {
        @AuraEnabled public List<SessionInfo> sessions = new List<SessionInfo>();
        @AuraEnabled public List<EmployeeRow> employees = new List<EmployeeRow>();
    }

    public class SessionInfo {
        @AuraEnabled public Id sessionId;
        @AuraEnabled public String name;
        @AuraEnabled public Datetime startTime;
        @AuraEnabled public Datetime endTime;
        @AuraEnabled public String venueName;
        @AuraEnabled public String trainerName;
        @AuraEnabled public Integer capacity;
        @AuraEnabled public Integer seatsLeft;
        @AuraEnabled public Boolean frozen;
    }

    public class EmployeeRow {
        @AuraEnabled public Id employeeId;
        @AuraEnabled public String name;
        @AuraEnabled public List<Id> enrolledSessionIds = new List<Id>();
    }

    /** @description One change made in the table (deserialized from the component's JSON). */
    public class Change {
        public Id employeeId;
        public Id sessionId;
        public Boolean enrolled;
    }

    /** @description Courses for the picklist. Data driven: new courses appear automatically. */
    @AuraEnabled(cacheable=true)
    public static List<Course__c> getCourses() {
        return [
            SELECT Id, Name, Topic__c
            FROM Course__c
            WHERE Status__c IN ('Planned', 'Active') AND End_Date__c >= TODAY
            WITH USER_MODE
            ORDER BY Name
            LIMIT 500];
    }

    /** @description The manager's employees x the course's sessions of the next 3 months. */
    @AuraEnabled
    public static Matrix getMatrix(Id courseId) {
        // Trainers can open the home page too, but only managers may use this table.
        if (!Schema.sObjectType.Employee__c.isAccessible()
                || !Schema.sObjectType.Enrollment__c.isCreateable()) {
            throw newError('Only managers can enroll employees (ACME Manager permission set required).');
        }
        Matrix matrix = new Matrix();
        Datetime rightNow = System.now();
        Datetime horizon = rightNow.addMonths(3);
        Datetime freezeLimit = rightNow.addHours(24);

        List<Training_Session__c> sessions = [
            SELECT Id, Name, Start_Time__c, End_Time__c, Max_Participants__c, Venue__r.Name, Trainer__r.Name
            FROM Training_Session__c
            WHERE Course__c = :courseId
              AND Status__c = 'Scheduled'
              AND Start_Time__c > :rightNow
              AND Start_Time__c <= :horizon
            WITH USER_MODE
            ORDER BY Start_Time__c
            LIMIT 50];
        Set<Id> sessionIds = new Map<Id, Training_Session__c>(sessions).keySet();
        Map<Id, Integer> seatsTaken = new SystemQueries().countSeatsTaken(sessionIds);

        for (Training_Session__c s : sessions) {
            SessionInfo info = new SessionInfo();
            info.sessionId = s.Id;
            info.name = s.Name;
            info.startTime = s.Start_Time__c;
            info.endTime = s.End_Time__c;
            info.venueName = s.Venue__r.Name;
            info.trainerName = s.Trainer__r.Name;
            info.capacity = s.Max_Participants__c == null ? 0 : s.Max_Participants__c.intValue();
            Integer taken = seatsTaken.containsKey(s.Id) ? seatsTaken.get(s.Id) : 0;
            info.seatsLeft = Math.max(info.capacity - taken, 0);
            info.frozen = s.Start_Time__c <= freezeLimit;
            matrix.sessions.add(info);
        }

        Map<Id, EmployeeRow> rowsByEmployee = new Map<Id, EmployeeRow>();
        for (Employee__c emp : [
                SELECT Id, Name
                FROM Employee__c
                WHERE Manager__c = :UserInfo.getUserId()
                WITH USER_MODE
                ORDER BY Name
                LIMIT 200]) {
            EmployeeRow row = new EmployeeRow();
            row.employeeId = emp.Id;
            row.name = emp.Name;
            rowsByEmployee.put(emp.Id, row);
            matrix.employees.add(row);
        }

        Set<Id> employeeIds = rowsByEmployee.keySet();
        if (!sessionIds.isEmpty() && !employeeIds.isEmpty()) {
            for (Enrollment__c e : [
                    SELECT Employee__c, Training_Session__c
                    FROM Enrollment__c
                    WHERE Training_Session__c IN :sessionIds
                      AND Employee__c IN :employeeIds
                      AND Status__c = 'Enrolled'
                    WITH USER_MODE]) {
                rowsByEmployee.get(e.Employee__c).enrolledSessionIds.add(e.Training_Session__c);
            }
        }
        return matrix;
    }

    /**
     * @description Saves the boxes the manager checked / unchecked. All or nothing: if one
     * change breaks a rule (capacity, overlap, freeze...) nothing is saved and the rule's
     * message is shown to the manager. Business rules live in the trigger, not here.
     */
    @AuraEnabled
    public static void saveChanges(String changesJson) {
        List<Change> changes = (List<Change>) JSON.deserialize(changesJson, List<Change>.class);
        if (changes == null || changes.isEmpty()) {
            return;
        }
        Set<Id> employeeIds = new Set<Id>();
        Set<Id> sessionIds = new Set<Id>();
        for (Change c : changes) {
            employeeIds.add(c.employeeId);
            sessionIds.add(c.sessionId);
        }

        Map<String, Enrollment__c> existingByKey = new Map<String, Enrollment__c>();
        for (Enrollment__c e : [
                SELECT Id, Employee__c, Training_Session__c, Status__c
                FROM Enrollment__c
                WHERE Employee__c IN :employeeIds AND Training_Session__c IN :sessionIds
                WITH USER_MODE]) {
            String key = e.Employee__c + '|' + e.Training_Session__c;
            if (!existingByKey.containsKey(key) || e.Status__c == 'Enrolled') {
                existingByKey.put(key, e);
            }
        }

        List<Enrollment__c> toCancel = new List<Enrollment__c>();
        List<Enrollment__c> toReactivate = new List<Enrollment__c>();
        List<Enrollment__c> toInsert = new List<Enrollment__c>();
        for (Change c : changes) {
            Enrollment__c existing = existingByKey.get(c.employeeId + '|' + c.sessionId);
            if (c.enrolled == true) {
                if (existing == null) {
                    toInsert.add(new Enrollment__c(
                        Employee__c = c.employeeId,
                        Training_Session__c = c.sessionId,
                        Status__c = 'Enrolled'));
                } else if (existing.Status__c != 'Enrolled') {
                    existing.Status__c = 'Enrolled';
                    toReactivate.add(existing);
                }
            } else if (existing != null && existing.Status__c == 'Enrolled') {
                existing.Status__c = 'Cancelled';
                toCancel.add(existing);
            }
        }

        Savepoint sp = Database.setSavepoint();
        try {
            // Cancellations first: they free seats and time slots for the new enrollments.
            if (!toCancel.isEmpty()) {
                update as user toCancel;
            }
            if (!toReactivate.isEmpty()) {
                update as user toReactivate;
            }
            if (!toInsert.isEmpty()) {
                insert as user toInsert;
            }
        } catch (Exception ex) {
            Database.rollback(sp);
            throw newError(ex instanceof DmlException
                ? ((DmlException) ex).getDmlMessage(0) : ex.getMessage());
        }
    }

    /** @description Error that the component can show. setMessage makes it readable in tests too. */
    private static AuraHandledException newError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }

    /** @description System-level seat counter. Returns numbers only, never record data. */
    private without sharing class SystemQueries {
        public Map<Id, Integer> countSeatsTaken(Set<Id> sessionIds) {
            Map<Id, Integer> result = new Map<Id, Integer>();
            if (sessionIds.isEmpty()) {
                return result;
            }
            for (AggregateResult ar : [
                    SELECT Training_Session__c sessionId, COUNT(Id) total
                    FROM Enrollment__c
                    WHERE Training_Session__c IN :sessionIds AND Status__c = 'Enrolled'
                    GROUP BY Training_Session__c]) {
                result.put((Id) ar.get('sessionId'), (Integer) ar.get('total'));
            }
            return result;
        }
    }
}