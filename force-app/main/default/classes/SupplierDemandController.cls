public with sharing class SupplierDemandController {

    @AuraEnabled(cacheable=true)
    public static SupplierDemandResult getSupplierDemand(Id accountId) {
        SupplierDemandResult result = new SupplierDemandResult();
        result.parts = new List<SupplierPartInfo>();
        result.confirmed = new List<ConfirmedProductDemand>();
        result.pipeline = new List<PipelineProductDemand>();

        // Phase 1: BOM逆引き（このサプライヤーの部品 -> 製品）
        List<BOM_Part__c> bomParts = [
            SELECT Part_Name__c, Part_Number__c, Quantity__c,
                   Manufacturing_Site__c, Manufacturing_Site__r.Name,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name
            FROM BOM_Part__c
            WHERE Supplier__c = :accountId
              AND BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Status__c = '承認済'
        ];

        if (bomParts.isEmpty()) return result;

        // 製品別に部品を集約（Part_Number__cで重複排除）
        Map<Id, Map<String, PartBrief>> productPartsMap = new Map<Id, Map<String, PartBrief>>();
        Set<Id> productIds = new Set<Id>();
        Set<String> allPartNumbers = new Set<String>();
        Set<Id> allSiteIds = new Set<Id>();

        for (BOM_Part__c bp : bomParts) {
            Id prodId = bp.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c;
            String prodName = bp.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name;
            productIds.add(prodId);
            if (bp.Part_Number__c != null) allPartNumbers.add(bp.Part_Number__c);
            if (bp.Manufacturing_Site__c != null) allSiteIds.add(bp.Manufacturing_Site__c);

            if (!productPartsMap.containsKey(prodId)) {
                productPartsMap.put(prodId, new Map<String, PartBrief>());
            }
            Map<String, PartBrief> partsMap = productPartsMap.get(prodId);
            String pn = bp.Part_Number__c != null ? bp.Part_Number__c : bp.Part_Name__c;
            if (!partsMap.containsKey(pn)) {
                PartBrief pb = new PartBrief();
                pb.partName = bp.Part_Name__c;
                pb.partNumber = bp.Part_Number__c;
                pb.qtyPerUnit = bp.Quantity__c != null ? bp.Quantity__c : 0;
                partsMap.put(pn, pb);
            }
        }

        // キャパシティデータ取得
        Map<String, Supplier_Capacity__c> capMap = new Map<String, Supplier_Capacity__c>();
        if (!allPartNumbers.isEmpty() && !allSiteIds.isEmpty()) {
            List<Supplier_Capacity__c> caps = [
                SELECT Part_Number__c, Monthly_Capacity__c,
                       Manufacturing_Site__c, Manufacturing_Site__r.Name
                FROM Supplier_Capacity__c
                WHERE Part_Number__c IN :allPartNumbers
                  AND Manufacturing_Site__c IN :allSiteIds
                  AND (Effective_To__c = null OR Effective_To__c >= TODAY)
                  AND Effective_From__c <= TODAY
            ];
            for (Supplier_Capacity__c sc : caps) {
                String capKey = sc.Part_Number__c + '-' + sc.Manufacturing_Site__c;
                capMap.put(capKey, sc);
            }
        }

        // 供給部品一覧（キャパシティ情報付き）
        Set<String> seenParts = new Set<String>();
        for (BOM_Part__c bp : bomParts) {
            String pn = bp.Part_Number__c != null ? bp.Part_Number__c : bp.Part_Name__c;
            if (!seenParts.contains(pn)) {
                SupplierPartInfo spi = new SupplierPartInfo();
                spi.partName = bp.Part_Name__c;
                spi.partNumber = bp.Part_Number__c;
                spi.qtyPerUnit = bp.Quantity__c != null ? bp.Quantity__c : 0;
                Id prodId = bp.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c;
                spi.productName = bp.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name;

                // キャパシティ情報を付与
                if (bp.Part_Number__c != null && bp.Manufacturing_Site__c != null) {
                    String capKey = bp.Part_Number__c + '-' + bp.Manufacturing_Site__c;
                    Supplier_Capacity__c cap = capMap.get(capKey);
                    if (cap != null) {
                        spi.monthlyCapacity = cap.Monthly_Capacity__c;
                        spi.siteName = cap.Manufacturing_Site__r.Name;
                    }
                }
                if (spi.siteName == null && bp.Manufacturing_Site__r.Name != null) {
                    spi.siteName = bp.Manufacturing_Site__r.Name;
                }

                result.parts.add(spi);
                seenParts.add(pn);
            }
        }

        // Phase 2: 確定需要（Sales Agreement）
        List<Sales_Agreement_Product__c> saps = [
            SELECT Product__c, Product__r.Name,
                   Sales_Agreement__r.Id, Sales_Agreement__r.Name, Sales_Agreement__r.Status__c,
                   Sales_Agreement__r.Account__c, Sales_Agreement__r.Account__r.Name,
                (SELECT Schedule_Month__c, Plan_Quantity__c, Actual_Quantity__c
                 FROM Schedules__r
                 ORDER BY Schedule_Month__c)
            FROM Sales_Agreement_Product__c
            WHERE Product__c IN :productIds
        ];

        // 製品別 -> 顧客別に集約
        Map<Id, ConfirmedProductDemand> confirmedMap = new Map<Id, ConfirmedProductDemand>();
        Decimal totalConfirmedPartQty = 0;
        Integer totalCustomers = 0;
        Set<Id> customerSet = new Set<Id>();

        // 製品別の確定需要合計（月平均計算用）
        Map<Id, Decimal> confirmedPlanByProduct = new Map<Id, Decimal>();
        Map<Id, Integer> confirmedMonthsByProduct = new Map<Id, Integer>();

        for (Sales_Agreement_Product__c sap : saps) {
            Id prodId = sap.Product__c;
            if (!confirmedMap.containsKey(prodId)) {
                ConfirmedProductDemand cpd = new ConfirmedProductDemand();
                cpd.productId = prodId;
                cpd.productName = sap.Product__r.Name;
                cpd.parts = new List<PartBrief>(productPartsMap.get(prodId).values());
                cpd.customers = new List<CustomerDemand>();
                cpd.totalPlanQty = 0;
                cpd.totalPartDemandQty = 0;
                confirmedMap.put(prodId, cpd);
            }
            ConfirmedProductDemand cpd = confirmedMap.get(prodId);

            CustomerDemand cd = new CustomerDemand();
            cd.customerId = sap.Sales_Agreement__r.Account__c;
            cd.customerName = sap.Sales_Agreement__r.Account__r.Name;
            cd.agreementId = sap.Sales_Agreement__r.Id;
            cd.agreementName = sap.Sales_Agreement__r.Name;
            cd.status = sap.Sales_Agreement__r.Status__c;
            customerSet.add(cd.customerId);

            Decimal planQty = 0, actualQty = 0;
            Integer monthCount = 0;
            cd.schedules = new List<MonthSchedule>();
            for (Sales_Agreement_Schedule__c sch : sap.Schedules__r) {
                Decimal p = sch.Plan_Quantity__c != null ? sch.Plan_Quantity__c : 0;
                Decimal a = sch.Actual_Quantity__c != null ? sch.Actual_Quantity__c : 0;
                planQty += p;
                actualQty += a;
                monthCount++;
                MonthSchedule ms = new MonthSchedule();
                ms.month = sch.Schedule_Month__c;
                ms.planQty = p;
                ms.actualQty = a;
                cd.schedules.add(ms);
            }
            cd.totalPlanQty = planQty;
            cd.totalActualQty = actualQty;

            // 部品所要数量 = 製品計画数量 x 各部品の必要数の合計
            Decimal partDemand = 0;
            for (PartBrief pb : cpd.parts) {
                partDemand += planQty * pb.qtyPerUnit;
            }
            cd.totalPartDemandQty = partDemand;

            cpd.customers.add(cd);
            cpd.totalPlanQty += planQty;
            cpd.totalPartDemandQty += partDemand;
            totalConfirmedPartQty += partDemand;

            // 月平均計算用に蓄積
            Decimal prevPlan = confirmedPlanByProduct.containsKey(prodId) ? confirmedPlanByProduct.get(prodId) : 0;
            confirmedPlanByProduct.put(prodId, prevPlan + planQty);
            Integer prevMonths = confirmedMonthsByProduct.containsKey(prodId) ? confirmedMonthsByProduct.get(prodId) : 0;
            confirmedMonthsByProduct.put(prodId, Math.max(prevMonths, monthCount));
        }
        result.confirmed = confirmedMap.values();
        totalCustomers = customerSet.size();

        // 稼働率計算: 月平均需要 vs キャパシティ
        for (SupplierPartInfo spi : result.parts) {
            if (spi.monthlyCapacity != null && spi.monthlyCapacity > 0 && spi.partNumber != null) {
                // この部品に関連する全製品の月平均需要を合算
                Decimal totalMonthlyDemand = 0;
                for (Id prodId : productPartsMap.keySet()) {
                    Map<String, PartBrief> partsMap = productPartsMap.get(prodId);
                    PartBrief pb = partsMap.get(spi.partNumber);
                    if (pb != null && confirmedPlanByProduct.containsKey(prodId)) {
                        Decimal totalPlan = confirmedPlanByProduct.get(prodId);
                        Integer months = confirmedMonthsByProduct.containsKey(prodId) ? confirmedMonthsByProduct.get(prodId) : 1;
                        if (months > 0) {
                            Decimal monthlyAvg = totalPlan / months;
                            totalMonthlyDemand += monthlyAvg * pb.qtyPerUnit;
                        }
                    }
                }
                spi.utilizationPct = (totalMonthlyDemand / spi.monthlyCapacity * 100).setScale(1);
            }
        }

        // Phase 3: パイプライン需要（Revenue Forecast）
        List<Revenue_Forecast__c> forecasts = [
            SELECT Product__c, Product__r.Name, Fiscal_Year__c, Fiscal_Quarter__c,
                   Forecast_Quantity__c, Forecast_Amount__c, Weighted_Amount__c,
                   Opportunity__r.Id, Opportunity__r.Name, Opportunity__r.StageName,
                   Opportunity__r.Probability,
                   Opportunity__r.AccountId, Opportunity__r.Account.Name
            FROM Revenue_Forecast__c
            WHERE Product__c IN :productIds
              AND Status__c = '予測中'
              AND Opportunity__r.RecordType.DeveloperName = 'Design_Win'
              AND Opportunity__r.IsClosed = false
            ORDER BY Fiscal_Year__c, Fiscal_Quarter__c
        ];

        Map<Id, PipelineProductDemand> pipelineMap = new Map<Id, PipelineProductDemand>();
        Decimal totalPipelineWeighted = 0;
        Integer totalOpps = 0;
        Set<Id> oppSet = new Set<Id>();

        for (Revenue_Forecast__c rf : forecasts) {
            Id prodId = rf.Product__c;
            if (!pipelineMap.containsKey(prodId)) {
                PipelineProductDemand ppd = new PipelineProductDemand();
                ppd.productId = prodId;
                ppd.productName = rf.Product__r.Name;
                ppd.parts = new List<PartBrief>(productPartsMap.get(prodId).values());
                ppd.opportunities = new List<PipelineOpp>();
                ppd.totalWeightedQty = 0;
                ppd.totalWeightedAmt = 0;
                pipelineMap.put(prodId, ppd);
            }
            PipelineProductDemand ppd = pipelineMap.get(prodId);

            // 商談単位でグループ化
            Id oppId = rf.Opportunity__r.Id;
            PipelineOpp po = null;
            for (PipelineOpp existing : ppd.opportunities) {
                if (existing.oppId == oppId) { po = existing; break; }
            }
            if (po == null) {
                po = new PipelineOpp();
                po.oppId = oppId;
                po.oppName = rf.Opportunity__r.Name;
                po.customerId = rf.Opportunity__r.AccountId;
                po.customerName = rf.Opportunity__r.Account.Name;
                po.stageName = rf.Opportunity__r.StageName;
                po.probability = rf.Opportunity__r.Probability;
                po.forecasts = new List<ForecastPeriod>();
                po.totalWeightedAmt = 0;
                po.totalForecastQty = 0;
                po.totalPartDemandQty = 0;
                ppd.opportunities.add(po);
                oppSet.add(oppId);
            }

            ForecastPeriod fp = new ForecastPeriod();
            fp.fiscalYear = rf.Fiscal_Year__c;
            fp.quarter = rf.Fiscal_Quarter__c;
            fp.forecastQty = rf.Forecast_Quantity__c;
            fp.weightedAmt = rf.Weighted_Amount__c;
            po.forecasts.add(fp);

            Decimal wAmt = rf.Weighted_Amount__c != null ? rf.Weighted_Amount__c : 0;
            Decimal fQty = rf.Forecast_Quantity__c != null ? rf.Forecast_Quantity__c : 0;
            po.totalWeightedAmt += wAmt;
            po.totalForecastQty += fQty;

            // 部品所要数量（予測数量ベース）
            Decimal partDemand = 0;
            for (PartBrief pb : ppd.parts) {
                partDemand += fQty * pb.qtyPerUnit;
            }
            po.totalPartDemandQty += partDemand;

            ppd.totalWeightedAmt += wAmt;
            ppd.totalWeightedQty += fQty;
            totalPipelineWeighted += wAmt;
        }
        result.pipeline = pipelineMap.values();
        totalOpps = oppSet.size();

        // サマリー
        result.totalParts = result.parts.size();
        result.totalConfirmedPartQty = totalConfirmedPartQty;
        result.totalCustomers = totalCustomers;
        result.totalPipelineWeightedAmt = totalPipelineWeighted;
        result.totalPipelineOpps = totalOpps;
        result.totalProducts = productIds.size();

        return result;
    }

    // Inner Classes
    public class SupplierDemandResult {
        @AuraEnabled public List<SupplierPartInfo> parts;
        @AuraEnabled public List<ConfirmedProductDemand> confirmed;
        @AuraEnabled public List<PipelineProductDemand> pipeline;
        @AuraEnabled public Integer totalParts;
        @AuraEnabled public Integer totalProducts;
        @AuraEnabled public Decimal totalConfirmedPartQty;
        @AuraEnabled public Integer totalCustomers;
        @AuraEnabled public Decimal totalPipelineWeightedAmt;
        @AuraEnabled public Integer totalPipelineOpps;
    }
    public class SupplierPartInfo {
        @AuraEnabled public String partName;
        @AuraEnabled public String partNumber;
        @AuraEnabled public Decimal qtyPerUnit;
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal monthlyCapacity;
        @AuraEnabled public String siteName;
        @AuraEnabled public Decimal utilizationPct;
    }
    public class PartBrief {
        @AuraEnabled public String partName;
        @AuraEnabled public String partNumber;
        @AuraEnabled public Decimal qtyPerUnit;
    }
    public class ConfirmedProductDemand {
        @AuraEnabled public Id productId;
        @AuraEnabled public String productName;
        @AuraEnabled public List<PartBrief> parts;
        @AuraEnabled public List<CustomerDemand> customers;
        @AuraEnabled public Decimal totalPlanQty;
        @AuraEnabled public Decimal totalPartDemandQty;
    }
    public class CustomerDemand {
        @AuraEnabled public Id customerId;
        @AuraEnabled public String customerName;
        @AuraEnabled public Id agreementId;
        @AuraEnabled public String agreementName;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal totalPlanQty;
        @AuraEnabled public Decimal totalActualQty;
        @AuraEnabled public Decimal totalPartDemandQty;
        @AuraEnabled public List<MonthSchedule> schedules;
    }
    public class MonthSchedule {
        @AuraEnabled public Date month;
        @AuraEnabled public Decimal planQty;
        @AuraEnabled public Decimal actualQty;
    }
    public class PipelineProductDemand {
        @AuraEnabled public Id productId;
        @AuraEnabled public String productName;
        @AuraEnabled public List<PartBrief> parts;
        @AuraEnabled public List<PipelineOpp> opportunities;
        @AuraEnabled public Decimal totalWeightedQty;
        @AuraEnabled public Decimal totalWeightedAmt;
    }
    public class PipelineOpp {
        @AuraEnabled public Id oppId;
        @AuraEnabled public String oppName;
        @AuraEnabled public Id customerId;
        @AuraEnabled public String customerName;
        @AuraEnabled public String stageName;
        @AuraEnabled public Decimal probability;
        @AuraEnabled public List<ForecastPeriod> forecasts;
        @AuraEnabled public Decimal totalWeightedAmt;
        @AuraEnabled public Decimal totalForecastQty;
        @AuraEnabled public Decimal totalPartDemandQty;
    }
    public class ForecastPeriod {
        @AuraEnabled public String fiscalYear;
        @AuraEnabled public String quarter;
        @AuraEnabled public Decimal forecastQty;
        @AuraEnabled public Decimal weightedAmt;
    }
}
