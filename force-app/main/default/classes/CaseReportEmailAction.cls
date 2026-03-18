public with sharing class CaseReportEmailAction {

    public class Request {
        @InvocableVariable(required=true label='ケースID')
        public Id caseId;
    }

    public class Result {
        @InvocableVariable(label='生成メール文面')
        public String emailText;
    }

    @InvocableMethod(label='顧客報告メール生成' description='Case+是正措置データを取得しPrompt Templateでメール文面を生成')
    public static List<Result> generate(List<Request> requests) {
        Id caseId = requests[0].caseId;

        // 1. データ取得（CaseReportGeneratorを再利用）
        String jsonData = CaseReportGenerator.getData(new List<Id>{ caseId })[0];

        // 2. Prompt Template 呼び出し
        String emailText = callPromptTemplate(jsonData);

        Result res = new Result();
        res.emailText = emailText;
        return new List<Result>{ res };
    }

    private static String callPromptTemplate(String jsonData) {
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsInput input =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            input.isPreview = false;
            input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            input.additionalConfig.applicationName = 'PromptBuilderPreview';
            input.additionalConfig.temperature = 0.4;

            Map<String, ConnectApi.WrappedValue> inputParams =
                new Map<String, ConnectApi.WrappedValue>();
            ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
            wv.value = jsonData;
            inputParams.put('Input:reportData', wv);
            input.inputParams = inputParams;

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation result =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                    'CaseCustomerReport', input);

            return result.generations[0].text;
        } catch (Exception e) {
            return '【メール文面の自動生成中にエラーが発生しました】\n\n'
                 + 'エラー: ' + e.getMessage() + '\n\n'
                 + '--- 以下は収集した生データです（手動でメールを作成する際にご利用ください）---\n\n'
                 + jsonData;
        }
    }
}
