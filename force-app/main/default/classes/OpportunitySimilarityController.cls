public class OpportunitySimilarityController {

    // --- パネル初期表示: 入力状況の取得（軽量） ---

    @AuraEnabled(cacheable=true)
    public static String getInputStatus(Id opportunityId) {
        Map<String, Object> status = new Map<String, Object>();

        // 商談基本情報
        Opportunity opp = [
            SELECT Id, Name, Description, StageName, Amount, Account.Name
            FROM Opportunity WHERE Id = :opportunityId LIMIT 1
        ];
        status.put('name', opp.Name);
        status.put('stage', opp.StageName);
        status.put('accountName', opp.Account.Name);

        // Description有無
        Boolean hasDescription = String.isNotBlank(opp.Description);
        status.put('hasDescription', hasDescription);

        // サマリカード有無
        Integer summaryCount = [
            SELECT COUNT() FROM Opportunity_Summary__c
            WHERE Opportunity__c = :opportunityId
        ];
        status.put('hasSummaryCard', summaryCount > 0);

        // 商品件数
        Integer productCount = [
            SELECT COUNT() FROM OpportunityLineItem
            WHERE OpportunityId = :opportunityId
        ];
        status.put('productCount', productCount);

        // 活動件数（Task + Event）
        Integer taskCount = [
            SELECT COUNT() FROM Task WHERE WhatId = :opportunityId
        ];
        Integer eventCount = [
            SELECT COUNT() FROM Event WHERE WhatId = :opportunityId
        ];
        Integer activityCount = taskCount + eventCount;
        status.put('activityCount', activityCount);

        // 信頼度スコア（1-5）
        Integer score = 1;
        if (hasDescription) score = 2;
        if (hasDescription && (productCount > 0 || activityCount > 0)) score = 3;
        if (summaryCount > 0 && hasDescription && (productCount > 0 || activityCount > 0)) score = 4;
        if (summaryCount > 0 && hasDescription && productCount >= 3 && activityCount >= 5) score = 5;
        status.put('confidenceScore', score);

        return JSON.serialize(status);
    }

    // --- 分析実行: 類似商談検索 + Prompt Template（JSON出力） ---

    @AuraEnabled
    public static String searchAndAnalyze(Id opportunityId, String userQuery) {
        // 既存のsearchSimilarロジックを再利用
        Map<String, Object> searchResult = OpportunitySimilaritySearchHelper.searchSimilar(opportunityId);

        // Prompt TemplateでJSON形式の分析結果を生成
        Map<String, Object> promptInput = new Map<String, Object>();
        promptInput.put('current', searchResult.get('current'));
        promptInput.put('similar', searchResult.get('similar'));
        if (String.isNotBlank(userQuery)) {
            promptInput.put('userQuery', userQuery);
        }

        String jsonData = JSON.serialize(promptInput);
        String analysisJson = generateStructuredInsights(jsonData);

        return analysisJson;
    }

    // --- ToDo作成 ---

    @AuraEnabled
    public static Id createTodoFromRecommendation(Id opportunityId, String subject, String description) {
        Task t = new Task(
            Subject = subject,
            Description = description,
            WhatId = opportunityId,
            OwnerId = UserInfo.getUserId(),
            Status = 'Not Started',
            Priority = 'Normal',
            ActivityDate = Date.today().addDays(7)
        );
        insert t;
        return t.Id;
    }

    // --- Prompt Template呼び出し（JSON構造化出力） ---

    private static String generateStructuredInsights(String jsonData) {
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsInput input =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            input.isPreview = false;
            input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            input.additionalConfig.applicationName = 'PromptBuilderPreview';
            input.additionalConfig.numGenerations = 1;
            input.additionalConfig.temperature = 0.2;

            Map<String, ConnectApi.WrappedValue> inputParams =
                new Map<String, ConnectApi.WrappedValue>();
            ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
            wv.value = jsonData;
            inputParams.put('Input:analysisData', wv);
            input.inputParams = inputParams;

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation result =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                    'OpportunitySimilarityStructured', input);

            return result.generations[0].text;
        } catch (Exception e) {
            // フォールバック: エラー情報を含むJSONを返す
            Map<String, Object> errorResult = new Map<String, Object>();
            errorResult.put('error', e.getMessage());
            errorResult.put('summary', 'レポート生成中にエラーが発生しました');
            errorResult.put('recommendations', new List<Object>());
            errorResult.put('risks', new List<String>());
            errorResult.put('similarOpportunities', new List<Object>());
            return JSON.serialize(errorResult);
        }
    }
}
