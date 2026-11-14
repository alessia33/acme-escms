/**
 * @description Single trigger for Training_Session__c. Contains no logic:
 *              everything is delegated to TrainingSessionTriggerHandler.
 */
trigger TrainingSessionTrigger on Training_Session__c (before insert, before update, after update) {
    TrainingSessionTriggerHandler.handle(Trigger.operationType, Trigger.new, Trigger.oldMap);
}