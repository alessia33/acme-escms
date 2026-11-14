/**
 * @description Single trigger for Course__c. Contains no logic:
 *              everything is delegated to CourseTriggerHandler.
 */
trigger CourseTrigger on Course__c (before insert, before update, after insert, after update) {
    CourseTriggerHandler.handle(Trigger.operationType, Trigger.new, Trigger.oldMap);
}