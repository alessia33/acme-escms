/**
 * @description Record-level security for Enrollment__c (org-wide default: Private).
 * The manager who creates an enrollment owns it. This service gives the trainer of the
 * session READ access to it, so trainers see only enrollments of sessions they teach.
 * Runs "without sharing" because sharing rows are maintained by the system, not the user.
 */
public without sharing class EnrollmentSharingService {

    private static final String ROW_CAUSE_MANUAL = 'Manual';

    public static void shareWithTrainers(List<Enrollment__c> enrollments) {
        Set<Id> sessionIds = new Set<Id>();
        for (Enrollment__c e : enrollments) {
            sessionIds.add(e.Training_Session__c);
        }
        Map<Id, Training_Session__c> sessions = new Map<Id, Training_Session__c>(
            [SELECT Id, Trainer__c FROM Training_Session__c WHERE Id IN :sessionIds]);

        List<Enrollment__Share> shares = new List<Enrollment__Share>();
        for (Enrollment__c e : enrollments) {
            Training_Session__c s = sessions.get(e.Training_Session__c);
            // The owner already has full access; sharing with the owner is not allowed.
            if (s == null || s.Trainer__c == null || s.Trainer__c == e.OwnerId) {
                continue;
            }
            shares.add(new Enrollment__Share(
                ParentId = e.Id,
                UserOrGroupId = s.Trainer__c,
                AccessLevel = 'Read',
                RowCause = ROW_CAUSE_MANUAL));
        }
        if (shares.isEmpty()) {
            return;
        }
        // allOrNone = false: a sharing problem must never block the enrollment itself.
        for (Database.SaveResult result : Database.insert(shares, false)) {
            if (!result.isSuccess()) {
                System.debug(LoggingLevel.WARN, 'Enrollment share not created: '
                    + result.getErrors()[0].getMessage());
            }
        }
    }

    /** @description Rebuilds trainer shares for all enrollments of the given sessions. */
    public static void recalculateForSessions(Set<Id> sessionIds) {
        List<Enrollment__c> enrollments = [
            SELECT Id, OwnerId, Training_Session__c
            FROM Enrollment__c
            WHERE Training_Session__c IN :sessionIds];
        if (enrollments.isEmpty()) {
            return;
        }
        List<Enrollment__Share> oldShares = [
            SELECT Id FROM Enrollment__Share
            WHERE ParentId IN :enrollments AND RowCause = :ROW_CAUSE_MANUAL];
        if (!oldShares.isEmpty()) {
            delete oldShares;
        }
        shareWithTrainers(enrollments);
    }
}