public with sharing class AccountForecastController {
    @AuraEnabled(cacheable=true)
    public static ForecastSummary getForecastData(Id accountId) {
        ForecastSummary summary = new ForecastSummary();

        // ── 1. Sales Agreements (確定収益) ──
        summary.agreements = new List<AgreementSummary>();
        List<Sales_Agreement__c> agreements = [
            SELECT Id, Name, Status__c, Contract_Start__c, Contract_End__c,
                (SELECT Product__r.Name, Unit_Price__c,
                    (SELECT Schedule_Month__c, Plan_Quantity__c, Plan_Amount__c,
                            Actual_Quantity__c, Actual_Amount__c
                     FROM Schedules__r
                     ORDER BY Schedule_Month__c)
                 FROM Agreement_Products__r)
            FROM Sales_Agreement__c
            WHERE Account__c = :accountId
            ORDER BY Contract_Start__c DESC
        ];
        Decimal totalPlanAmt = 0, totalActualAmt = 0;
        for (Sales_Agreement__c sa : agreements) {
            AgreementSummary as2 = new AgreementSummary();
            as2.id = sa.Id;
            as2.name = sa.Name;
            as2.status = sa.Status__c;
            as2.contractStart = sa.Contract_Start__c;
            as2.contractEnd = sa.Contract_End__c;
            as2.products = new List<AgreementProductSummary>();

            Decimal saPlan = 0, saActual = 0;
            Map<String, Decimal[]> agFYMap = new Map<String, Decimal[]>();

            for (Sales_Agreement_Product__c sap : sa.Agreement_Products__r) {
                AgreementProductSummary aps = new AgreementProductSummary();
                aps.productName = sap.Product__r.Name;
                Decimal pPlanQty = 0, pActualQty = 0, pPlanAmt = 0, pActualAmt = 0;
                Map<String, Decimal[]> prodFYMap = new Map<String, Decimal[]>();

                for (Sales_Agreement_Schedule__c s : sap.Schedules__r) {
                    Decimal sq = s.Plan_Quantity__c != null ? s.Plan_Quantity__c : 0;
                    Decimal sa2 = s.Actual_Quantity__c != null ? s.Actual_Quantity__c : 0;
                    Decimal sp = s.Plan_Amount__c != null ? s.Plan_Amount__c : 0;
                    Decimal sact = s.Actual_Amount__c != null ? s.Actual_Amount__c : 0;
                    pPlanQty += sq; pActualQty += sa2; pPlanAmt += sp; pActualAmt += sact;

                    String fy = deriveFY(s.Schedule_Month__c);
                    if (!prodFYMap.containsKey(fy)) prodFYMap.put(fy, new Decimal[]{0,0,0,0});
                    Decimal[] pv = prodFYMap.get(fy);
                    pv[0] += sq; pv[1] += sa2; pv[2] += sp; pv[3] += sact;

                    if (!agFYMap.containsKey(fy)) agFYMap.put(fy, new Decimal[]{0,0});
                    Decimal[] av = agFYMap.get(fy);
                    av[0] += sp; av[1] += sact;
                }
                aps.totalPlanQty = pPlanQty;
                aps.totalActualQty = pActualQty;
                aps.totalPlanAmt = pPlanAmt;
                aps.totalActualAmt = pActualAmt;
                aps.achievementRate = pPlanAmt > 0 ? (pActualAmt / pPlanAmt * 100).setScale(1) : 0;
                aps.fyAmounts = toFYAmountList(prodFYMap);
                as2.products.add(aps);
                saPlan += pPlanAmt;
                saActual += pActualAmt;
            }
            as2.totalPlanAmt = saPlan;
            as2.totalActualAmt = saActual;
            as2.achievementRate = saPlan > 0 ? (saActual / saPlan * 100).setScale(1) : 0;
            as2.fyAmounts = toFYAmountListSimple(agFYMap);
            summary.agreements.add(as2);
            totalPlanAmt += saPlan;
            totalActualAmt += saActual;
        }
        summary.totalPlanAmt = totalPlanAmt;
        summary.totalActualAmt = totalActualAmt;

        // ── 2. Revenue Forecasts (Design Win pipeline) ──
        summary.pipeline = new List<PipelineItem>();
        List<Opportunity> dwOpps = [
            SELECT Id, Name, StageName, Probability,
                (SELECT Product__r.Name, Fiscal_Year__c, Fiscal_Quarter__c,
                        Forecast_Quantity__c, Forecast_Amount__c,
                        Weighted_Amount__c, Status__c
                 FROM Revenue_Forecasts__r
                 WHERE Status__c = '予測中'
                 ORDER BY Fiscal_Year__c, Fiscal_Quarter__c)
            FROM Opportunity
            WHERE AccountId = :accountId
              AND RecordType.DeveloperName = 'Design_Win'
              AND IsClosed = false
            ORDER BY CloseDate
        ];
        Decimal totalWeighted = 0;
        for (Opportunity o : dwOpps) {
            PipelineItem pi = new PipelineItem();
            pi.oppId = o.Id;
            pi.oppName = o.Name;
            pi.stageName = o.StageName;
            pi.probability = o.Probability;
            pi.forecasts = new List<ForecastItem>();
            Decimal oppWeighted = 0;
            for (Revenue_Forecast__c rf : o.Revenue_Forecasts__r) {
                ForecastItem fi = new ForecastItem();
                fi.productName = rf.Product__r.Name;
                fi.fiscalYear = rf.Fiscal_Year__c;
                fi.quarter = rf.Fiscal_Quarter__c;
                fi.quantity = rf.Forecast_Quantity__c;
                fi.amount = rf.Forecast_Amount__c;
                fi.weightedAmount = rf.Weighted_Amount__c;
                pi.forecasts.add(fi);
                oppWeighted += rf.Weighted_Amount__c != null ? rf.Weighted_Amount__c : 0;
            }
            pi.totalWeightedAmount = oppWeighted;
            summary.pipeline.add(pi);
            totalWeighted += oppWeighted;
        }
        summary.totalWeightedPipeline = totalWeighted;

        // ── 3. Standard Opportunities (通常商談パイプライン) ──
        summary.standardPipeline = new List<StandardOppItem>();
        List<Opportunity> stdOpps = [
            SELECT Id, Name, StageName, Amount, Probability, CloseDate,
                   ExpectedRevenue, RecordType.Name
            FROM Opportunity
            WHERE AccountId = :accountId
              AND (RecordType.DeveloperName = 'SimpleOpportunity'
                   OR RecordType.DeveloperName = 'Channel'
                   OR RecordTypeId = null)
              AND IsClosed = false
            ORDER BY CloseDate
        ];
        Map<String, StageGroup> stageMap = new Map<String, StageGroup>();
        Decimal totalStdAmt = 0, totalStdWeighted = 0;
        for (Opportunity o : stdOpps) {
            StandardOppItem item = new StandardOppItem();
            item.oppId = o.Id;
            item.oppName = o.Name;
            item.stageName = o.StageName;
            item.amount = o.Amount;
            item.probability = o.Probability;
            item.closeDate = o.CloseDate;
            item.expectedRevenue = o.ExpectedRevenue;
            item.recordTypeName = o.RecordType != null ? o.RecordType.Name : '標準';
            item.fiscalYear = deriveFY(o.CloseDate);
            summary.standardPipeline.add(item);

            Decimal amt = o.Amount != null ? o.Amount : 0;
            Decimal exp = o.ExpectedRevenue != null ? o.ExpectedRevenue : 0;
            totalStdAmt += amt;
            totalStdWeighted += exp;

            if (!stageMap.containsKey(o.StageName)) {
                StageGroup sg = new StageGroup();
                sg.stageName = o.StageName;
                sg.count = 0;
                sg.totalAmount = 0;
                sg.totalWeighted = 0;
                stageMap.put(o.StageName, sg);
            }
            StageGroup sg = stageMap.get(o.StageName);
            sg.count++;
            sg.totalAmount += amt;
            sg.totalWeighted += exp;
        }
        summary.stageGroups = stageMap.values();
        summary.totalStdAmount = totalStdAmt;
        summary.totalStdWeighted = totalStdWeighted;

        return summary;
    }

    // ── Helpers ──
    private static String deriveFY(Date d) {
        if (d == null) return 'Unknown';
        Integer yr = d.month() >= 4 ? d.year() : d.year() - 1;
        return 'FY' + yr;
    }

    private static List<FYAmount> toFYAmountList(Map<String, Decimal[]> fyMap) {
        List<FYAmount> result = new List<FYAmount>();
        for (String fy : fyMap.keySet()) {
            FYAmount f = new FYAmount();
            f.fiscalYear = fy;
            Decimal[] v = fyMap.get(fy);
            f.planQty = v[0]; f.actualQty = v[1]; f.planAmt = v[2]; f.actualAmt = v[3];
            result.add(f);
        }
        return result;
    }

    private static List<FYAmountSimple> toFYAmountListSimple(Map<String, Decimal[]> fyMap) {
        List<FYAmountSimple> result = new List<FYAmountSimple>();
        for (String fy : fyMap.keySet()) {
            FYAmountSimple f = new FYAmountSimple();
            f.fiscalYear = fy;
            Decimal[] v = fyMap.get(fy);
            f.planAmt = v[0]; f.actualAmt = v[1];
            result.add(f);
        }
        return result;
    }

    // ── Inner Classes ──
    public class ForecastSummary {
        @AuraEnabled public List<AgreementSummary> agreements;
        @AuraEnabled public Decimal totalPlanAmt;
        @AuraEnabled public Decimal totalActualAmt;
        @AuraEnabled public List<PipelineItem> pipeline;
        @AuraEnabled public Decimal totalWeightedPipeline;
        @AuraEnabled public List<StandardOppItem> standardPipeline;
        @AuraEnabled public List<StageGroup> stageGroups;
        @AuraEnabled public Decimal totalStdAmount;
        @AuraEnabled public Decimal totalStdWeighted;
    }
    public class AgreementSummary {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public Date contractStart;
        @AuraEnabled public Date contractEnd;
        @AuraEnabled public List<AgreementProductSummary> products;
        @AuraEnabled public Decimal totalPlanAmt;
        @AuraEnabled public Decimal totalActualAmt;
        @AuraEnabled public Decimal achievementRate;
        @AuraEnabled public List<FYAmountSimple> fyAmounts;
    }
    public class AgreementProductSummary {
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal totalPlanQty;
        @AuraEnabled public Decimal totalActualQty;
        @AuraEnabled public Decimal totalPlanAmt;
        @AuraEnabled public Decimal totalActualAmt;
        @AuraEnabled public Decimal achievementRate;
        @AuraEnabled public List<FYAmount> fyAmounts;
    }
    public class FYAmount {
        @AuraEnabled public String fiscalYear;
        @AuraEnabled public Decimal planQty;
        @AuraEnabled public Decimal actualQty;
        @AuraEnabled public Decimal planAmt;
        @AuraEnabled public Decimal actualAmt;
    }
    public class FYAmountSimple {
        @AuraEnabled public String fiscalYear;
        @AuraEnabled public Decimal planAmt;
        @AuraEnabled public Decimal actualAmt;
    }
    public class PipelineItem {
        @AuraEnabled public String oppId;
        @AuraEnabled public String oppName;
        @AuraEnabled public String stageName;
        @AuraEnabled public Decimal probability;
        @AuraEnabled public List<ForecastItem> forecasts;
        @AuraEnabled public Decimal totalWeightedAmount;
    }
    public class ForecastItem {
        @AuraEnabled public String productName;
        @AuraEnabled public String fiscalYear;
        @AuraEnabled public String quarter;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Decimal weightedAmount;
    }
    public class StandardOppItem {
        @AuraEnabled public String oppId;
        @AuraEnabled public String oppName;
        @AuraEnabled public String stageName;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Decimal probability;
        @AuraEnabled public Date closeDate;
        @AuraEnabled public Decimal expectedRevenue;
        @AuraEnabled public String recordTypeName;
        @AuraEnabled public String fiscalYear;
    }
    public class StageGroup {
        @AuraEnabled public String stageName;
        @AuraEnabled public Integer count;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public Decimal totalWeighted;
    }
}
