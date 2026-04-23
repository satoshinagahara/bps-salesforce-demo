public with sharing class AssetLtvController {

    public class Breakdown {
        @AuraEnabled public Decimal initialSale;           // 納入価額（Asset.Price × Quantity）
        @AuraEnabled public Decimal realizedService;       // 実績マイルストーン金額合計
        @AuraEnabled public Decimal plannedService;        // 予定マイルストーン金額合計
        @AuraEnabled public Decimal alertOpportunity;      // Equipment_Alert の想定商談機会（新規のみ）
    }

    public class YearlyPoint {
        @AuraEnabled public Integer year;
        @AuraEnabled public Decimal cumulative;            // 累積売上
        @AuraEnabled public Boolean isFuture;
    }

    public class LtvView {
        @AuraEnabled public String assetId;
        @AuraEnabled public String assetName;
        @AuraEnabled public Decimal realizedLtv;
        @AuraEnabled public Decimal projectedLtv;
        @AuraEnabled public Decimal ltvMultiple;
        @AuraEnabled public String realizedLtvFormatted;
        @AuraEnabled public String projectedLtvFormatted;
        @AuraEnabled public Breakdown breakdown;
        @AuraEnabled public String initialSaleFormatted;
        @AuraEnabled public String realizedServiceFormatted;
        @AuraEnabled public String plannedServiceFormatted;
        @AuraEnabled public String alertOpportunityFormatted;
        @AuraEnabled public List<YearlyPoint> yearlySeries;
        @AuraEnabled public Integer paybackYears;          // 納入価額を回収する年数（null=未回収予測）
        @AuraEnabled public Decimal annualAvgService;      // 年平均サービス売上（実績ベース）
        @AuraEnabled public String annualAvgServiceFormatted;
        @AuraEnabled public NextEvent nextMajorEvent;
    }

    public class NextEvent {
        @AuraEnabled public String milestoneType;
        @AuraEnabled public Date scheduledDate;
        @AuraEnabled public Decimal plannedAmount;
        @AuraEnabled public String plannedAmountFormatted;
        @AuraEnabled public Integer daysFromToday;
    }

    @AuraEnabled(cacheable=true)
    public static LtvView getLtv(Id assetId) {
        Asset a = [
            SELECT Id, Name, Price, Quantity, InstallDate
            FROM Asset
            WHERE Id = :assetId
            LIMIT 1
        ];

        List<Asset_Milestone__c> milestones = [
            SELECT Id, Milestone_Type__c, Scheduled_Date__c, Completed_Date__c,
                   Status__c, Planned_Amount__c, Actual_Amount__c
            FROM Asset_Milestone__c
            WHERE Asset__c = :assetId
            ORDER BY Scheduled_Date__c ASC
        ];

        List<Equipment_Alert__c> alerts = [
            SELECT Id, Estimated_Opportunity__c, Status__c, Detected_At__c
            FROM Equipment_Alert__c
            WHERE Asset__c = :assetId
        ];

        Decimal initialSale = (a.Price != null ? a.Price : 0) * (a.Quantity != null ? a.Quantity : 1);

        Decimal realizedService = 0;
        Decimal plannedService = 0;
        for (Asset_Milestone__c m : milestones) {
            if (m.Status__c == '実施済' && m.Actual_Amount__c != null) {
                realizedService += m.Actual_Amount__c;
            } else if (m.Planned_Amount__c != null) {
                plannedService += m.Planned_Amount__c;
            }
        }

        Decimal alertOpportunity = 0;
        for (Equipment_Alert__c al : alerts) {
            if (al.Estimated_Opportunity__c != null && al.Status__c != '解決済') {
                alertOpportunity += al.Estimated_Opportunity__c;
            }
        }

        Decimal realizedLtv = initialSale + realizedService;
        Decimal projectedLtv = realizedLtv + plannedService + alertOpportunity;
        Decimal ltvMultiple = (initialSale > 0) ? (projectedLtv / initialSale).setScale(2) : 0;

        Breakdown bd = new Breakdown();
        bd.initialSale = initialSale;
        bd.realizedService = realizedService;
        bd.plannedService = plannedService;
        bd.alertOpportunity = alertOpportunity;

        LtvView v = new LtvView();
        v.assetId = a.Id;
        v.assetName = a.Name;
        v.realizedLtv = realizedLtv;
        v.projectedLtv = projectedLtv;
        v.ltvMultiple = ltvMultiple;
        v.breakdown = bd;
        v.realizedLtvFormatted = formatCurrency(realizedLtv);
        v.projectedLtvFormatted = formatCurrency(projectedLtv);
        v.initialSaleFormatted = formatCurrency(initialSale);
        v.realizedServiceFormatted = formatCurrency(realizedService);
        v.plannedServiceFormatted = formatCurrency(plannedService);
        v.alertOpportunityFormatted = formatCurrency(alertOpportunity);
        v.yearlySeries = buildYearlySeries(a, milestones, alerts);
        v.paybackYears = computePayback(a, milestones);
        v.annualAvgService = computeAnnualAvgService(a, realizedService);
        v.annualAvgServiceFormatted = formatCurrency(v.annualAvgService);
        v.nextMajorEvent = findNextMajorEvent(milestones);

        return v;
    }

    private static List<YearlyPoint> buildYearlySeries(Asset a, List<Asset_Milestone__c> ms, List<Equipment_Alert__c> alerts) {
        Date today = Date.today();
        Map<Integer, Decimal> byYear = new Map<Integer, Decimal>();

        Integer startYear = a.InstallDate != null ? a.InstallDate.year() : today.year();
        if (a.Price != null) {
            byYear.put(startYear, (byYear.containsKey(startYear) ? byYear.get(startYear) : 0) + a.Price * (a.Quantity != null ? a.Quantity : 1));
        }

        Integer endYear = startYear;
        for (Asset_Milestone__c m : ms) {
            if (m.Scheduled_Date__c == null) continue;
            Integer y = m.Scheduled_Date__c.year();
            Decimal amt = 0;
            if (m.Status__c == '実施済' && m.Actual_Amount__c != null) amt = m.Actual_Amount__c;
            else if (m.Planned_Amount__c != null) amt = m.Planned_Amount__c;
            if (amt > 0) {
                byYear.put(y, (byYear.containsKey(y) ? byYear.get(y) : 0) + amt);
                if (y > endYear) endYear = y;
            }
        }

        // Equipment_Alert の想定商談機会は今年に計上（発生年が不明なため近似）
        Decimal alertSum = 0;
        for (Equipment_Alert__c al : alerts) {
            if (al.Estimated_Opportunity__c != null && al.Status__c != '解決済') {
                alertSum += al.Estimated_Opportunity__c;
            }
        }
        if (alertSum > 0) {
            Integer y = today.year();
            byYear.put(y, (byYear.containsKey(y) ? byYear.get(y) : 0) + alertSum);
            if (y > endYear) endYear = y;
        }

        List<YearlyPoint> out = new List<YearlyPoint>();
        Decimal cum = 0;
        for (Integer y = startYear; y <= endYear; y++) {
            Decimal yrAdd = byYear.containsKey(y) ? byYear.get(y) : 0;
            cum += yrAdd;
            YearlyPoint p = new YearlyPoint();
            p.year = y;
            p.cumulative = cum;
            p.isFuture = (y > today.year());
            out.add(p);
        }
        return out;
    }

    private static Integer computePayback(Asset a, List<Asset_Milestone__c> ms) {
        if (a.Price == null || a.Price == 0 || a.InstallDate == null) return null;
        Decimal target = a.Price * (a.Quantity != null ? a.Quantity : 1);
        Decimal cum = target; // 納入時点で一括入金しているので回収済
        // ここでは「初期納入コスト回収」ではなく「初期納入価額の倍を超えた時点」を定義とする場合を想定するが、
        // 単発販売ビジネスなので納入時点で売上は計上済 → paybackYears は実質「投資回収」ではなく
        // 「保守売上で納入価額相当を追加で積めた年数」として扱う（倍率2.0達成までの年数）
        Decimal threshold = target; // 納入価額と同額の追加売上が積み上がる時期
        Decimal addCum = 0;
        Integer targetYear = null;
        for (Asset_Milestone__c m : ms) {
            if (m.Scheduled_Date__c == null) continue;
            Decimal amt = 0;
            if (m.Status__c == '実施済' && m.Actual_Amount__c != null) amt = m.Actual_Amount__c;
            else if (m.Planned_Amount__c != null) amt = m.Planned_Amount__c;
            addCum += amt;
            if (addCum >= threshold && targetYear == null) {
                targetYear = m.Scheduled_Date__c.year();
                break;
            }
        }
        if (targetYear == null) return null;
        return targetYear - a.InstallDate.year();
    }

    private static Decimal computeAnnualAvgService(Asset a, Decimal realizedService) {
        if (a.InstallDate == null) return 0;
        Integer elapsedYears = a.InstallDate.daysBetween(Date.today()) / 365;
        if (elapsedYears <= 0) elapsedYears = 1;
        return (realizedService / elapsedYears).setScale(0);
    }

    private static NextEvent findNextMajorEvent(List<Asset_Milestone__c> ms) {
        Date today = Date.today();
        NextEvent next;
        Decimal maxAmt = 0;
        for (Asset_Milestone__c m : ms) {
            if (m.Scheduled_Date__c == null) continue;
            if (m.Scheduled_Date__c < today) continue;
            if (m.Status__c == '実施済') continue;
            Decimal amt = m.Planned_Amount__c != null ? m.Planned_Amount__c : 0;
            if (amt > maxAmt) {
                maxAmt = amt;
                next = new NextEvent();
                next.milestoneType = m.Milestone_Type__c;
                next.scheduledDate = m.Scheduled_Date__c;
                next.plannedAmount = amt;
                next.plannedAmountFormatted = formatCurrency(amt);
                next.daysFromToday = today.daysBetween(m.Scheduled_Date__c);
            }
        }
        return next;
    }

    private static String formatCurrency(Decimal val) {
        if (val == null) return '¥0';
        if (val >= 100000000) return '¥' + (val / 100000000).setScale(2) + '億';
        if (val >= 10000) return '¥' + (val / 10000).setScale(0) + '万';
        return '¥' + val.setScale(0);
    }
}
