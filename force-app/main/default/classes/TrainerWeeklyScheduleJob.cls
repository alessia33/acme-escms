/**
 * @description Scheduled every Monday. Emails each trainer the Scheduled sessions they teach
 * in the next 7 days (one email per trainer, one sendEmail call in total).
 * Schedule once from Execute Anonymous:
 *   System.schedule('ACME Weekly Trainer Schedule', '0 0 7 ? * MON', new TrainerWeeklyScheduleJob());
 */
public without sharing class TrainerWeeklyScheduleJob implements Schedulable {

    /** @description Number of emails built in this transaction (used by unit tests). */
    @TestVisible
    private static Integer emailsPrepared = 0;

    public void execute(SchedulableContext context) {
        sendSchedules();
    }

    public static void sendSchedules() {
        Datetime fromTime = System.now();
        Datetime toTime = fromTime.addDays(7);

        List<Training_Session__c> sessions = [
            SELECT Id, Name, Trainer__c, Trainer__r.FirstName, Trainer__r.TimeZoneSidKey,
                   Start_Time__c, End_Time__c, Max_Participants__c, Course__r.Name, Venue__r.Name
            FROM Training_Session__c
            WHERE Status__c = :TrainingSessionTriggerHandler.STATUS_SCHEDULED
              AND Start_Time__c >= :fromTime
              AND Start_Time__c < :toTime
              AND Trainer__r.IsActive = true
            ORDER BY Start_Time__c];
        if (sessions.isEmpty()) {
            return;
        }

        Map<Id, Integer> enrolledBySession = new Map<Id, Integer>();
        for (AggregateResult ar : [
                SELECT Training_Session__c sessionId, COUNT(Id) total
                FROM Enrollment__c
                WHERE Training_Session__c IN :sessions
                  AND Status__c = :EnrollmentTriggerHandler.STATUS_ENROLLED
                GROUP BY Training_Session__c]) {
            enrolledBySession.put((Id) ar.get('sessionId'), (Integer) ar.get('total'));
        }

        Map<Id, List<Training_Session__c>> sessionsByTrainer = new Map<Id, List<Training_Session__c>>();
        for (Training_Session__c s : sessions) {
            if (!sessionsByTrainer.containsKey(s.Trainer__c)) {
                sessionsByTrainer.put(s.Trainer__c, new List<Training_Session__c>());
            }
            sessionsByTrainer.get(s.Trainer__c).add(s);
        }

        List<Messaging.SingleEmailMessage> messages = new List<Messaging.SingleEmailMessage>();
        for (Id trainerId : sessionsByTrainer.keySet()) {
            List<Training_Session__c> mine = sessionsByTrainer.get(trainerId);
            String tzKey = mine[0].Trainer__r.TimeZoneSidKey;
            String firstName = mine[0].Trainer__r.FirstName;

            String body = 'Hello' + (String.isBlank(firstName) ? '' : ' ' + firstName) + ',\n\n'
                + 'Here is your training schedule for the next 7 days (' + tzKey + ' time):\n\n';
            for (Training_Session__c s : mine) {
                Integer enrolled = enrolledBySession.containsKey(s.Id) ? enrolledBySession.get(s.Id) : 0;
                Integer capacity = s.Max_Participants__c == null ? 0 : s.Max_Participants__c.intValue();
                body += '- ' + s.Start_Time__c.format('EEE d MMM, HH:mm', tzKey)
                    + ' to ' + s.End_Time__c.format('HH:mm', tzKey)
                    + ' | ' + s.Course__r.Name + ' (' + s.Name + ')'
                    + ' | ' + s.Venue__r.Name
                    + ' | ' + enrolled + ' of ' + capacity + ' seats taken\n';
            }
            body += '\nACME Employee Skills and Courses Management System';

            Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
            message.setTargetObjectId(trainerId); // emails to internal users do not use the daily limit
            message.setSaveAsActivity(false);     // required when the target is a User
            message.setSubject('Your training schedule for this week');
            message.setPlainTextBody(body);
            messages.add(message);
        }
        emailsPrepared += messages.size();
        EnrollmentEmailService.send(messages);
    }
}