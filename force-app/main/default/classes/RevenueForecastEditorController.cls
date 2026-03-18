public with sharing class RevenueForecastEditorController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getForecasts(Id opportunityId) {
        // 既存レコード取得
        List<Revenue_Forecast__c> records = [
            SELECT Id, Fiscal_Year__c, Fiscal_Quarter__c, Product__c, Product__r.Name,
                   Forecast_Quantity__c, Unit_Price__c, Forecast_Amount__c,
                   Probability__c, Weighted_Amount__c, Status__c
            FROM Revenue_Forecast__c
            WHERE Opportunity__c = :opportunityId
            ORDER BY Product__r.Name, Fiscal_Year__c, Fiscal_Quarter__c
        ];

        // 既にForecastに使われている製品を収集
        Map<Id, String> productMap = new Map<Id, String>();
        for (Revenue_Forecast__c rf : records) {
            if (rf.Product__c != null) {
                productMap.put(rf.Product__c, rf.Product__r.Name);
            }
        }

        // 全Active製品を選択肢に（既存製品を先頭に、残りを名前順で追加）
        List<Product2> allProducts = [
            SELECT Id, Name FROM Product2
            WHERE IsActive = true
            ORDER BY Name
        ];
        List<Map<String, Object>> productOptions = new List<Map<String, Object>>();
        // まず既存Forecast製品
        for (Id pid : productMap.keySet()) {
            Map<String, Object> opt = new Map<String, Object>();
            opt.put('value', pid);
            opt.put('label', productMap.get(pid));
            productOptions.add(opt);
        }
        // 残りのActive製品
        for (Product2 p : allProducts) {
            if (!productMap.containsKey(p.Id)) {
                Map<String, Object> opt = new Map<String, Object>();
                opt.put('value', p.Id);
                opt.put('label', p.Name);
                productOptions.add(opt);
            }
        }

        // レコードをシリアライズ
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Revenue_Forecast__c rf : records) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('id', rf.Id);
            row.put('fiscalYear', rf.Fiscal_Year__c);
            row.put('quarter', rf.Fiscal_Quarter__c);
            row.put('productId', rf.Product__c);
            row.put('productName', rf.Product__r != null ? rf.Product__r.Name : '');
            row.put('quantity', rf.Forecast_Quantity__c);
            row.put('unitPrice', rf.Unit_Price__c);
            row.put('amount', rf.Forecast_Amount__c);
            row.put('probability', rf.Probability__c);
            row.put('weightedAmount', rf.Weighted_Amount__c);
            row.put('status', rf.Status__c);
            rows.add(row);
        }

        Map<String, Object> result = new Map<String, Object>();
        result.put('records', rows);
        result.put('productOptions', productOptions);
        return result;
    }

    // 製品のデフォルト単価を標準価格表(JPY)から取得
    @AuraEnabled
    public static Decimal getDefaultPrice(Id productId) {
        List<PricebookEntry> entries = [
            SELECT UnitPrice FROM PricebookEntry
            WHERE Product2Id = :productId
              AND Pricebook2.IsStandard = true
              AND CurrencyIsoCode = 'JPY'
              AND IsActive = true
            LIMIT 1
        ];
        if (entries.isEmpty()) {
            // JPYがなければ通貨問わず標準価格表から取得
            entries = [
                SELECT UnitPrice FROM PricebookEntry
                WHERE Product2Id = :productId
                  AND Pricebook2.IsStandard = true
                  AND IsActive = true
                LIMIT 1
            ];
        }
        return entries.isEmpty() ? 0 : entries[0].UnitPrice;
    }

    @AuraEnabled
    public static void saveForecasts(Id opportunityId, String forecastsJson) {
        List<Object> forecasts = (List<Object>) JSON.deserializeUntyped(forecastsJson);

        List<Revenue_Forecast__c> toUpsert = new List<Revenue_Forecast__c>();
        List<Id> toDelete = new List<Id>();

        for (Object obj : forecasts) {
            Map<String, Object> f = (Map<String, Object>) obj;
            String action = (String) f.get('action');

            if (action == 'delete') {
                String recId = (String) f.get('id');
                if (recId != null) {
                    toDelete.add(recId);
                }
                continue;
            }

            Revenue_Forecast__c rec = new Revenue_Forecast__c();
            String recId = (String) f.get('id');
            if (recId != null && recId != '') {
                rec.Id = recId;
            }
            rec.Opportunity__c = opportunityId;
            rec.Fiscal_Year__c = (String) f.get('fiscalYear');
            rec.Fiscal_Quarter__c = (String) f.get('quarter');
            rec.Product__c = (String) f.get('productId');

            Object qty = f.get('quantity');
            rec.Forecast_Quantity__c = qty != null ? Decimal.valueOf(String.valueOf(qty)) : 0;

            Object price = f.get('unitPrice');
            rec.Unit_Price__c = price != null ? Decimal.valueOf(String.valueOf(price)) : 0;

            toUpsert.add(rec);
        }

        if (!toDelete.isEmpty()) {
            delete [SELECT Id FROM Revenue_Forecast__c WHERE Id IN :toDelete];
        }
        if (!toUpsert.isEmpty()) {
            upsert toUpsert;
        }
    }
}
