public with sharing class LauncherController {
    @AuraEnabled(cacheable=true)
    public static List<Launcher_Button__c> getItems() {
        return [
            SELECT Name, Link__c, Sort_Order__c,
                   Is_Active__c, Description__c, Open_In_New_Tab__c, Category__c
            FROM Launcher_Button__c
            WHERE Is_Active__c = true
            ORDER BY Category__c NULLS LAST, Sort_Order__c ASC NULLS LAST, Name ASC
        ];
    }
}
