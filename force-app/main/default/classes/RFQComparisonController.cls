public with sharing class RFQComparisonController {

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getRFQsForPart(Id bomPartId) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        List<RFQ__c> rfqs = [
            SELECT Id, Name, Title__c, Status__c, Category__c, Due_Date__c,
                   Part_Number__c, Part_Spec__c, Required_Quantity__c,
                   Target_Unit_Price__c, Selected_Quote__c, Notes__c,
                   BOM_Part__r.Part_Name__c, BOM_Part__r.Part_Number__c
            FROM RFQ__c
            WHERE BOM_Part__c = :bomPartId
            ORDER BY CreatedDate DESC
        ];
        for (RFQ__c rfq : rfqs) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('Id', rfq.Id);
            m.put('Name', rfq.Name);
            m.put('Title', rfq.Title__c);
            m.put('Status', rfq.Status__c);
            m.put('Category', rfq.Category__c);
            m.put('DueDate', rfq.Due_Date__c);
            m.put('PartNumber', rfq.Part_Number__c);
            m.put('PartSpec', rfq.Part_Spec__c);
            m.put('RequiredQuantity', rfq.Required_Quantity__c);
            m.put('TargetUnitPrice', rfq.Target_Unit_Price__c);
            m.put('SelectedQuoteId', rfq.Selected_Quote__c);
            m.put('Notes', rfq.Notes__c);
            result.add(m);
        }
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getRFQWithQuotes(Id rfqId) {
        RFQ__c rfq = [
            SELECT Id, Name, Title__c, Status__c, Category__c, Due_Date__c,
                   Part_Number__c, Part_Spec__c, Required_Quantity__c,
                   Target_Unit_Price__c, Selected_Quote__c, Notes__c,
                   BOM_Part__c, BOM_Part__r.Part_Name__c, BOM_Part__r.Part_Number__c,
                   BOM_Part__r.Unit_Cost__c
            FROM RFQ__c
            WHERE Id = :rfqId
            LIMIT 1
        ];

        List<RFQ_Quote__c> quotes = [
            SELECT Id, Name, Status__c, Unit_Price__c, Lead_Time_Days__c,
                   MOQ__c, Valid_Until__c, Response_Date__c, Score__c, Notes__c,
                   Supplier__c, Supplier__r.Name,
                   Manufacturing_Site__c, Manufacturing_Site__r.Name
            FROM RFQ_Quote__c
            WHERE RFQ__c = :rfqId
            ORDER BY Unit_Price__c ASC NULLS LAST
        ];

        Map<String, Object> result = new Map<String, Object>();
        result.put('Id', rfq.Id);
        result.put('Name', rfq.Name);
        result.put('Title', rfq.Title__c);
        result.put('Status', rfq.Status__c);
        result.put('Category', rfq.Category__c);
        result.put('DueDate', rfq.Due_Date__c);
        result.put('PartNumber', rfq.Part_Number__c);
        result.put('PartSpec', rfq.Part_Spec__c);
        result.put('RequiredQuantity', rfq.Required_Quantity__c);
        result.put('TargetUnitPrice', rfq.Target_Unit_Price__c);
        result.put('SelectedQuoteId', rfq.Selected_Quote__c);
        result.put('Notes', rfq.Notes__c);
        result.put('BomPartId', rfq.BOM_Part__c);
        result.put('CurrentUnitCost', rfq.BOM_Part__r != null ? rfq.BOM_Part__r.Unit_Cost__c : null);

        Decimal bestPrice = null;
        Integer bestLeadTime = null;
        for (RFQ_Quote__c q : quotes) {
            if (q.Unit_Price__c != null && (bestPrice == null || q.Unit_Price__c < bestPrice)) {
                bestPrice = q.Unit_Price__c;
            }
            if (q.Lead_Time_Days__c != null && (bestLeadTime == null || q.Lead_Time_Days__c < bestLeadTime)) {
                bestLeadTime = Integer.valueOf(q.Lead_Time_Days__c);
            }
        }

        List<Map<String, Object>> quoteList = new List<Map<String, Object>>();
        for (RFQ_Quote__c q : quotes) {
            Map<String, Object> qm = new Map<String, Object>();
            qm.put('Id', q.Id);
            qm.put('Name', q.Name);
            qm.put('Status', q.Status__c);
            qm.put('UnitPrice', q.Unit_Price__c);
            qm.put('LeadTimeDays', q.Lead_Time_Days__c);
            qm.put('MOQ', q.MOQ__c);
            qm.put('ValidUntil', q.Valid_Until__c);
            qm.put('ResponseDate', q.Response_Date__c);
            qm.put('Score', q.Score__c);
            qm.put('Notes', q.Notes__c);
            qm.put('SupplierName', q.Supplier__r != null ? q.Supplier__r.Name : '');
            qm.put('SupplierId', q.Supplier__c);
            qm.put('SiteName', q.Manufacturing_Site__r != null ? q.Manufacturing_Site__r.Name : '');
            qm.put('SiteId', q.Manufacturing_Site__c);
            qm.put('isBestPrice', q.Unit_Price__c != null && bestPrice != null && q.Unit_Price__c == bestPrice);
            qm.put('isBestLeadTime', q.Lead_Time_Days__c != null && bestLeadTime != null && Integer.valueOf(q.Lead_Time_Days__c) == bestLeadTime);
            qm.put('isSelected', rfq.Selected_Quote__c == q.Id);
            quoteList.add(qm);
        }
        result.put('quotes', quoteList);
        result.put('quoteCount', quotes.size());

        return result;
    }

    @AuraEnabled
    public static void adoptQuote(Id rfqId, Id quoteId) {
        List<RFQ_Quote__c> allQuotes = [
            SELECT Id, Status__c FROM RFQ_Quote__c WHERE RFQ__c = :rfqId
        ];
        List<RFQ_Quote__c> toUpdate = new List<RFQ_Quote__c>();
        for (RFQ_Quote__c q : allQuotes) {
            if (q.Id == quoteId) {
                q.Status__c = '採用';
            } else if (q.Status__c != '辞退') {
                q.Status__c = '不採用';
            }
            toUpdate.add(q);
        }
        update toUpdate;

        RFQ__c rfq = new RFQ__c(Id = rfqId);
        rfq.Selected_Quote__c = quoteId;
        rfq.Status__c = '決定済';
        update rfq;
    }
}
