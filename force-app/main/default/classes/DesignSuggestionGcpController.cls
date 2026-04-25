public with sharing class DesignSuggestionGcpController {
    private static final String GCP_ENDPOINT = 'https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net/generate-design-suggestion';

    public class InitiativePreview {
        @AuraEnabled public String initiativeId;
        @AuraEnabled public String title;
        @AuraEnabled public String whyRationale;
        @AuraEnabled public String whatDescription;
        @AuraEnabled public String targetCustomer;
        @AuraEnabled public String productName;
        @AuraEnabled public List<NeedSummary> linkedNeeds;
    }

    public class NeedSummary {
        @AuraEnabled public String needsCardId;
        @AuraEnabled public String title;
        @AuraEnabled public String customerVoice;
        @AuraEnabled public String description;
        @AuraEnabled public String accountName;
    }

    public class DesignSuggestionResult {
        @AuraEnabled public String designSuggestionId;
        @AuraEnabled public String targetProduct;
        @AuraEnabled public String targetComponent;
        @AuraEnabled public String suggestionText;
        @AuraEnabled public String referenceSpec;
        @AuraEnabled public String referenceDiagram;
        @AuraEnabled public String priority;
        @AuraEnabled public String processedBy;
        @AuraEnabled public String generatedAt;
        @AuraEnabled public String gcpRequestId;
        @AuraEnabled public String specUrl;
        @AuraEnabled public String diagramUrl;
        @AuraEnabled public Integer iterations;
        @AuraEnabled public List<ToolHistoryEntry> toolHistory;
    }

    public class ToolHistoryEntry {
        @AuraEnabled public String tool;
        @AuraEnabled public String args;
        @AuraEnabled public String resultSummary;
        @AuraEnabled public Decimal elapsedSec;
    }

    @AuraEnabled(cacheable=true)
    public static DesignSuggestionResult getLatestSuggestion(Id initiativeId) {
        List<DesignSuggestion__c> records = [
            SELECT Id, SuggestionText__c, TargetProduct__c, TargetComponent__c,
                   Priority__c, ReferenceSpec__c, ReferenceDiagram__c,
                   SpecUrl__c, DiagramUrl__c, GeneratedAt__c, GcpRequestId__c, ProcessedBy__c
            FROM DesignSuggestion__c
            WHERE Initiative__c = :initiativeId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (records.isEmpty()) {
            return null;
        }
        DesignSuggestion__c r = records[0];
        DesignSuggestionResult result = new DesignSuggestionResult();
        result.designSuggestionId = r.Id;
        result.suggestionText = r.SuggestionText__c;
        result.targetProduct = r.TargetProduct__c;
        result.targetComponent = r.TargetComponent__c;
        result.priority = r.Priority__c;
        result.referenceSpec = r.ReferenceSpec__c;
        result.referenceDiagram = r.ReferenceDiagram__c;
        result.specUrl = r.SpecUrl__c;
        result.diagramUrl = r.DiagramUrl__c;
        result.generatedAt = r.GeneratedAt__c != null ? r.GeneratedAt__c.format('yyyy-MM-dd HH:mm') : null;
        result.gcpRequestId = r.GcpRequestId__c;
        result.processedBy = r.ProcessedBy__c;
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static InitiativePreview getPreviewData(Id initiativeId) {
        Product_Initiative__c pi = [
            SELECT Id, Title__c, Why_Rationale__c, What_Description__c,
                   Target_Customer__c, Product__r.Name
            FROM Product_Initiative__c
            WHERE Id = :initiativeId
            LIMIT 1
        ];

        List<Initiative_Need__c> links = [
            SELECT Needs_Card__c, Needs_Card__r.Title__c,
                   Needs_Card__r.Customer_Voice__c, Needs_Card__r.Description__c,
                   Needs_Card__r.Account__r.Name
            FROM Initiative_Need__c
            WHERE Initiative__c = :initiativeId
            ORDER BY CreatedDate DESC
            LIMIT 10
        ];

        InitiativePreview preview = new InitiativePreview();
        preview.initiativeId = pi.Id;
        preview.title = pi.Title__c;
        preview.whyRationale = pi.Why_Rationale__c;
        preview.whatDescription = pi.What_Description__c;
        preview.targetCustomer = pi.Target_Customer__c;
        preview.productName = pi.Product__r != null ? pi.Product__r.Name : '';

        preview.linkedNeeds = new List<NeedSummary>();
        for (Initiative_Need__c link : links) {
            NeedSummary ns = new NeedSummary();
            ns.needsCardId = link.Needs_Card__c;
            ns.title = link.Needs_Card__r.Title__c;
            ns.customerVoice = link.Needs_Card__r.Customer_Voice__c;
            ns.description = link.Needs_Card__r.Description__c;
            ns.accountName = link.Needs_Card__r.Account__r != null ? link.Needs_Card__r.Account__r.Name : '';
            preview.linkedNeeds.add(ns);
        }
        return preview;
    }

    @AuraEnabled
    public static DesignSuggestionResult generateDesignSuggestion(Id initiativeId) {
        InitiativePreview preview = getPreviewData(initiativeId);

        Map<String, Object> requestBody = new Map<String, Object>{
            'initiativeId' => preview.initiativeId,
            'initiativeTitle' => preview.title,
            'whyRationale' => preview.whyRationale != null ? preview.whyRationale : '',
            'whatDescription' => preview.whatDescription != null ? preview.whatDescription : '',
            'targetCustomer' => preview.targetCustomer != null ? preview.targetCustomer : '',
            'productName' => preview.productName,
            'linkedNeeds' => buildNeedsList(preview.linkedNeeds)
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(GCP_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(requestBody));

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() != 200) {
            throw new AuraHandledException(
                'GCPからの応答エラー (' + res.getStatusCode() + '): ' + res.getBody()
            );
        }

        Map<String, Object> gcpResponse = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

        DesignSuggestionResult result = new DesignSuggestionResult();
        result.designSuggestionId = (String) gcpResponse.get('designSuggestionId');
        result.targetProduct = (String) gcpResponse.get('targetProduct');
        result.targetComponent = (String) gcpResponse.get('targetComponent');
        result.suggestionText = (String) gcpResponse.get('suggestionText');
        result.referenceSpec = (String) gcpResponse.get('referenceSpec');
        result.referenceDiagram = (String) gcpResponse.get('referenceDiagram');
        result.priority = (String) gcpResponse.get('priority');
        result.processedBy = (String) gcpResponse.get('processedBy');
        result.generatedAt = (String) gcpResponse.get('generatedAt');
        result.gcpRequestId = (String) gcpResponse.get('gcpRequestId');
        result.specUrl = (String) gcpResponse.get('specUrl');
        result.diagramUrl = (String) gcpResponse.get('diagramUrl');
        return result;
    }

    /**
     * エージェント版: initiativeId のみをGCPに送信し、
     * Product Engineering Agent が自律的にツール呼出してSF書き戻しまで完結させる。
     */
    @AuraEnabled
    public static DesignSuggestionResult generateDesignSuggestionAgent(Id initiativeId) {
        Map<String, Object> requestBody = new Map<String, Object>{
            'initiativeId' => initiativeId
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(GCP_ENDPOINT + '/design-suggestion-agent');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(requestBody));

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() != 200) {
            throw new AuraHandledException(
                'Agentからの応答エラー (' + res.getStatusCode() + '): ' + res.getBody()
            );
        }

        Map<String, Object> gcpResponse = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

        DesignSuggestionResult result = new DesignSuggestionResult();
        result.designSuggestionId = (String) gcpResponse.get('designSuggestionId');
        result.targetProduct = (String) gcpResponse.get('targetProduct');
        result.targetComponent = (String) gcpResponse.get('targetComponent');
        result.suggestionText = (String) gcpResponse.get('suggestionText');
        result.referenceSpec = (String) gcpResponse.get('referenceSpec');
        result.referenceDiagram = (String) gcpResponse.get('referenceDiagram');
        result.priority = (String) gcpResponse.get('priority');
        result.processedBy = (String) gcpResponse.get('processedBy');
        result.generatedAt = (String) gcpResponse.get('generatedAt');
        result.gcpRequestId = (String) gcpResponse.get('gcpRequestId');
        result.specUrl = (String) gcpResponse.get('specUrl');
        result.diagramUrl = (String) gcpResponse.get('diagramUrl');
        result.iterations = gcpResponse.get('iterations') != null ? (Integer) gcpResponse.get('iterations') : null;

        // toolHistory をパース
        result.toolHistory = new List<ToolHistoryEntry>();
        List<Object> histRaw = (List<Object>) gcpResponse.get('toolHistory');
        if (histRaw != null) {
            for (Object o : histRaw) {
                Map<String, Object> h = (Map<String, Object>) o;
                ToolHistoryEntry e = new ToolHistoryEntry();
                e.tool = (String) h.get('tool');
                e.args = (String) h.get('args');
                e.resultSummary = (String) h.get('result_summary');
                Object elapsed = h.get('elapsed_sec');
                if (elapsed != null) {
                    if (elapsed instanceof Decimal) e.elapsedSec = (Decimal) elapsed;
                    else if (elapsed instanceof Double) e.elapsedSec = Decimal.valueOf((Double) elapsed);
                    else if (elapsed instanceof Integer) e.elapsedSec = Decimal.valueOf((Integer) elapsed);
                }
                result.toolHistory.add(e);
            }
        }
        return result;
    }

    private static List<Map<String, String>> buildNeedsList(List<NeedSummary> needs) {
        List<Map<String, String>> result = new List<Map<String, String>>();
        for (NeedSummary ns : needs) {
            result.add(new Map<String, String>{
                'needsCardId' => ns.needsCardId,
                'title' => ns.title,
                'customerVoice' => ns.customerVoice != null ? ns.customerVoice : '',
                'description' => ns.description != null ? ns.description : '',
                'accountName' => ns.accountName
            });
        }
        return result;
    }
}
