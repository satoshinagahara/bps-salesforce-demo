public with sharing class CampaignSurveyAnalysisAction {

    // LWCから呼び出し用
    @AuraEnabled
    public static AnalysisResult analyzeCampaignSurveyLwc(Id campaignId) {
        return processAnalysis(campaignId);
    }

    // Batch / Apex から呼び出し用
    public static AnalysisResult analyze(Id campaignId) {
        return processAnalysis(campaignId);
    }

    public class AnalysisResult {
        @AuraEnabled public String resultMessage;
        @AuraEnabled public String sentiment;
        @AuraEnabled public String keyFindings;
        @AuraEnabled public String improvements;
        @AuraEnabled public String fullAnalysis;
        @AuraEnabled public String errorMessage;
    }

    private static AnalysisResult processAnalysis(Id campaignId) {
        AnalysisResult result = new AnalysisResult();

        try {
            Campaign campaign = [
                SELECT Id, Name, Type, Status, StartDate, EndDate,
                       NumberOfContacts, NumberOfLeads, Description
                FROM Campaign
                WHERE Id = :campaignId
                LIMIT 1
            ];

            String eventInfo = 'イベント名: ' + campaign.Name;
            if (campaign.Description != null) {
                eventInfo += '\n説明: ' + campaign.Description;
            }
            if (campaign.StartDate != null) {
                eventInfo += '\n開催日: ' + String.valueOf(campaign.StartDate);
            }

            String feedbackResponse = callFeedbackTemplate(eventInfo);
            result.fullAnalysis = feedbackResponse;

            String jsonStr = extractJsonFromResponse(feedbackResponse);
            if (jsonStr != null) {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonStr);

                String sentiment = (String) parsed.get('overall_sentiment');
                String responseSummary = (String) parsed.get('response_summary');

                String keyFindings = formatList(parsed, 'key_findings');
                String positivePoints = formatList(parsed, 'positive_points');
                String negativePoints = formatList(parsed, 'negative_points');
                String improvements = formatList(parsed, 'improvements');
                String nextEventSuggestions = formatList(parsed, 'next_event_suggestions');
                String segments = formatSegments(parsed);

                Campaign updateCampaign = new Campaign(Id = campaignId);
                updateCampaign.Survey_Sentiment__c = sentiment;
                updateCampaign.Survey_Key_Findings__c = '## 回答傾向\n' + responseSummary
                    + '\n\n## 主要発見事項\n' + keyFindings
                    + '\n\n## 参加者セグメント\n' + segments;
                updateCampaign.Survey_Improvements__c = '## ポジティブな反応\n' + positivePoints
                    + '\n\n## ネガティブな反応・課題\n' + negativePoints
                    + '\n\n## 次回改善点\n' + improvements
                    + '\n\n## 次回イベント企画の提案\n' + nextEventSuggestions;
                updateCampaign.Survey_Analysis__c = feedbackResponse;
                updateCampaign.Survey_Analyzed_Date__c = Datetime.now();
                update updateCampaign;

                result.sentiment = sentiment;
                result.keyFindings = updateCampaign.Survey_Key_Findings__c;
                result.improvements = updateCampaign.Survey_Improvements__c;
            }

            result.resultMessage = 'キャンペーン「' + campaign.Name + '」の反響分析が完了しました。'
                + '\n反響: ' + result.sentiment;

        } catch (Exception e) {
            result.errorMessage = e.getTypeName() + ': ' + e.getMessage();
        }
        return result;
    }

    private static String callFeedbackTemplate(String eventInfo) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;

        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
        wv.value = eventInfo;
        inputParams.put('Input:eventInfo', wv);
        input.inputParams = inputParams;

        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptBuilderPreview';
        input.additionalConfig.temperature = 0.2;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                'EventSurveyFeedback', input
            );

        if (response.generations == null || response.generations.isEmpty()) {
            throw new CampaignAnalysisException('Prompt Templateからの応答が空です。');
        }

        return ((ConnectApi.EinsteinLLMGenerationItemOutput) response.generations[0]).text;
    }

    private static String formatList(Map<String, Object> parsed, String key) {
        List<Object> items = (List<Object>) parsed.get(key);
        if (items == null || items.isEmpty()) return '（なし）';
        String result = '';
        for (Object item : items) {
            result += '• ' + String.valueOf(item) + '\n';
        }
        return result.trim();
    }

    private static String formatSegments(Map<String, Object> parsed) {
        List<Object> segments = (List<Object>) parsed.get('attendee_segments');
        if (segments == null || segments.isEmpty()) return '（なし）';
        String result = '';
        for (Object seg : segments) {
            Map<String, Object> s = (Map<String, Object>) seg;
            result += '• ' + String.valueOf(s.get('segment'))
                + '（約' + String.valueOf(s.get('count_hint')) + '名）: '
                + String.valueOf(s.get('key_interest')) + '\n';
        }
        return result.trim();
    }

    private static String extractJsonFromResponse(String response) {
        if (response == null) return null;
        Integer jsonStart = response.indexOf('```json');
        if (jsonStart >= 0) {
            jsonStart = response.indexOf('\n', jsonStart) + 1;
            Integer jsonEnd = response.indexOf('```', jsonStart);
            if (jsonEnd > jsonStart) {
                return response.substring(jsonStart, jsonEnd).trim();
            }
        }
        Integer braceStart = response.indexOf('{');
        Integer braceEnd = response.lastIndexOf('}');
        if (braceStart >= 0 && braceEnd > braceStart) {
            return response.substring(braceStart, braceEnd + 1);
        }
        return null;
    }

    public class CampaignAnalysisException extends Exception {}
}
