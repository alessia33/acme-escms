/**
 * @description Single trigger for Enrollment__c. Contains no logic:
 *              everything is delegated to EnrollmentTriggerHandler.
 */
trigger EnrollmentTrigger on Enrollment__c (before insert, before update, after insert, after update) {
    EnrollmentTriggerHandler.handle(Trigger.operationType, Trigger.new, Trigger.oldMap);
}