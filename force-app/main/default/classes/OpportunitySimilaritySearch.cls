global class OpportunitySimilaritySearch {

    global class Request {
        @InvocableVariable(label='商談ID' description='類似商談を検索する対象の商談ID' required=true)
        global String opportunityId;
        @InvocableVariable(label='質問内容' description='ユーザーが知りたいこと（例：競合に勝つには？次に何をすべき？）' required=false)
        global String userQuery;
    }

    global class Result {
        @InvocableVariable(label='類似商談分析レポート')
        global String analysisReport;
    }

    @InvocableMethod(label='類似商談分析' description='指定された商談の類似商談を検索し、比較分析とインサイトを含むレポートを生成します')
    global static List<Result> search(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();

            // ヘルパーで検索
            Map<String, Object> searchResult = OpportunitySimilaritySearchHelper.searchSimilar(Id.valueOf(req.opportunityId));

            // Prompt Template用JSONを構築
            Map<String, Object> promptInput = new Map<String, Object>();
            promptInput.put('current', searchResult.get('current'));
            promptInput.put('similar', searchResult.get('similar'));
            if (String.isNotBlank(req.userQuery)) {
                promptInput.put('userQuery', req.userQuery);
            }

            // マークダウンレポートを生成（Agentforceチャット用）
            res.analysisReport = generateMarkdownInsights(JSON.serialize(promptInput));
            results.add(res);
        }
        return results;
    }

    private static String generateMarkdownInsights(String jsonData) {
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
                    'OpportunitySimilarityInsights', input);

            return result.generations[0].text;
        } catch (Exception e) {
            return 'レポート生成中にエラーが発生しました: ' + e.getMessage();
        }
    }
}
