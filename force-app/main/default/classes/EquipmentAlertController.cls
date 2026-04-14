public with sharing class EquipmentAlertController {

    public class AlertView {
        @AuraEnabled public String alertId;
        @AuraEnabled public String alertNumber;
        @AuraEnabled public String sensorType;
        @AuraEnabled public Decimal detectedValue;
        @AuraEnabled public Decimal threshold;
        @AuraEnabled public String severity;
        @AuraEnabled public String severityClass;
        @AuraEnabled public DateTime detectedAt;
        @AuraEnabled public String anomalyDescription;
        @AuraEnabled public String recommendedAction;
        @AuraEnabled public Decimal estimatedOpportunity;
        @AuraEnabled public String estimatedOpportunityFormatted;
        @AuraEnabled public String processedBy;
        @AuraEnabled public String status;
        @AuraEnabled public String gcpRequestId;
    }

    public class AssetContext {
        @AuraEnabled public String assetId;
        @AuraEnabled public String assetName;
        @AuraEnabled public String productName;
        @AuraEnabled public String accountName;
        @AuraEnabled public Date installDate;
        @AuraEnabled public String status;
        @AuraEnabled public List<AlertView> alerts;
    }

    @AuraEnabled(cacheable=true)
    public static AssetContext getAssetWithAlerts(Id assetId) {
        Asset a = [
            SELECT Id, Name, Product2.Name, Account.Name, InstallDate, Status
            FROM Asset
            WHERE Id = :assetId
            LIMIT 1
        ];

        List<Equipment_Alert__c> alerts = [
            SELECT Id, Name, Sensor_Type__c, Detected_Value__c, Threshold__c,
                   Severity__c, Detected_At__c, Anomaly_Description__c,
                   Recommended_Action__c, Estimated_Opportunity__c,
                   ProcessedBy__c, Status__c, GcpRequestId__c
            FROM Equipment_Alert__c
            WHERE Asset__c = :assetId
            ORDER BY Detected_At__c DESC NULLS LAST, CreatedDate DESC
            LIMIT 10
        ];

        AssetContext ctx = new AssetContext();
        ctx.assetId = a.Id;
        ctx.assetName = a.Name;
        ctx.productName = a.Product2 != null ? a.Product2.Name : '';
        ctx.accountName = a.Account != null ? a.Account.Name : '';
        ctx.installDate = a.InstallDate;
        ctx.status = a.Status;

        ctx.alerts = new List<AlertView>();
        for (Equipment_Alert__c r : alerts) {
            AlertView v = new AlertView();
            v.alertId = r.Id;
            v.alertNumber = r.Name;
            v.sensorType = r.Sensor_Type__c;
            v.detectedValue = r.Detected_Value__c;
            v.threshold = r.Threshold__c;
            v.severity = r.Severity__c;
            v.severityClass = severityClassOf(r.Severity__c);
            v.detectedAt = r.Detected_At__c;
            v.anomalyDescription = r.Anomaly_Description__c;
            v.recommendedAction = r.Recommended_Action__c;
            v.estimatedOpportunity = r.Estimated_Opportunity__c;
            v.estimatedOpportunityFormatted = formatCurrency(r.Estimated_Opportunity__c);
            v.processedBy = r.ProcessedBy__c;
            v.status = r.Status__c;
            v.gcpRequestId = r.GcpRequestId__c;
            ctx.alerts.add(v);
        }
        return ctx;
    }

    private static String severityClassOf(String sev) {
        if (sev == '高') return 'severity-high';
        if (sev == '中') return 'severity-medium';
        return 'severity-low';
    }

    private static String formatCurrency(Decimal val) {
        if (val == null) return '';
        if (val >= 100000000) return '¥' + (val / 100000000).setScale(1) + '億';
        if (val >= 10000) return '¥' + (val / 10000).setScale(0) + '万';
        return '¥' + val.setScale(0);
    }
}
