/**
 * @description Business rules for Enrollment__c. Checked whenever an enrollment is created
 * or its Status changes:
 *  1. Only the employee's manager may enroll or cancel.
 *  2. The session must be Scheduled.
 *  3. The employee must not already be enrolled in an overlapping session.
 *  4. The session must not exceed the capacity of its venue.
 * After save: the enrollment is shared with the trainer and the employee is emailed.
 * (The 24-hour freeze is a validation rule on Enrollment__c, not Apex.)
 * Runs "without sharing" on purpose: capacity and overlap checks must count ALL
 * enrollments, including those owned by other managers.
 */
public without sharing class EnrollmentTriggerHandler {

    public static final String STATUS_ENROLLED = 'Enrolled';
    public static final String STATUS_CANCELLED = 'Cancelled';

    /** @description Set to true only by system cascades (e.g. a session being cancelled). */
    public static Boolean bypassManagerCheck = false;

    public static void handle(System.TriggerOperation operation, List<Enrollment__c> newList,
                              Map<Id, Enrollment__c> oldMap) {
        switch on operation {
            when BEFORE_INSERT, BEFORE_UPDATE {
                validate(newList, oldMap);
            }
            when AFTER_INSERT {
                EnrollmentSharingService.shareWithTrainers(newList);
                EnrollmentEmailService.sendNotifications(newList, oldMap);
            }
            when AFTER_UPDATE {
                reshareOnOwnerChange(newList, oldMap);
                EnrollmentEmailService.sendNotifications(newList, oldMap);
            }
        }
    }

    private static void validate(List<Enrollment__c> newList, Map<Id, Enrollment__c> oldMap) {
        List<Enrollment__c> toValidate = new List<Enrollment__c>();
        Set<Id> employeeIds = new Set<Id>();
        Set<Id> sessionIds = new Set<Id>();
        Set<Id> idsInTrigger = new Set<Id>();

        for (Enrollment__c e : newList) {
            if (e.Id != null) {
                idsInTrigger.add(e.Id);
            }
            Enrollment__c old = oldMap == null ? null : oldMap.get(e.Id);
            Boolean statusChanged = old == null || old.Status__c != e.Status__c;
            if (!statusChanged || e.Employee__c == null || e.Training_Session__c == null) {
                continue;
            }
            toValidate.add(e);
            employeeIds.add(e.Employee__c);
            if (e.Status__c == STATUS_ENROLLED) {
                sessionIds.add(e.Training_Session__c);
            }
        }
        if (toValidate.isEmpty()) {
            return;
        }

        Map<Id, Employee__c> employees = new Map<Id, Employee__c>(
            [SELECT Id, Name, Manager__c FROM Employee__c WHERE Id IN :employeeIds]);

        Map<Id, Training_Session__c> sessions = new Map<Id, Training_Session__c>();
        Map<Id, Integer> seatsTaken = new Map<Id, Integer>();
        Map<Id, List<Training_Session__c>> busyByEmployee = new Map<Id, List<Training_Session__c>>();

        if (!sessionIds.isEmpty()) {
            // FOR UPDATE locks the session rows until the transaction ends, so two managers
            // saving at the same moment cannot both take the last seat.
            sessions = new Map<Id, Training_Session__c>([
                SELECT Id, Name, Status__c, Start_Time__c, End_Time__c, Max_Participants__c
                FROM Training_Session__c
                WHERE Id IN :sessionIds
                FOR UPDATE]);

            for (AggregateResult ar : [
                    SELECT Training_Session__c sessionId, COUNT(Id) total
                    FROM Enrollment__c
                    WHERE Training_Session__c IN :sessionIds AND Status__c = :STATUS_ENROLLED
                    GROUP BY Training_Session__c]) {
                seatsTaken.put((Id) ar.get('sessionId'), (Integer) ar.get('total'));
            }

            Datetime minStart;
            Datetime maxEnd;
            for (Training_Session__c s : sessions.values()) {
                if (minStart == null || s.Start_Time__c < minStart) {
                    minStart = s.Start_Time__c;
                }
                if (maxEnd == null || s.End_Time__c > maxEnd) {
                    maxEnd = s.End_Time__c;
                }
            }
            for (Enrollment__c existing : [
                    SELECT Id, Employee__c, Training_Session__r.Id, Training_Session__r.Name,
                           Training_Session__r.Start_Time__c, Training_Session__r.End_Time__c
                    FROM Enrollment__c
                    WHERE Employee__c IN :employeeIds
                      AND Status__c = :STATUS_ENROLLED
                      AND Training_Session__r.Status__c = :TrainingSessionTriggerHandler.STATUS_SCHEDULED
                      AND Training_Session__r.Start_Time__c < :maxEnd
                      AND Training_Session__r.End_Time__c > :minStart
                      AND Id NOT IN :idsInTrigger]) {
                addBusy(busyByEmployee, existing.Employee__c, existing.Training_Session__r);
            }
        }

        for (Enrollment__c e : toValidate) {
            Employee__c emp = employees.get(e.Employee__c);

            // Rule 1 - only the employee's manager.
            if (!bypassManagerCheck && (emp == null || emp.Manager__c != UserInfo.getUserId())) {
                e.addError('You can only enroll or cancel enrollments for employees you manage.');
                continue;
            }
            if (e.Status__c != STATUS_ENROLLED) {
                continue; // cancellations need no further checks
            }
            Training_Session__c s = sessions.get(e.Training_Session__c);
            if (s == null) {
                continue;
            }
            String employeeName = emp == null ? 'This employee' : emp.Name;

            // Rule 2 - the session must be open.
            if (s.Status__c != TrainingSessionTriggerHandler.STATUS_SCHEDULED) {
                e.addError('Session ' + s.Name + ' is not open for enrollment (status: '
                    + s.Status__c + ').');
                continue;
            }

            // Rule 3 - no overlapping sessions for the same employee.
            Training_Session__c clash = findClash(busyByEmployee.get(e.Employee__c), s);
            if (clash != null) {
                e.addError(clash.Id == s.Id
                    ? employeeName + ' is already enrolled in session ' + s.Name + '.'
                    : employeeName + ' is already enrolled in session ' + clash.Name
                        + ', which overlaps with session ' + s.Name + '.');
                continue;
            }

            // Rule 4 - venue capacity.
            Integer taken = seatsTaken.containsKey(s.Id) ? seatsTaken.get(s.Id) : 0;
            Integer capacity = s.Max_Participants__c == null ? 0 : s.Max_Participants__c.intValue();
            if (taken >= capacity) {
                e.addError('Session ' + s.Name + ' is full (' + capacity + ' seats).');
                continue;
            }

            // Accepted: reserve the seat and the time slot for the rest of this batch.
            seatsTaken.put(s.Id, taken + 1);
            addBusy(busyByEmployee, e.Employee__c, s);
        }
    }

    private static void addBusy(Map<Id, List<Training_Session__c>> busyByEmployee, Id employeeId,
                                Training_Session__c s) {
        if (!busyByEmployee.containsKey(employeeId)) {
            busyByEmployee.put(employeeId, new List<Training_Session__c>());
        }
        busyByEmployee.get(employeeId).add(s);
    }

    private static Training_Session__c findClash(List<Training_Session__c> busy,
                                                 Training_Session__c candidate) {
        if (busy == null) {
            return null;
        }
        for (Training_Session__c b : busy) {
            if (TrainingSessionTriggerHandler.overlaps(candidate.Start_Time__c, candidate.End_Time__c,
                                                       b.Start_Time__c, b.End_Time__c)) {
                return b;
            }
        }
        return null;
    }

    private static void reshareOnOwnerChange(List<Enrollment__c> newList, Map<Id, Enrollment__c> oldMap) {
        // Manual shares are removed by the platform when the owner changes, so re-create them.
        List<Enrollment__c> ownerChanged = new List<Enrollment__c>();
        for (Enrollment__c e : newList) {
            if (e.OwnerId != oldMap.get(e.Id).OwnerId) {
                ownerChanged.add(e);
            }
        }
        if (!ownerChanged.isEmpty()) {
            EnrollmentSharingService.shareWithTrainers(ownerChanged);
        }
    }
}