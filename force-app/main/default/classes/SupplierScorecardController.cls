public with sharing class SupplierScorecardController {

    public class Scorecard {
        @AuraEnabled public Integer overallScore;
        @AuraEnabled public Integer qualityScore;
        @AuraEnabled public Integer costScore;
        @AuraEnabled public Integer complianceScore;
        @AuraEnabled public String overallGrade;
        @AuraEnabled public String qualityGrade;
        @AuraEnabled public String costGrade;
        @AuraEnabled public String complianceGrade;
        @AuraEnabled public List<Alert> alerts;
        @AuraEnabled public List<Risk> risks;
        @AuraEnabled public List<Map<String, Object>> supplyParts;
        @AuraEnabled public List<Map<String, Object>> correctiveActions;
        @AuraEnabled public List<Map<String, Object>> rfqQuotes;
        @AuraEnabled public List<Map<String, Object>> audits;
        @AuraEnabled public List<Map<String, Object>> certifications;
        @AuraEnabled public List<Map<String, Object>> sites;
        @AuraEnabled public List<Map<String, Object>> tasks;
        @AuraEnabled public List<Map<String, Object>> events;
        @AuraEnabled public Map<String, Object> stats;
    }

    public class Alert {
        @AuraEnabled public String severity;
        @AuraEnabled public String message;
        public Alert(String severity, String message) {
            this.severity = severity;
            this.message = message;
        }
    }

    public class Risk {
        @AuraEnabled public String category;
        @AuraEnabled public String level;
        @AuraEnabled public String detail;
        public Risk(String category, String level, String detail) {
            this.category = category;
            this.level = level;
            this.detail = detail;
        }
    }

    @AuraEnabled(cacheable=true)
    public static Scorecard getScorecard(Id accountId) {
        Scorecard sc = new Scorecard();
        sc.alerts = new List<Alert>();
        sc.risks = new List<Risk>();
        sc.stats = new Map<String, Object>();

        // --- Query all related data ---
        List<Corrective_Action__c> cas = [
            SELECT Id, Name, Title__c, Phase__c, Severity__c, Category__c,
                   Product__r.Name, Case__r.CaseNumber, Target_Close_Date__c,
                   Actual_Close_Date__c, CreatedDate
            FROM Corrective_Action__c
            WHERE Supplier__c = :accountId
            ORDER BY CreatedDate DESC
        ];

        List<RFQ_Quote__c> quotes = [
            SELECT Id, Name, RFQ__r.Name, Unit_Price__c, Status__c, CreatedDate
            FROM RFQ_Quote__c
            WHERE Supplier__c = :accountId
            ORDER BY CreatedDate DESC
        ];

        List<Supplier_Audit__c> auditList = [
            SELECT Id, Name, Audit_Type__c, Audit_Date__c, Result__c
            FROM Supplier_Audit__c
            WHERE Supplier__c = :accountId
            ORDER BY Audit_Date__c DESC
        ];

        List<Supplier_Certification__c> certs = [
            SELECT Id, Name, Certification_Type__c, Status__c,
                   Issue_Date__c, Expiry_Date__c
            FROM Supplier_Certification__c
            WHERE Supplier__c = :accountId
            ORDER BY Expiry_Date__c DESC
        ];

        List<BOM_Part__c> parts = [
            SELECT Id, Name, Part_Name__c, Part_Number__c, Supplier__c,
                   Unit_Cost__c, Make_or_Buy__c,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Name,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name
            FROM BOM_Part__c
            WHERE Supplier__c = :accountId
            ORDER BY Part_Name__c
        ];

        List<Manufacturing_Site__c> siteList = [
            SELECT Id, Name, Is_Own_Site__c
            FROM Manufacturing_Site__c
            WHERE Supplier__c = :accountId
        ];

        List<Task> taskList = [
            SELECT Id, Subject, Status, Priority, ActivityDate, Owner.Name
            FROM Task
            WHERE AccountId = :accountId
            ORDER BY ActivityDate DESC
            LIMIT 10
        ];

        List<Event> eventList = [
            SELECT Id, Subject, StartDateTime, EndDateTime, Owner.Name
            FROM Event
            WHERE AccountId = :accountId
            ORDER BY StartDateTime DESC
            LIMIT 10
        ];

        // --- Calculate Scores ---
        sc.qualityScore = calcQualityScore(cas, auditList);
        sc.costScore = calcCostScore(quotes);
        sc.complianceScore = calcComplianceScore(certs, auditList);
        sc.overallScore = (sc.qualityScore * 40 + sc.costScore * 20 + sc.complianceScore * 40) / 100;

        sc.overallGrade = toGrade(sc.overallScore);
        sc.qualityGrade = toGrade(sc.qualityScore);
        sc.costGrade = toGrade(sc.costScore);
        sc.complianceGrade = toGrade(sc.complianceScore);

        // --- Generate Alerts ---
        for (Corrective_Action__c ca : cas) {
            if (ca.Severity__c == '重大' && ca.Phase__c != 'D8 完了') {
                sc.alerts.add(new Alert('error', '重大CA進行中: ' + ca.Name + ' (' + ca.Phase__c + ')'));
            }
        }
        for (Supplier_Certification__c c : certs) {
            if (c.Status__c == '期限切れ') {
                sc.alerts.add(new Alert('error', c.Certification_Type__c + ' 認証が期限切れ (' + formatDate(c.Expiry_Date__c) + ')'));
            } else if (c.Expiry_Date__c != null && c.Expiry_Date__c <= Date.today().addMonths(2)) {
                sc.alerts.add(new Alert('warning', c.Certification_Type__c + ' 認証の期限が迫っています (' + formatDate(c.Expiry_Date__c) + ')'));
            }
        }
        if (auditList.isEmpty()) {
            sc.alerts.add(new Alert('warning', '監査実績がありません'));
        } else if (auditList[0].Audit_Date__c < Date.today().addMonths(-12)) {
            sc.alerts.add(new Alert('warning', '直近の監査から1年以上経過 (' + formatDate(auditList[0].Audit_Date__c) + ')'));
        }

        // --- Assess Risks ---
        // Quality risk
        Integer openSevereCAs = 0;
        for (Corrective_Action__c ca : cas) {
            if (ca.Phase__c != 'D8 完了' && (ca.Severity__c == '重大' || ca.Severity__c == '重要')) {
                openSevereCAs++;
            }
        }
        if (openSevereCAs > 0) {
            sc.risks.add(new Risk('品質リスク', 'high', '重大/重要CA ' + openSevereCAs + '件が進行中'));
        } else if (!cas.isEmpty()) {
            sc.risks.add(new Risk('品質リスク', 'low', '全CAが完了済み'));
        } else {
            sc.risks.add(new Risk('品質リスク', 'low', 'CA発生なし'));
        }

        // Compliance risk
        Integer expiredCerts = 0;
        Integer expiringCerts = 0;
        for (Supplier_Certification__c c : certs) {
            if (c.Status__c == '期限切れ') expiredCerts++;
            else if (c.Expiry_Date__c != null && c.Expiry_Date__c <= Date.today().addMonths(2)) expiringCerts++;
        }
        if (expiredCerts > 0) {
            sc.risks.add(new Risk('認証リスク', 'high', '期限切れ認証 ' + expiredCerts + '件'));
        } else if (expiringCerts > 0) {
            sc.risks.add(new Risk('認証リスク', 'medium', '期限間近の認証 ' + expiringCerts + '件'));
        } else {
            sc.risks.add(new Risk('認証リスク', 'low', '全認証有効'));
        }

        // Supply concentration risk
        Set<String> productNames = new Set<String>();
        for (BOM_Part__c p : parts) {
            if (p.BOM_SubComponent__r?.BOM_Line__r?.BOM_Header__r?.Product__r?.Name != null) {
                productNames.add(p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name);
            }
        }
        // Check if any parts are single-sourced
        Set<String> partNumbers = new Set<String>();
        for (BOM_Part__c p : parts) {
            if (p.Part_Number__c != null) partNumbers.add(p.Part_Number__c);
        }
        Integer singleSourceCount = 0;
        if (!partNumbers.isEmpty()) {
            Map<String, Integer> supplierCountByPart = new Map<String, Integer>();
            for (AggregateResult ar : [
                SELECT Part_Number__c pn, COUNT_DISTINCT(Supplier__c) cnt
                FROM BOM_Part__c
                WHERE Part_Number__c IN :partNumbers
                GROUP BY Part_Number__c
            ]) {
                supplierCountByPart.put((String)ar.get('pn'), (Integer)ar.get('cnt'));
            }
            for (String pn : partNumbers) {
                Integer cnt = supplierCountByPart.get(pn);
                if (cnt != null && cnt == 1) singleSourceCount++;
            }
        }
        if (singleSourceCount > 0) {
            sc.risks.add(new Risk('集中リスク', 'medium', '単一ソース部品 ' + singleSourceCount + '件'));
        } else if (!parts.isEmpty()) {
            sc.risks.add(new Risk('集中リスク', 'low', '全部品に代替サプライヤーあり'));
        }

        // Geographic risk
        if (siteList.size() <= 1) {
            sc.risks.add(new Risk('供給リスク', 'medium', '製造拠点が' + siteList.size() + '拠点のみ'));
        } else {
            sc.risks.add(new Risk('供給リスク', 'low', siteList.size() + '拠点体制'));
        }

        // --- Build tab data ---
        // Supply parts
        sc.supplyParts = new List<Map<String, Object>>();
        for (BOM_Part__c p : parts) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('id', p.Id);
            m.put('partName', p.Part_Name__c);
            m.put('partNumber', p.Part_Number__c);
            String prodName = '';
            String bomName = '';
            if (p.BOM_SubComponent__r?.BOM_Line__r?.BOM_Header__r != null) {
                bomName = p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Name;
                if (p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r != null) {
                    prodName = p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name;
                }
            }
            m.put('productName', prodName);
            m.put('bomName', bomName);
            m.put('unitCost', p.Unit_Cost__c);
            Integer supplierCount = 0;
            if (p.Part_Number__c != null) {
                List<AggregateResult> ars = [
                    SELECT COUNT_DISTINCT(Supplier__c) cnt
                    FROM BOM_Part__c
                    WHERE Part_Number__c = :p.Part_Number__c
                ];
                if (!ars.isEmpty()) supplierCount = (Integer)ars[0].get('cnt');
            }
            m.put('supplierCount', supplierCount);
            m.put('isSingleSource', supplierCount <= 1);
            sc.supplyParts.add(m);
        }

        // Corrective Actions
        sc.correctiveActions = new List<Map<String, Object>>();
        for (Corrective_Action__c ca : cas) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('id', ca.Id);
            m.put('name', ca.Name);
            m.put('title', ca.Title__c);
            m.put('phase', ca.Phase__c);
            m.put('severity', ca.Severity__c);
            m.put('category', ca.Category__c);
            m.put('productName', ca.Product__r?.Name);
            m.put('caseNumber', ca.Case__r?.CaseNumber);
            m.put('isOpen', ca.Phase__c != 'D8 完了');
            sc.correctiveActions.add(m);
        }

        // RFQ Quotes
        sc.rfqQuotes = new List<Map<String, Object>>();
        for (RFQ_Quote__c q : quotes) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('id', q.Id);
            m.put('name', q.Name);
            m.put('rfqName', q.RFQ__r?.Name);
            m.put('unitPrice', q.Unit_Price__c);
            m.put('status', q.Status__c);
            sc.rfqQuotes.add(m);
        }

        // Audits
        sc.audits = new List<Map<String, Object>>();
        for (Supplier_Audit__c a : auditList) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('id', a.Id);
            m.put('name', a.Name);
            m.put('auditType', a.Audit_Type__c);
            m.put('auditDate', a.Audit_Date__c);
            m.put('result', a.Result__c);
            sc.audits.add(m);
        }

        // Certifications
        sc.certifications = new List<Map<String, Object>>();
        for (Supplier_Certification__c c : certs) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('id', c.Id);
            m.put('name', c.Name);
            m.put('certType', c.Certification_Type__c);
            m.put('status', c.Status__c);
            m.put('issueDate', c.Issue_Date__c);
            m.put('expiryDate', c.Expiry_Date__c);
            m.put('isExpired', c.Status__c == '期限切れ');
            m.put('isExpiring', c.Status__c != '期限切れ' && c.Expiry_Date__c != null && c.Expiry_Date__c <= Date.today().addMonths(2));
            sc.certifications.add(m);
        }

        // Sites
        sc.sites = new List<Map<String, Object>>();
        for (Manufacturing_Site__c s : siteList) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('id', s.Id);
            m.put('name', s.Name);
            sc.sites.add(m);
        }

        // Tasks
        sc.tasks = new List<Map<String, Object>>();
        for (Task t : taskList) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('id', t.Id);
            m.put('subject', t.Subject);
            m.put('status', t.Status);
            m.put('priority', t.Priority);
            m.put('activityDate', t.ActivityDate);
            m.put('ownerName', t.Owner.Name);
            sc.tasks.add(m);
        }

        // Events
        sc.events = new List<Map<String, Object>>();
        for (Event e : eventList) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('id', e.Id);
            m.put('subject', e.Subject);
            m.put('startDateTime', e.StartDateTime);
            m.put('endDateTime', e.EndDateTime);
            m.put('ownerName', e.Owner.Name);
            sc.events.add(m);
        }

        // Stats summary
        Integer openCAs = 0;
        for (Corrective_Action__c ca : cas) {
            if (ca.Phase__c != 'D8 完了') openCAs++;
        }
        Integer adoptedQuotes = 0;
        for (RFQ_Quote__c q : quotes) {
            if (q.Status__c == '採用') adoptedQuotes++;
        }
        Integer validCerts = 0;
        for (Supplier_Certification__c c : certs) {
            if (c.Status__c == '有効') validCerts++;
        }
        sc.stats.put('totalCAs', cas.size());
        sc.stats.put('openCAs', openCAs);
        sc.stats.put('totalQuotes', quotes.size());
        sc.stats.put('adoptedQuotes', adoptedQuotes);
        sc.stats.put('totalAudits', auditList.size());
        sc.stats.put('totalCerts', certs.size());
        sc.stats.put('validCerts', validCerts);
        sc.stats.put('expiredCerts', expiredCerts);
        sc.stats.put('totalParts', parts.size());
        sc.stats.put('singleSourceParts', singleSourceCount);
        sc.stats.put('totalSites', siteList.size());
        sc.stats.put('productCount', productNames.size());

        return sc;
    }

    private static Integer calcQualityScore(List<Corrective_Action__c> cas, List<Supplier_Audit__c> audits) {
        Integer score = 80;
        for (Corrective_Action__c ca : cas) {
            if (ca.Phase__c == 'D8 完了') {
                score += 2;
            } else {
                if (ca.Severity__c == '重大') score -= 20;
                else if (ca.Severity__c == '重要') score -= 10;
                else score -= 5;
            }
        }
        if (!audits.isEmpty()) {
            String latestResult = audits[0].Result__c;
            if (latestResult == '合格') score += 10;
            else if (latestResult == '条件付合格') score += 0;
            else if (latestResult == '不合格') score -= 15;
        } else {
            score -= 5;
        }
        return Math.max(0, Math.min(100, score));
    }

    private static Integer calcCostScore(List<RFQ_Quote__c> quotes) {
        if (quotes.isEmpty()) return 70;
        Integer total = quotes.size();
        Integer adopted = 0;
        for (RFQ_Quote__c q : quotes) {
            if (q.Status__c == '採用') adopted++;
        }
        Decimal rate = (Decimal)adopted / total * 100;
        Integer score = 50 + (Integer)(rate * 0.5);
        return Math.max(0, Math.min(100, score));
    }

    private static Integer calcComplianceScore(List<Supplier_Certification__c> certs, List<Supplier_Audit__c> audits) {
        Integer score = 40;
        for (Supplier_Certification__c c : certs) {
            if (c.Status__c == '有効') score += 12;
            else if (c.Status__c == '期限切れ') score -= 15;
        }
        for (Supplier_Audit__c a : audits) {
            if (a.Result__c == '合格') score += 8;
            else if (a.Result__c == '条件付合格') score += 3;
            else if (a.Result__c == '不合格') score -= 10;
        }
        return Math.max(0, Math.min(100, score));
    }

    private static String toGrade(Integer score) {
        if (score >= 90) return 'A';
        if (score >= 80) return 'B+';
        if (score >= 70) return 'B';
        if (score >= 60) return 'C+';
        if (score >= 50) return 'C';
        return 'D';
    }

    private static String formatDate(Date d) {
        if (d == null) return '';
        return d.year() + '/' + String.valueOf(d.month()).leftPad(2, '0') + '/' + String.valueOf(d.day()).leftPad(2, '0');
    }
}
