public with sharing class SalesAgreementScheduleController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getScheduleData(Id agreementId) {
        Sales_Agreement__c sa = [
            SELECT Id, Name, Contract_Start__c, Contract_End__c, Status__c,
                   Source_Opportunity__c
            FROM Sales_Agreement__c WHERE Id = :agreementId
        ];

        // 契約製品とスケジュール
        List<Sales_Agreement_Product__c> products = [
            SELECT Id, Product__r.Name, Unit_Price__c,
                (SELECT Id, Schedule_Month__c, Plan_Quantity__c, Plan_Amount__c,
                        Actual_Quantity__c, Actual_Amount__c
                 FROM Schedules__r
                 ORDER BY Schedule_Month__c)
            FROM Sales_Agreement_Product__c
            WHERE Sales_Agreement__c = :agreementId
            ORDER BY Product__r.Name
        ];

        // Revenue Forecast参考値（Source Opportunityから）
        List<Map<String, Object>> forecasts = new List<Map<String, Object>>();
        if (sa.Source_Opportunity__c != null) {
            for (Revenue_Forecast__c rf : [
                SELECT Product__r.Name, Fiscal_Year__c, Fiscal_Quarter__c,
                       Forecast_Quantity__c, Unit_Price__c
                FROM Revenue_Forecast__c
                WHERE Opportunity__c = :sa.Source_Opportunity__c
                  AND Status__c = '予測中'
                ORDER BY Product__r.Name, Fiscal_Year__c, Fiscal_Quarter__c
            ]) {
                Map<String, Object> f = new Map<String, Object>();
                f.put('productName', rf.Product__r.Name);
                f.put('period', rf.Fiscal_Year__c + ' ' + rf.Fiscal_Quarter__c);
                f.put('quantity', rf.Forecast_Quantity__c);
                f.put('unitPrice', rf.Unit_Price__c);
                forecasts.add(f);
            }
        }

        // 製品・スケジュールをシリアライズ
        List<Map<String, Object>> prodList = new List<Map<String, Object>>();
        for (Sales_Agreement_Product__c sap : products) {
            Map<String, Object> p = new Map<String, Object>();
            p.put('id', sap.Id);
            p.put('productName', sap.Product__r.Name);
            p.put('unitPrice', sap.Unit_Price__c);

            List<Map<String, Object>> schedules = new List<Map<String, Object>>();
            for (Sales_Agreement_Schedule__c s : sap.Schedules__r) {
                Map<String, Object> sc = new Map<String, Object>();
                sc.put('id', s.Id);
                sc.put('month', s.Schedule_Month__c);
                sc.put('planQty', s.Plan_Quantity__c);
                sc.put('planAmt', s.Plan_Amount__c);
                sc.put('actualQty', s.Actual_Quantity__c);
                sc.put('actualAmt', s.Actual_Amount__c);
                schedules.add(sc);
            }
            p.put('schedules', schedules);
            prodList.add(p);
        }

        Map<String, Object> result = new Map<String, Object>();
        result.put('agreement', new Map<String, Object>{
            'name' => sa.Name,
            'status' => sa.Status__c,
            'contractStart' => sa.Contract_Start__c,
            'contractEnd' => sa.Contract_End__c
        });
        result.put('products', prodList);
        result.put('forecasts', forecasts);
        return result;
    }

    @AuraEnabled
    public static void saveSchedules(String schedulesJson) {
        List<Object> items = (List<Object>) JSON.deserializeUntyped(schedulesJson);
        List<Sales_Agreement_Schedule__c> toUpdate = new List<Sales_Agreement_Schedule__c>();

        for (Object obj : items) {
            Map<String, Object> item = (Map<String, Object>) obj;
            Sales_Agreement_Schedule__c rec = new Sales_Agreement_Schedule__c();
            rec.Id = (String) item.get('id');

            Object pq = item.get('planQty');
            Object pa = item.get('planAmt');
            Object aq = item.get('actualQty');
            Object aa = item.get('actualAmt');

            rec.Plan_Quantity__c = pq != null ? Decimal.valueOf(String.valueOf(pq)) : null;
            rec.Plan_Amount__c = pa != null ? Decimal.valueOf(String.valueOf(pa)) : null;
            rec.Actual_Quantity__c = aq != null ? Decimal.valueOf(String.valueOf(aq)) : null;
            rec.Actual_Amount__c = aa != null ? Decimal.valueOf(String.valueOf(aa)) : null;

            toUpdate.add(rec);
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }
}
