public with sharing class DesignWinConversionController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getConversionPreview(Id opportunityId) {
        Opportunity opp = [
            SELECT Id, Name, AccountId, Account.Name, StageName,
                   RecordType.DeveloperName
            FROM Opportunity
            WHERE Id = :opportunityId
        ];

        // 四半期予測を製品別に集約
        List<Revenue_Forecast__c> forecasts = [
            SELECT Product__c, Product__r.Name, Fiscal_Year__c, Fiscal_Quarter__c,
                   Forecast_Quantity__c, Unit_Price__c, Forecast_Amount__c, Status__c
            FROM Revenue_Forecast__c
            WHERE Opportunity__c = :opportunityId
              AND Status__c = '予測中'
            ORDER BY Product__r.Name, Fiscal_Year__c, Fiscal_Quarter__c
        ];

        // 既存の販売契約チェック
        List<Sales_Agreement__c> existingAgreements = [
            SELECT Id, Name FROM Sales_Agreement__c
            WHERE Source_Opportunity__c = :opportunityId
        ];

        // 製品別サマリー
        Map<Id, Map<String, Object>> productMap = new Map<Id, Map<String, Object>>();
        for (Revenue_Forecast__c rf : forecasts) {
            if (!productMap.containsKey(rf.Product__c)) {
                Map<String, Object> p = new Map<String, Object>();
                p.put('productId', rf.Product__c);
                p.put('productName', rf.Product__r.Name);
                p.put('unitPrice', rf.Unit_Price__c);
                p.put('totalQty', (Decimal) 0);
                p.put('totalAmt', (Decimal) 0);
                productMap.put(rf.Product__c, p);
            }
            Map<String, Object> pm = productMap.get(rf.Product__c);
            Decimal qty = rf.Forecast_Quantity__c != null ? rf.Forecast_Quantity__c : 0;
            Decimal amt = rf.Forecast_Amount__c != null ? rf.Forecast_Amount__c : 0;
            pm.put('totalQty', (Decimal) pm.get('totalQty') + qty);
            pm.put('totalAmt', (Decimal) pm.get('totalAmt') + amt);
        }

        Map<String, Object> result = new Map<String, Object>();
        result.put('oppName', opp.Name);
        result.put('accountName', opp.Account.Name);
        result.put('stageName', opp.StageName);
        result.put('isDesignWin', opp.RecordType.DeveloperName == 'Design_Win');
        result.put('isClosed', opp.StageName == 'Design_Win');
        result.put('products', productMap.values());
        result.put('forecastCount', forecasts.size());
        result.put('hasExisting', !existingAgreements.isEmpty());
        result.put('existingName', existingAgreements.isEmpty() ? null : existingAgreements[0].Name);
        return result;
    }

    @AuraEnabled
    public static Id convertToAgreement(Id opportunityId, Date contractStart, Date contractEnd) {
        Opportunity opp = [
            SELECT Id, Name, AccountId, StageName, RecordType.DeveloperName
            FROM Opportunity WHERE Id = :opportunityId
        ];

        if (opp.RecordType.DeveloperName != 'Design_Win') {
            throw new AuraHandledException('Design Win商談のみ変換可能です。');
        }

        // 既存チェック
        List<Sales_Agreement__c> existing = [
            SELECT Id FROM Sales_Agreement__c
            WHERE Source_Opportunity__c = :opportunityId
        ];
        if (!existing.isEmpty()) {
            throw new AuraHandledException('この商談から既に販売契約が作成されています。');
        }

        // ① Sales_Agreement__c 作成
        Sales_Agreement__c sa = new Sales_Agreement__c();
        sa.Account__c = opp.AccountId;
        sa.Source_Opportunity__c = opp.Id;
        sa.Contract_Start__c = contractStart;
        sa.Contract_End__c = contractEnd;
        sa.Status__c = '有効';
        insert sa;

        // 予測データ取得（製品別に集約）
        List<Revenue_Forecast__c> forecasts = [
            SELECT Id, Product__c, Product__r.Name, Unit_Price__c, Status__c
            FROM Revenue_Forecast__c
            WHERE Opportunity__c = :opportunityId
              AND Status__c = '予測中'
            ORDER BY Product__r.Name
        ];

        // 製品別にユニークなUnit_Priceを取得
        Map<Id, Decimal> productPrices = new Map<Id, Decimal>();
        Set<Id> forecastIds = new Set<Id>();
        for (Revenue_Forecast__c rf : forecasts) {
            if (!productPrices.containsKey(rf.Product__c)) {
                productPrices.put(rf.Product__c, rf.Unit_Price__c);
            }
            forecastIds.add(rf.Id);
        }

        // ② Sales_Agreement_Product__c 作成
        Map<Id, Sales_Agreement_Product__c> sapMap = new Map<Id, Sales_Agreement_Product__c>();
        for (Id productId : productPrices.keySet()) {
            Sales_Agreement_Product__c sap = new Sales_Agreement_Product__c();
            sap.Sales_Agreement__c = sa.Id;
            sap.Product__c = productId;
            sap.Unit_Price__c = productPrices.get(productId);
            sapMap.put(productId, sap);
        }
        insert sapMap.values();

        // ③ 月別スケジュール作成（空の箱）
        List<Sales_Agreement_Schedule__c> schedules = new List<Sales_Agreement_Schedule__c>();
        for (Id productId : sapMap.keySet()) {
            Sales_Agreement_Product__c sap = sapMap.get(productId);
            Date monthDate = contractStart.toStartOfMonth();
            Date endMonth = contractEnd.toStartOfMonth();
            while (monthDate <= endMonth) {
                Sales_Agreement_Schedule__c sch = new Sales_Agreement_Schedule__c();
                sch.Sales_Agreement_Product__c = sap.Id;
                sch.Schedule_Month__c = monthDate;
                sch.Plan_Quantity__c = 0;
                sch.Plan_Amount__c = 0;
                schedules.add(sch);
                monthDate = monthDate.addMonths(1);
            }
        }
        insert schedules;

        // ④ Revenue_Forecast__c のステータスを契約移行済に更新
        List<Revenue_Forecast__c> toUpdate = new List<Revenue_Forecast__c>();
        for (Id rfId : forecastIds) {
            Revenue_Forecast__c rf = new Revenue_Forecast__c();
            rf.Id = rfId;
            rf.Status__c = '契約移行済';
            toUpdate.add(rf);
        }
        update toUpdate;

        return sa.Id;
    }
}
