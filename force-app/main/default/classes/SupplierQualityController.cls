public with sharing class SupplierQualityController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getSupplierQualityData(Id accountId) {
        Map<String, Object> result = new Map<String, Object>();

        // 1. 監査履歴
        List<Supplier_Audit__c> audits = [
            SELECT Id, Name, Audit_Type__c, Audit_Date__c, Auditor__c,
                   Result__c, Score__c, Findings_Count__c, Critical_Findings__c,
                   Findings_Summary__c, Corrective_Action_Due__c,
                   Corrective_Action_Status__c, Next_Audit_Date__c, Scope__c
            FROM Supplier_Audit__c
            WHERE Supplier__c = :accountId
            ORDER BY Audit_Date__c DESC
            LIMIT 20
        ];

        List<Map<String, Object>> auditList = new List<Map<String, Object>>();
        Date nextAuditDate = null;
        Integer totalAudits = audits.size();
        Integer passCount = 0;
        Decimal totalScore = 0;
        Integer scoredCount = 0;

        for (Supplier_Audit__c a : audits) {
            Map<String, Object> am = new Map<String, Object>();
            am.put('Id', a.Id);
            am.put('Name', a.Name);
            am.put('auditType', a.Audit_Type__c);
            am.put('auditDate', a.Audit_Date__c);
            am.put('auditor', a.Auditor__c);
            am.put('result', a.Result__c);
            am.put('score', a.Score__c);
            am.put('findingsCount', a.Findings_Count__c);
            am.put('criticalFindings', a.Critical_Findings__c);
            am.put('findingsSummary', a.Findings_Summary__c);
            am.put('correctiveActionDue', a.Corrective_Action_Due__c);
            am.put('correctiveActionStatus', a.Corrective_Action_Status__c);
            am.put('scope', a.Scope__c);
            auditList.add(am);

            if (a.Result__c == '合格') passCount++;
            if (a.Score__c != null) { totalScore += a.Score__c; scoredCount++; }
            if (a.Next_Audit_Date__c != null && (nextAuditDate == null || a.Next_Audit_Date__c > nextAuditDate)) {
                nextAuditDate = a.Next_Audit_Date__c;
            }
        }

        result.put('audits', auditList);
        result.put('totalAudits', totalAudits);
        result.put('passRate', totalAudits > 0 ? (Decimal.valueOf(passCount) / totalAudits * 100).setScale(0) : null);
        result.put('avgAuditScore', scoredCount > 0 ? (totalScore / scoredCount).setScale(0) : null);
        result.put('nextAuditDate', nextAuditDate);

        // 2. 認証情報
        List<Supplier_Certification__c> certs = [
            SELECT Id, Name, Certification_Type__c, Certification_Number__c,
                   Issuing_Body__c, Issue_Date__c, Expiry_Date__c, Status__c,
                   Scope__c, Last_Surveillance_Date__c, Next_Surveillance_Date__c
            FROM Supplier_Certification__c
            WHERE Supplier__c = :accountId
            ORDER BY Expiry_Date__c ASC
        ];

        List<Map<String, Object>> certList = new List<Map<String, Object>>();
        Integer activeCerts = 0;
        Integer expiringSoonCerts = 0;
        Integer expiredCerts = 0;

        for (Supplier_Certification__c c : certs) {
            Map<String, Object> cm = new Map<String, Object>();
            cm.put('Id', c.Id);
            cm.put('Name', c.Name);
            cm.put('certType', c.Certification_Type__c);
            cm.put('certNumber', c.Certification_Number__c);
            cm.put('issuingBody', c.Issuing_Body__c);
            cm.put('issueDate', c.Issue_Date__c);
            cm.put('expiryDate', c.Expiry_Date__c);
            cm.put('status', c.Status__c);
            cm.put('scope', c.Scope__c);
            cm.put('nextSurveillance', c.Next_Surveillance_Date__c);

            // 期限チェック
            if (c.Status__c == '有効' && c.Expiry_Date__c != null) {
                Integer daysToExpiry = Date.today().daysBetween(c.Expiry_Date__c);
                cm.put('daysToExpiry', daysToExpiry);
                if (daysToExpiry < 0) {
                    expiredCerts++;
                } else if (daysToExpiry <= 90) {
                    expiringSoonCerts++;
                }
                activeCerts++;
            } else if (c.Status__c == '期限切れ' || c.Status__c == '失効') {
                expiredCerts++;
            } else if (c.Status__c == '有効') {
                activeCerts++;
            }

            certList.add(cm);
        }

        result.put('certifications', certList);
        result.put('activeCerts', activeCerts);
        result.put('expiringSoonCerts', expiringSoonCerts);
        result.put('expiredCerts', expiredCerts);
        result.put('totalCerts', certs.size());

        return result;
    }
}
