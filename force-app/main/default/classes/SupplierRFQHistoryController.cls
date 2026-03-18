public with sharing class SupplierRFQHistoryController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getSupplierRFQHistory(Id accountId) {
        List<RFQ_Quote__c> quotes = [
            SELECT Id, Name, Status__c, Unit_Price__c, Lead_Time_Days__c,
                   MOQ__c, Score__c, Response_Date__c, Valid_Until__c, Notes__c,
                   Manufacturing_Site__r.Name,
                   RFQ__r.Name, RFQ__r.Title__c, RFQ__r.Status__c,
                   RFQ__r.Category__c, RFQ__r.Part_Number__c,
                   RFQ__r.Target_Unit_Price__c, RFQ__r.Required_Quantity__c,
                   RFQ__r.Selected_Quote__c
            FROM RFQ_Quote__c
            WHERE Supplier__c = :accountId
            ORDER BY CreatedDate DESC
        ];

        Integer totalQuotes = quotes.size();
        Integer adoptedCount = 0;
        Integer respondedCount = 0;
        Integer declinedCount = 0;
        Decimal totalScore = 0;
        Integer scoredCount = 0;

        List<Map<String, Object>> quoteList = new List<Map<String, Object>>();

        for (RFQ_Quote__c q : quotes) {
            if (q.Status__c == '採用') adoptedCount++;
            if (q.Status__c == '回答済' || q.Status__c == '採用' || q.Status__c == '不採用') respondedCount++;
            if (q.Status__c == '辞退') declinedCount++;
            if (q.Score__c != null) {
                totalScore += q.Score__c;
                scoredCount++;
            }

            Map<String, Object> qm = new Map<String, Object>();
            qm.put('Id', q.Id);
            qm.put('Name', q.Name);
            qm.put('Status', q.Status__c);
            qm.put('UnitPrice', q.Unit_Price__c);
            qm.put('LeadTimeDays', q.Lead_Time_Days__c);
            qm.put('MOQ', q.MOQ__c);
            qm.put('Score', q.Score__c);
            qm.put('ResponseDate', q.Response_Date__c);
            qm.put('Notes', q.Notes__c);
            qm.put('SiteName', q.Manufacturing_Site__r != null ? q.Manufacturing_Site__r.Name : '');
            qm.put('RFQName', q.RFQ__r.Name);
            qm.put('RFQTitle', q.RFQ__r.Title__c);
            qm.put('RFQStatus', q.RFQ__r.Status__c);
            qm.put('RFQCategory', q.RFQ__r.Category__c);
            qm.put('RFQPartNumber', q.RFQ__r.Part_Number__c);
            qm.put('RFQTargetPrice', q.RFQ__r.Target_Unit_Price__c);
            qm.put('RFQId', q.RFQ__c);
            qm.put('isSelected', q.RFQ__r.Selected_Quote__c == q.Id);

            if (q.RFQ__r.Target_Unit_Price__c != null && q.Unit_Price__c != null) {
                Decimal diff = ((q.Unit_Price__c - q.RFQ__r.Target_Unit_Price__c) / q.RFQ__r.Target_Unit_Price__c * 100);
                qm.put('vsTarget', diff.setScale(1));
            }
            quoteList.add(qm);
        }

        Map<String, Object> result = new Map<String, Object>();
        result.put('quotes', quoteList);
        result.put('totalQuotes', totalQuotes);
        result.put('adoptedCount', adoptedCount);
        result.put('respondedCount', respondedCount);
        result.put('declinedCount', declinedCount);
        result.put('adoptionRate', respondedCount > 0 ? (Decimal.valueOf(adoptedCount) / respondedCount * 100).setScale(1) : 0);
        result.put('avgScore', scoredCount > 0 ? (totalScore / scoredCount).setScale(1) : null);

        return result;
    }
}
