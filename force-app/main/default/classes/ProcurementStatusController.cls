public with sharing class ProcurementStatusController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getStatusData() {
        Map<String, Object> result = new Map<String, Object>();
        Date today = Date.today();

        // 全RFQ取得
        List<RFQ__c> allRFQs = [
            SELECT Id, Name, Title__c, Status__c, Category__c,
                   Part_Number__c, Due_Date__c, Required_Quantity__c,
                   Target_Unit_Price__c, Selected_Quote__c,
                   (SELECT Id, Supplier__r.Name, Unit_Price__c, Lead_Time_Days__c,
                           Status__c, Response_Date__c
                    FROM Quotes__r
                    ORDER BY Unit_Price__c ASC NULLS LAST)
            FROM RFQ__c
            ORDER BY Due_Date__c ASC
        ];

        // ステータス別カウント
        Integer openCount = 0;
        Integer draftCount = 0;
        Integer issuedCount = 0;
        Integer evaluatingCount = 0;
        Integer decidedCount = 0;
        Integer dueSoonCount = 0;
        Date dueSoonThreshold = today.addDays(7);

        List<Map<String, Object>> rfqList = new List<Map<String, Object>>();
        List<Map<String, Object>> recentQuotes = new List<Map<String, Object>>();

        for (RFQ__c rfq : allRFQs) {
            String status = rfq.Status__c;
            if (status == '下書き') draftCount++;
            else if (status == '発行済') issuedCount++;
            else if (status == '評価中') evaluatingCount++;
            else if (status == '決定済') decidedCount++;

            Boolean isOpen = (status == '発行済' || status == '評価中');
            if (isOpen) openCount++;

            // 期限間近（オープンかつ7日以内）
            Boolean isDueSoon = isOpen && rfq.Due_Date__c != null
                && rfq.Due_Date__c <= dueSoonThreshold && rfq.Due_Date__c >= today;
            Boolean isOverdue = isOpen && rfq.Due_Date__c != null && rfq.Due_Date__c < today;
            if (isDueSoon || isOverdue) dueSoonCount++;

            // RFQ一覧データ
            Integer totalQuotes = rfq.Quotes__r != null ? rfq.Quotes__r.size() : 0;
            Integer respondedQuotes = 0;
            Decimal lowestPrice = null;
            if (rfq.Quotes__r != null) {
                for (RFQ_Quote__c q : rfq.Quotes__r) {
                    if (q.Status__c == '回答済' || q.Status__c == '採用' || q.Status__c == '不採用') {
                        respondedQuotes++;
                    }
                    if (q.Unit_Price__c != null && (lowestPrice == null || q.Unit_Price__c < lowestPrice)) {
                        lowestPrice = q.Unit_Price__c;
                    }
                }
            }

            Map<String, Object> rfqMap = new Map<String, Object>();
            rfqMap.put('id', rfq.Id);
            rfqMap.put('name', rfq.Name);
            rfqMap.put('title', rfq.Title__c);
            rfqMap.put('status', status);
            rfqMap.put('category', rfq.Category__c);
            rfqMap.put('partNumber', rfq.Part_Number__c);
            rfqMap.put('dueDate', String.valueOf(rfq.Due_Date__c));
            rfqMap.put('totalQuotes', totalQuotes);
            rfqMap.put('respondedQuotes', respondedQuotes);
            rfqMap.put('isDueSoon', isDueSoon);
            rfqMap.put('isOverdue', isOverdue);
            rfqMap.put('lowestPrice', lowestPrice);
            rfqMap.put('targetPrice', rfq.Target_Unit_Price__c);
            rfqList.add(rfqMap);

            // 最新の見積回答を収集
            if (rfq.Quotes__r != null) {
                for (RFQ_Quote__c q : rfq.Quotes__r) {
                    if (q.Response_Date__c != null && q.Status__c == '回答済') {
                        Map<String, Object> qMap = new Map<String, Object>();
                        qMap.put('rfqName', rfq.Name);
                        qMap.put('partNumber', rfq.Part_Number__c);
                        qMap.put('supplierName', q.Supplier__r?.Name);
                        qMap.put('unitPrice', q.Unit_Price__c);
                        qMap.put('leadTimeDays', q.Lead_Time_Days__c);
                        qMap.put('responseDate', String.valueOf(q.Response_Date__c));
                        qMap.put('isCheapest', q.Unit_Price__c == lowestPrice);
                        recentQuotes.add(qMap);
                    }
                }
            }
        }

        // 見積回答を回答日順にソート（降順）、上位10件
        recentQuotes.sort(new QuoteResponseDateComparator());
        if (recentQuotes.size() > 10) {
            List<Map<String, Object>> trimmed = new List<Map<String, Object>>();
            for (Integer i = 0; i < 10; i++) {
                trimmed.add(recentQuotes[i]);
            }
            recentQuotes = trimmed;
        }

        result.put('openCount', openCount);
        result.put('draftCount', draftCount);
        result.put('evaluatingCount', evaluatingCount);
        result.put('decidedCount', decidedCount);
        result.put('dueSoonCount', dueSoonCount);
        result.put('rfqList', rfqList);
        result.put('recentQuotes', recentQuotes);

        // カテゴリ別カウント（オープンのみ）
        Map<String, Integer> byCategory = new Map<String, Integer>();
        for (RFQ__c rfq : allRFQs) {
            if (rfq.Status__c == '発行済' || rfq.Status__c == '評価中') {
                String cat = rfq.Category__c;
                if (cat != null) {
                    byCategory.put(cat, (byCategory.containsKey(cat) ? byCategory.get(cat) : 0) + 1);
                }
            }
        }
        result.put('byCategory', byCategory);

        return result;
    }

    // 回答日降順ソート用Comparator
    private class QuoteResponseDateComparator implements System.Comparator<Map<String, Object>> {
        public Integer compare(Map<String, Object> a, Map<String, Object> b) {
            String dateA = (String) a.get('responseDate');
            String dateB = (String) b.get('responseDate');
            if (dateA == null && dateB == null) return 0;
            if (dateA == null) return 1;
            if (dateB == null) return -1;
            return dateB.compareTo(dateA);
        }
    }
}
