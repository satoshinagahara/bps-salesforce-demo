public with sharing class SalesDemandDashboardController {

    @AuraEnabled(cacheable=true)
    public static DashboardData getDashboardData() {
        DashboardData result = new DashboardData();

        // ── 1. Sales Agreements (確定収益) ──
        Map<String, Decimal> saFYMap = new Map<String, Decimal>();
        Map<String, Decimal[]> saProductMap = new Map<String, Decimal[]>(); // [qty, amt]
        Decimal totalConfirmed = 0;

        List<Sales_Agreement__c> agreements = [
            SELECT Id,
                (SELECT Product__r.Name, Product__r.Family,
                    (SELECT Schedule_Month__c, Plan_Quantity__c, Plan_Amount__c
                     FROM Schedules__r)
                 FROM Agreement_Products__r)
            FROM Sales_Agreement__c
            WHERE Status__c IN ('有効', '更新交渉中')
        ];
        for (Sales_Agreement__c sa : agreements) {
            for (Sales_Agreement_Product__c sap : sa.Agreement_Products__r) {
                String pName = sap.Product__r.Name;
                String pFamily = sap.Product__r.Family;
                String pKey = pName + '|||' + (pFamily != null ? pFamily : '');
                if (!saProductMap.containsKey(pKey)) saProductMap.put(pKey, new Decimal[]{0, 0});

                for (Sales_Agreement_Schedule__c s : sap.Schedules__r) {
                    Decimal planAmt = s.Plan_Amount__c != null ? s.Plan_Amount__c : 0;
                    Decimal planQty = s.Plan_Quantity__c != null ? s.Plan_Quantity__c : 0;
                    totalConfirmed += planAmt;

                    String fy = deriveFY(s.Schedule_Month__c);
                    saFYMap.put(fy, (saFYMap.containsKey(fy) ? saFYMap.get(fy) : 0) + planAmt);

                    Decimal[] pv = saProductMap.get(pKey);
                    pv[0] += planQty;
                    pv[1] += planAmt;
                }
            }
        }
        result.confirmedRevenue = totalConfirmed;

        // ── 2. Design Win Opportunities + Revenue Forecasts ──
        Map<String, Decimal> dwFYMap = new Map<String, Decimal>();
        Map<String, Decimal[]> dwProductMap = new Map<String, Decimal[]>(); // [qty, amt]
        Decimal totalDWWeighted = 0;
        List<StageData> dwStageList = new List<StageData>();
        Map<String, StageData> dwStageMap = new Map<String, StageData>();

        List<Opportunity> dwOpps = [
            SELECT Id, Name, StageName, Probability,
                (SELECT Product__r.Name, Product__r.Family, Fiscal_Year__c,
                        Forecast_Quantity__c, Forecast_Amount__c,
                        Weighted_Amount__c, Status__c
                 FROM Revenue_Forecasts__r
                 WHERE Status__c = '予測中')
            FROM Opportunity
            WHERE RecordType.DeveloperName = 'Design_Win'
              AND IsClosed = false
        ];

        for (Opportunity o : dwOpps) {
            // Stage aggregation
            String stage = o.StageName;
            if (!dwStageMap.containsKey(stage)) {
                StageData sd = new StageData();
                sd.stageName = stage;
                sd.stageLabel = dwStageLabel(stage);
                sd.count = 0;
                sd.totalAmount = 0;
                sd.totalWeighted = 0;
                dwStageMap.put(stage, sd);
            }
            StageData sd = dwStageMap.get(stage);
            sd.count++;

            Decimal oppWeighted = 0;
            Decimal oppAmount = 0;
            for (Revenue_Forecast__c rf : o.Revenue_Forecasts__r) {
                Decimal wa = rf.Weighted_Amount__c != null ? rf.Weighted_Amount__c : 0;
                Decimal fa = rf.Forecast_Amount__c != null ? rf.Forecast_Amount__c : 0;
                Decimal fq = rf.Forecast_Quantity__c != null ? rf.Forecast_Quantity__c : 0;
                oppWeighted += wa;
                oppAmount += fa;
                totalDWWeighted += wa;

                String fy = rf.Fiscal_Year__c;
                dwFYMap.put(fy, (dwFYMap.containsKey(fy) ? dwFYMap.get(fy) : 0) + wa);

                String pName = rf.Product__r.Name;
                String pFamily = rf.Product__r.Family;
                String pKey = pName + '|||' + (pFamily != null ? pFamily : '');
                if (!dwProductMap.containsKey(pKey)) dwProductMap.put(pKey, new Decimal[]{0, 0});
                Decimal[] pv = dwProductMap.get(pKey);
                pv[0] += fq;
                pv[1] += fa;
            }
            sd.totalAmount += oppAmount;
            sd.totalWeighted += oppWeighted;
        }
        result.dwPipelineWeighted = totalDWWeighted;

        // DW stages in order
        String[] dwOrder = new String[]{'DW_Inquiry','DW_Proposal','DW_Prototype','DW_Qualification','DW_FinalNegotiation'};
        result.dwStages = new List<StageData>();
        for (String s : dwOrder) {
            if (dwStageMap.containsKey(s)) result.dwStages.add(dwStageMap.get(s));
        }

        // ── 3. Standard Opportunities ──
        Map<String, Decimal> stdFYMap = new Map<String, Decimal>();
        Decimal totalStdWeighted = 0;
        Decimal closeThisMonth = 0;
        Map<String, StageData> stdStageMap = new Map<String, StageData>();

        Date monthStart = Date.today().toStartOfMonth();
        Date monthEnd = monthStart.addMonths(1).addDays(-1);

        List<Opportunity> stdOpps = [
            SELECT Id, Name, StageName, convertCurrency(Amount) ConvertedAmount,
                   Probability, CloseDate, convertCurrency(ExpectedRevenue) ConvertedExpected
            FROM Opportunity
            WHERE (RecordType.DeveloperName = 'SimpleOpportunity'
                   OR RecordType.DeveloperName = 'Channel'
                   OR RecordTypeId = null)
              AND IsClosed = false
        ];

        for (Opportunity o : stdOpps) {
            Decimal amt = (Decimal) o.get('ConvertedAmount');
            amt = amt != null ? amt : 0;
            Decimal exp = (Decimal) o.get('ConvertedExpected');
            exp = exp != null ? exp : 0;
            totalStdWeighted += exp;

            if (o.CloseDate != null && o.CloseDate >= monthStart && o.CloseDate <= monthEnd) {
                closeThisMonth += amt;
            }

            String fy = deriveFY(o.CloseDate);
            stdFYMap.put(fy, (stdFYMap.containsKey(fy) ? stdFYMap.get(fy) : 0) + exp);

            String stage = o.StageName;
            if (!stdStageMap.containsKey(stage)) {
                StageData ssd = new StageData();
                ssd.stageName = stage;
                ssd.stageLabel = stage;
                ssd.count = 0;
                ssd.totalAmount = 0;
                ssd.totalWeighted = 0;
                stdStageMap.put(stage, ssd);
            }
            StageData ssd = stdStageMap.get(stage);
            ssd.count++;
            ssd.totalAmount += amt;
            ssd.totalWeighted += exp;
        }
        result.stdPipelineWeighted = totalStdWeighted;
        result.closeThisMonth = closeThisMonth;
        result.stdStages = stdStageMap.values();

        // ── 4. Build FY Revenue list (FY2025-FY2030) ──
        result.fyRevenues = new List<FYRevenue>();
        for (Integer y = 2025; y <= 2030; y++) {
            String fy = 'FY' + y;
            FYRevenue fyr = new FYRevenue();
            fyr.fiscalYear = fy;
            fyr.confirmedAmount = saFYMap.containsKey(fy) ? saFYMap.get(fy) : 0;
            fyr.dwWeightedAmount = dwFYMap.containsKey(fy) ? dwFYMap.get(fy) : 0;
            fyr.stdWeightedAmount = stdFYMap.containsKey(fy) ? stdFYMap.get(fy) : 0;
            fyr.totalAmount = fyr.confirmedAmount + fyr.dwWeightedAmount + fyr.stdWeightedAmount;
            result.fyRevenues.add(fyr);
        }

        // ── 5. Build Product Demand list ──
        Map<String, ProductDemand> pdMap = new Map<String, ProductDemand>();
        for (String pKey : saProductMap.keySet()) {
            String[] parts = pKey.split('\\|\\|\\|');
            ProductDemand pd = new ProductDemand();
            pd.productName = parts[0];
            pd.productFamily = parts.size() > 1 ? parts[1] : '';
            Decimal[] pv = saProductMap.get(pKey);
            pd.saQuantity = pv[0];
            pd.saAmount = pv[1];
            pd.dwQuantity = 0;
            pd.dwAmount = 0;
            pdMap.put(pKey, pd);
        }
        for (String pKey : dwProductMap.keySet()) {
            String[] parts = pKey.split('\\|\\|\\|');
            Decimal[] pv = dwProductMap.get(pKey);
            if (pdMap.containsKey(pKey)) {
                ProductDemand pd = pdMap.get(pKey);
                pd.dwQuantity = pv[0];
                pd.dwAmount = pv[1];
            } else {
                ProductDemand pd = new ProductDemand();
                pd.productName = parts[0];
                pd.productFamily = parts.size() > 1 ? parts[1] : '';
                pd.saQuantity = 0;
                pd.saAmount = 0;
                pd.dwQuantity = pv[0];
                pd.dwAmount = pv[1];
                pdMap.put(pKey, pd);
            }
        }
        result.productDemands = pdMap.values();

        return result;
    }

    // ── Helpers ──
    private static String deriveFY(Date d) {
        if (d == null) return 'Unknown';
        Integer yr = d.month() >= 4 ? d.year() : d.year() - 1;
        return 'FY' + yr;
    }

    private static String dwStageLabel(String stage) {
        Map<String, String> m = new Map<String, String>{
            'DW_Inquiry' => '引合い', 'DW_Proposal' => '提案',
            'DW_Prototype' => '試作・評価', 'DW_Qualification' => '品質認定',
            'DW_FinalNegotiation' => '最終交渉'
        };
        return m.containsKey(stage) ? m.get(stage) : stage;
    }

    // ── Inner Classes ──
    public class DashboardData {
        @AuraEnabled public Decimal confirmedRevenue;
        @AuraEnabled public Decimal dwPipelineWeighted;
        @AuraEnabled public Decimal stdPipelineWeighted;
        @AuraEnabled public Decimal closeThisMonth;
        @AuraEnabled public List<FYRevenue> fyRevenues;
        @AuraEnabled public List<StageData> dwStages;
        @AuraEnabled public List<StageData> stdStages;
        @AuraEnabled public List<ProductDemand> productDemands;
    }

    public class FYRevenue {
        @AuraEnabled public String fiscalYear;
        @AuraEnabled public Decimal confirmedAmount;
        @AuraEnabled public Decimal dwWeightedAmount;
        @AuraEnabled public Decimal stdWeightedAmount;
        @AuraEnabled public Decimal totalAmount;
    }

    public class StageData {
        @AuraEnabled public String stageName;
        @AuraEnabled public String stageLabel;
        @AuraEnabled public Integer count;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public Decimal totalWeighted;
    }

    public class ProductDemand {
        @AuraEnabled public String productName;
        @AuraEnabled public String productFamily;
        @AuraEnabled public Decimal saQuantity;
        @AuraEnabled public Decimal saAmount;
        @AuraEnabled public Decimal dwQuantity;
        @AuraEnabled public Decimal dwAmount;
    }
}
