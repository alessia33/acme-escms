/**
 * @description Business rules for Training_Session__c.
 *  1. The session owner always equals the trainer, so the trainer can edit and cancel it.
 *  2. A trainer cannot teach two overlapping Scheduled sessions.
 *  3. Cancelling a session cancels its active enrollments (employees are then emailed).
 *  4. When the trainer changes, enrollment sharing is recalculated for the new trainer.
 * Runs "without sharing" on purpose: the overlap rule must see ALL sessions of a trainer,
 * not only the records visible to the user who is saving.
 */
public without sharing class TrainingSessionTriggerHandler {

    public static final String STATUS_SCHEDULED = 'Scheduled';
    public static final String STATUS_CANCELLED = 'Cancelled';

    public static void handle(System.TriggerOperation operation, List<Training_Session__c> newList,
                              Map<Id, Training_Session__c> oldMap) {
        switch on operation {
            when BEFORE_INSERT, BEFORE_UPDATE {
                syncOwnerWithTrainer(newList);
                preventTrainerOverlap(newList, oldMap);
            }
            when AFTER_UPDATE {
                cancelEnrollmentsOfCancelledSessions(newList, oldMap);
                reshareEnrollmentsOnTrainerChange(newList, oldMap);
            }
        }
    }

    /** @description True when two time windows overlap. Back-to-back windows do not overlap. */
    public static Boolean overlaps(Datetime start1, Datetime end1, Datetime start2, Datetime end2) {
        return start1 < end2 && start2 < end1;
    }

    private static void syncOwnerWithTrainer(List<Training_Session__c> newList) {
        for (Training_Session__c s : newList) {
            if (s.Trainer__c != null && s.OwnerId != s.Trainer__c) {
                s.OwnerId = s.Trainer__c;
            }
        }
    }

    private static void preventTrainerOverlap(List<Training_Session__c> newList,
                                              Map<Id, Training_Session__c> oldMap) {
        List<Training_Session__c> toCheck = new List<Training_Session__c>();
        Map<Id, List<Training_Session__c>> busyByTrainer = new Map<Id, List<Training_Session__c>>();
        Set<Id> idsInTrigger = new Set<Id>();
        Set<Id> trainerIds = new Set<Id>();
        Datetime minStart;
        Datetime maxEnd;

        for (Training_Session__c s : newList) {
            if (s.Id != null) {
                idsInTrigger.add(s.Id);
            }
            if (s.Status__c != STATUS_SCHEDULED || s.Trainer__c == null
                    || s.Start_Time__c == null || s.End_Time__c == null) {
                continue;
            }
            Training_Session__c old = oldMap == null ? null : oldMap.get(s.Id);
            Boolean changed = old == null
                || old.Trainer__c != s.Trainer__c
                || old.Start_Time__c != s.Start_Time__c
                || old.End_Time__c != s.End_Time__c
                || old.Status__c != s.Status__c;
            if (changed) {
                toCheck.add(s);
                trainerIds.add(s.Trainer__c);
                if (minStart == null || s.Start_Time__c < minStart) {
                    minStart = s.Start_Time__c;
                }
                if (maxEnd == null || s.End_Time__c > maxEnd) {
                    maxEnd = s.End_Time__c;
                }
            } else {
                // Unchanged sessions in the same save still occupy the trainer's calendar.
                addBusy(busyByTrainer, s);
            }
        }
        if (toCheck.isEmpty()) {
            return;
        }

        // One query for the whole batch (bulk safe). Records in this save are excluded
        // because the database still holds their old values.
        for (Training_Session__c existing : [
                SELECT Id, Name, Trainer__c, Start_Time__c, End_Time__c
                FROM Training_Session__c
                WHERE Trainer__c IN :trainerIds
                  AND Status__c = :STATUS_SCHEDULED
                  AND Start_Time__c < :maxEnd
                  AND End_Time__c > :minStart
                  AND Id NOT IN :idsInTrigger]) {
            addBusy(busyByTrainer, existing);
        }

        for (Training_Session__c s : toCheck) {
            Training_Session__c clash = findClash(busyByTrainer.get(s.Trainer__c), s);
            if (clash == null) {
                addBusy(busyByTrainer, s);
            } else {
                String other = clash.Name == null
                    ? 'another session in the same save' : 'session ' + clash.Name;
                s.addError('This trainer already teaches ' + other
                    + ' during that time. A trainer cannot teach overlapping sessions.');
            }
        }
    }

    private static void addBusy(Map<Id, List<Training_Session__c>> busyByTrainer, Training_Session__c s) {
        if (!busyByTrainer.containsKey(s.Trainer__c)) {
            busyByTrainer.put(s.Trainer__c, new List<Training_Session__c>());
        }
        busyByTrainer.get(s.Trainer__c).add(s);
    }

    private static Training_Session__c findClash(List<Training_Session__c> busy,
                                                 Training_Session__c candidate) {
        if (busy == null) {
            return null;
        }
        for (Training_Session__c b : busy) {
            if (overlaps(candidate.Start_Time__c, candidate.End_Time__c, b.Start_Time__c, b.End_Time__c)) {
                return b;
            }
        }
        return null;
    }

    private static void cancelEnrollmentsOfCancelledSessions(List<Training_Session__c> newList,
                                                             Map<Id, Training_Session__c> oldMap) {
        Set<Id> cancelledIds = new Set<Id>();
        for (Training_Session__c s : newList) {
            if (s.Status__c == STATUS_CANCELLED && oldMap.get(s.Id).Status__c != STATUS_CANCELLED) {
                cancelledIds.add(s.Id);
            }
        }
        if (cancelledIds.isEmpty()) {
            return;
        }
        List<Enrollment__c> toCancel = [
            SELECT Id FROM Enrollment__c
            WHERE Training_Session__c IN :cancelledIds
              AND Status__c = :EnrollmentTriggerHandler.STATUS_ENROLLED];
        if (toCancel.isEmpty()) {
            return;
        }
        for (Enrollment__c e : toCancel) {
            e.Status__c = EnrollmentTriggerHandler.STATUS_CANCELLED;
        }
        // The trainer (not the manager) triggers this system cascade, so the
        // "only the employee's manager" rule is switched off for this one update.
        EnrollmentTriggerHandler.bypassManagerCheck = true;
        try {
            update toCancel;
        } finally {
            EnrollmentTriggerHandler.bypassManagerCheck = false;
        }
    }

    private static void reshareEnrollmentsOnTrainerChange(List<Training_Session__c> newList,
                                                          Map<Id, Training_Session__c> oldMap) {
        Set<Id> changedIds = new Set<Id>();
        for (Training_Session__c s : newList) {
            if (s.Trainer__c != oldMap.get(s.Id).Trainer__c) {
                changedIds.add(s.Id);
            }
        }
        if (!changedIds.isEmpty()) {
            EnrollmentSharingService.recalculateForSessions(changedIds);
        }
    }
}