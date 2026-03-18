public with sharing class SupplierInvestigationListController {

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getInvestigations(Id accountId) {
        List<Supplier_Investigation__c> siList = [
            SELECT Id, Name, Status__c, Severity__c, Request_Date__c,
                   Response_Due_Date__c, Response_Date__c,
                   Cause_Category__c, Supplier_Contact__c,
                   Corrective_Action__r.Name
            FROM Supplier_Investigation__c
            WHERE Supplier__c = :accountId
            ORDER BY Request_Date__c DESC
            LIMIT 50
        ];

        List<Map<String, Object>> results = new List<Map<String, Object>>();
        for (Supplier_Investigation__c si : siList) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('Id', si.Id);
            m.put('Name', si.Name);
            m.put('status', si.Status__c);
            m.put('severity', si.Severity__c);
            m.put('requestDate', si.Request_Date__c);
            m.put('responseDueDate', si.Response_Due_Date__c);
            m.put('responseDate', si.Response_Date__c);
            m.put('causeCategory', si.Cause_Category__c);
            m.put('caName', si.Corrective_Action__r != null ? si.Corrective_Action__r.Name : null);
            m.put('supplierContact', si.Supplier_Contact__c);

            // 期限超過チェック
            if (si.Status__c != '完了' && si.Response_Due_Date__c != null) {
                m.put('isOverdue', Date.today() > si.Response_Due_Date__c);
            } else {
                m.put('isOverdue', false);
            }
            results.add(m);
        }
        return results;
    }
}
