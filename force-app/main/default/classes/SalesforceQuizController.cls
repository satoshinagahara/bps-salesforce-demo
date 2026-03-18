public with sharing class SalesforceQuizController {

    @AuraEnabled
    public static String generateQuiz(String category, String difficulty) {
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            input.isPreview = false;

            Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();

            ConnectApi.WrappedValue categoryVal = new ConnectApi.WrappedValue();
            categoryVal.value = category;
            inputParams.put('Input:category', categoryVal);

            ConnectApi.WrappedValue difficultyVal = new ConnectApi.WrappedValue();
            difficultyVal.value = difficulty;
            inputParams.put('Input:difficulty', difficultyVal);

            input.inputParams = inputParams;
            input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            input.additionalConfig.applicationName = 'PromptBuilderPreview';
            input.additionalConfig.temperature = 0.7;

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation result =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                    'SalesforceQuizGenerator',
                    input
                );

            if (result.generations != null && !result.generations.isEmpty()) {
                return result.generations[0].text;
            }

            return '[]';
        } catch (Exception e) {
            throw new AuraHandledException('クイズ生成エラー: ' + e.getMessage());
        }
    }
}
