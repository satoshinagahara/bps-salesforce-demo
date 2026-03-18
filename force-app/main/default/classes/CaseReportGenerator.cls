public with sharing class CaseReportGenerator {

    @InvocableMethod(label='ケース顧客報告データ取得' description='Case + 是正措置 + サプライヤー調査の情報をJSON化して返す')
    public static List<String> getData(List<Id> caseIds) {
        Id caseId = caseIds[0];

        Case c = [
            SELECT Id, CaseNumber, Subject, Description, Status, Priority,
                   CreatedDate, ClosedDate,
                   Contact.Name, Contact.Email,
                   Account.Name
            FROM Case
            WHERE Id = :caseId
            LIMIT 1
        ];

        List<Corrective_Action__c> cas = [
            SELECT Id, Name, Title__c, Phase__c, Severity__c, Category__c,
                   Target_Close_Date__c, Actual_Close_Date__c,
                   Product__r.Name, Product__r.ProductCode,
                   Supplier__r.Name,
                   BOM_Part__r.Part_Name__c, BOM_Part__r.Part_Number__c,
                   Team_Lead__r.Name,
                   D2_Problem_Description__c, D3_Containment__c,
                   D4_Root_Cause__c, D5_Permanent_Action__c,
                   D6_Verification__c, D7_Prevention__c,
                   (SELECT Id, Name, Status__c, Supplier__r.Name,
                           Request_Date__c, Response_Due_Date__c, Response_Date__c,
                           Root_Cause_by_Supplier__c, Action_Taken__c,
                           Verification_Date__c, Verification_Result__c
                    FROM Supplier_Investigations__r
                    ORDER BY Request_Date__c DESC)
            FROM Corrective_Action__c
            WHERE Case__c = :caseId
            ORDER BY CreatedDate DESC
        ];

        Map<String, Object> result = new Map<String, Object>();

        // Case info
        Map<String, Object> caseInfo = new Map<String, Object>();
        caseInfo.put('caseNumber', c.CaseNumber);
        caseInfo.put('subject', c.Subject);
        caseInfo.put('description', c.Description);
        caseInfo.put('status', c.Status);
        caseInfo.put('priority', c.Priority);
        caseInfo.put('createdDate', String.valueOf(c.CreatedDate));
        caseInfo.put('contactName', c.Contact?.Name);
        caseInfo.put('accountName', c.Account?.Name);
        result.put('case', caseInfo);

        // Corrective Actions
        List<Map<String, Object>> caList = new List<Map<String, Object>>();
        for (Corrective_Action__c ca : cas) {
            Map<String, Object> caMap = new Map<String, Object>();
            caMap.put('name', ca.Name);
            caMap.put('title', ca.Title__c);
            caMap.put('phase', ca.Phase__c);
            caMap.put('severity', ca.Severity__c);
            caMap.put('category', ca.Category__c);
            caMap.put('targetCloseDate', String.valueOf(ca.Target_Close_Date__c));
            caMap.put('actualCloseDate', String.valueOf(ca.Actual_Close_Date__c));
            caMap.put('productName', ca.Product__r?.Name);
            caMap.put('productCode', ca.Product__r?.ProductCode);
            caMap.put('supplierName', ca.Supplier__r?.Name);
            caMap.put('partName', ca.BOM_Part__r?.Part_Name__c);
            caMap.put('teamLead', ca.Team_Lead__r?.Name);
            caMap.put('problemDescription', ca.D2_Problem_Description__c);
            caMap.put('containment', ca.D3_Containment__c);
            caMap.put('rootCause', ca.D4_Root_Cause__c);
            caMap.put('permanentAction', ca.D5_Permanent_Action__c);
            caMap.put('verification', ca.D6_Verification__c);
            caMap.put('prevention', ca.D7_Prevention__c);

            // Supplier Investigations
            List<Map<String, Object>> siList = new List<Map<String, Object>>();
            for (Supplier_Investigation__c si : ca.Supplier_Investigations__r) {
                Map<String, Object> siMap = new Map<String, Object>();
                siMap.put('name', si.Name);
                siMap.put('status', si.Status__c);
                siMap.put('supplierName', si.Supplier__r?.Name);
                siMap.put('requestDate', String.valueOf(si.Request_Date__c));
                siMap.put('responseDate', String.valueOf(si.Response_Date__c));
                siMap.put('rootCauseBySupplier', si.Root_Cause_by_Supplier__c);
                siMap.put('actionTaken', si.Action_Taken__c);
                siMap.put('verificationDate', String.valueOf(si.Verification_Date__c));
                siMap.put('verificationResult', si.Verification_Result__c);
                siList.add(siMap);
            }
            caMap.put('supplierInvestigations', siList);
            caList.add(caMap);
        }
        result.put('correctiveActions', caList);
        result.put('caCount', cas.size());
        result.put('generatedDate', String.valueOf(Date.today()));

        return new List<String>{ JSON.serialize(result) };
    }
}
