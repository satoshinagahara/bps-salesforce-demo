public with sharing class CorrectiveActionProgressController {

    @AuraEnabled(cacheable=true)
    public static List<CAWrapper> getCorrectiveActionsForCase(Id caseId) {
        List<Corrective_Action__c> cas = [
            SELECT Id, Name, Title__c, Phase__c, Severity__c, Category__c,
                   Product__c, Product__r.Name,
                   BOM_Part__c, BOM_Part__r.Part_Name__c, BOM_Part__r.Part_Number__c,
                   Supplier__c, Supplier__r.Name,
                   Team_Lead__c, Team_Lead__r.Name,
                   Target_Close_Date__c, Actual_Close_Date__c,
                   Impact_Scope__c,
                   (SELECT Id, Name, Supplier__r.Name, Status__c,
                           Request_Date__c, Response_Due_Date__c, Response_Date__c
                    FROM Supplier_Investigations__r
                    ORDER BY Request_Date__c DESC)
            FROM Corrective_Action__c
            WHERE Case__c = :caseId
            ORDER BY CreatedDate DESC
        ];

        List<CAWrapper> result = new List<CAWrapper>();
        for (Corrective_Action__c ca : cas) {
            result.add(new CAWrapper(ca));
        }
        return result;
    }

    public class CAWrapper {
        @AuraEnabled public Corrective_Action__c record;
        @AuraEnabled public Integer phaseIndex;
        @AuraEnabled public Integer totalPhases;
        @AuraEnabled public Integer progressPercent;
        @AuraEnabled public String severityClass;
        @AuraEnabled public List<SIWrapper> investigations;

        public CAWrapper(Corrective_Action__c ca) {
            this.record = ca;
            this.totalPhases = 8;
            this.phaseIndex = getPhaseIndex(ca.Phase__c);
            this.progressPercent = (this.phaseIndex * 100) / this.totalPhases;
            this.severityClass = getSeverityClass(ca.Severity__c);
            this.investigations = new List<SIWrapper>();
            if (ca.Supplier_Investigations__r != null) {
                for (Supplier_Investigation__c si : ca.Supplier_Investigations__r) {
                    this.investigations.add(new SIWrapper(si));
                }
            }
        }

        private Integer getPhaseIndex(String phase) {
            if (phase == null) return 0;
            if (phase.startsWith('D1')) return 1;
            if (phase.startsWith('D2')) return 2;
            if (phase.startsWith('D3')) return 3;
            if (phase.startsWith('D4')) return 4;
            if (phase.startsWith('D5')) return 5;
            if (phase.startsWith('D6')) return 6;
            if (phase.startsWith('D7')) return 7;
            if (phase.startsWith('D8')) return 8;
            return 0;
        }

        private String getSeverityClass(String severity) {
            if (severity == '重大') return 'severity-critical';
            if (severity == '重要') return 'severity-major';
            if (severity == '軽微') return 'severity-minor';
            return '';
        }
    }

    public class SIWrapper {
        @AuraEnabled public Supplier_Investigation__c record;
        @AuraEnabled public String statusClass;
        @AuraEnabled public Boolean isOverdue;

        public SIWrapper(Supplier_Investigation__c si) {
            this.record = si;
            this.statusClass = getStatusClass(si.Status__c);
            this.isOverdue = si.Response_Due_Date__c != null
                && si.Response_Date__c == null
                && si.Response_Due_Date__c < Date.today()
                && si.Status__c != '完了' && si.Status__c != '回答済';
        }

        private String getStatusClass(String status) {
            if (status == '依頼中') return 'status-requested';
            if (status == '調査中') return 'status-investigating';
            if (status == '回答済') return 'status-responded';
            if (status == '対策実施中') return 'status-implementing';
            if (status == '完了') return 'status-completed';
            return '';
        }
    }
}
