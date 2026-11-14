/**
 * @description Sends the confirmation / cancellation email to the employee, including the
 * session details. All emails of one transaction are sent with ONE Messaging.sendEmail call
 * (bulk safe). An email problem is logged and never rolls back the enrollment.
 */
public without sharing class EnrollmentEmailService {

    /** @description Number of emails built in this transaction (used by unit tests). */
    @TestVisible
    private static Integer emailsPrepared = 0;

    public static void sendNotifications(List<Enrollment__c> newList, Map<Id, Enrollment__c> oldMap) {
        Set<Id> enrollmentIds = new Set<Id>();
        for (Enrollment__c e : newList) {
            Enrollment__c old = oldMap == null ? null : oldMap.get(e.Id);
            Boolean shouldNotify = old == null
                ? e.Status__c == EnrollmentTriggerHandler.STATUS_ENROLLED
                : old.Status__c != e.Status__c;
            if (shouldNotify) {
                enrollmentIds.add(e.Id);
            }
        }
        if (enrollmentIds.isEmpty()) {
            return;
        }

        List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
        for (Enrollment__c e : [
                SELECT Id, Status__c, Employee__r.Name, Employee__r.Email__c,
                       Training_Session__r.Name, Training_Session__r.Start_Time__c,
                       Training_Session__r.End_Time__c, Training_Session__r.Course__r.Name,
                       Training_Session__r.Venue__r.Name, Training_Session__r.Venue__r.Address__c,
                       Training_Session__r.Trainer__r.Name
                FROM Enrollment__c
                WHERE Id IN :enrollmentIds]) {
            if (String.isNotBlank(e.Employee__r.Email__c)) {
                messages.add(buildMessage(e));
            }
        }
        emailsPrepared += messages.size();
        send(messages);
    }

    private static Messaging.SingleEmailMessage buildMessage(Enrollment__c e) {
        Boolean enrolled = e.Status__c == EnrollmentTriggerHandler.STATUS_ENROLLED;
        Training_Session__c s = e.Training_Session__r;
        String dateFormat = 'EEE d MMM yyyy, HH:mm';
        String venue = s.Venue__r.Name
            + (String.isBlank(s.Venue__r.Address__c) ? '' : ' - ' + s.Venue__r.Address__c);

        String body = 'Hello ' + e.Employee__r.Name + ',\n\n'
            + (enrolled
                ? 'You have been enrolled in the following training session.'
                : 'Your enrollment in the following training session has been cancelled.')
            + '\n\n'
            + 'Course:  ' + s.Course__r.Name + '\n'
            + 'Session: ' + s.Name + '\n'
            + 'Starts:  ' + s.Start_Time__c.format(dateFormat) + '\n'
            + 'Ends:    ' + s.End_Time__c.format(dateFormat) + '\n'
            + 'Venue:   ' + venue + '\n'
            + 'Trainer: ' + s.Trainer__r.Name + '\n\n'
            + 'Times are shown in the ' + UserInfo.getTimeZone().getID() + ' time zone.\n\n'
            + 'ACME Employee Skills and Courses Management System';

        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setToAddresses(new List<String>{ e.Employee__r.Email__c });
        message.setSubject(
            (enrolled ? 'Enrollment confirmed: ' : 'Enrollment cancelled: ') + s.Course__r.Name);
        message.setPlainTextBody(body);
        message.setSaveAsActivity(false);
        return message;
    }

    /** @description Sends emails; failures (limits, deliverability off) are logged, not thrown. */
    public static void send(List<Messaging.SingleEmailMessage> messages) {
        if (messages.isEmpty()) {
            return;
        }
        try {
            for (Messaging.SendEmailResult result : Messaging.sendEmail(messages, false)) {
                if (!result.isSuccess()) {
                    System.debug(LoggingLevel.ERROR, 'Email not sent: ' + result.getErrors()[0].getMessage());
                }
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Emails could not be sent: ' + ex.getMessage());
        }
    }
}