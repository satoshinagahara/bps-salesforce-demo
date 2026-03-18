public with sharing class CASummaryController {

    @AuraEnabled
    public static String generateSummary(Id caId) {
        // 1. CA情報を一括取得
        Corrective_Action__c ca = [
            SELECT Id, Name, Title__c, Phase__c, Severity__c, Category__c,
                   Target_Close_Date__c, Actual_Close_Date__c, Knowledge_Created__c,
                   D2_Problem_Description__c, D3_Containment__c, D4_Root_Cause__c,
                   D5_Permanent_Action__c, D6_Verification__c, D7_Prevention__c,
                   Product__c, Product__r.Name,
                   Supplier__c, Supplier__r.Name,
                   BOM_Part__c, BOM_Part__r.Part_Name__c, BOM_Part__r.Part_Number__c,
                   Team_Lead__c, Team_Lead__r.Name,
                   Case__c, Case__r.CaseNumber, Case__r.Subject, Case__r.Status,
                   Case__r.Account.Name,
                   Parent_CA__c, Parent_CA__r.Name, Parent_CA__r.Title__c
            FROM Corrective_Action__c
            WHERE Id = :caId
            LIMIT 1
        ];

        // 2. サプライヤー調査状況
        List<Supplier_Investigation__c> investigations = [
            SELECT Id, Name, Status__c, Response_Due_Date__c, Supplier__r.Name
            FROM Supplier_Investigation__c
            WHERE Corrective_Action__c = :caId
            ORDER BY CreatedDate DESC
            LIMIT 10
        ];

        // 3. 子CA（水平展開先）
        List<Corrective_Action__c> childCAs = [
            SELECT Id, Name, Title__c, Phase__c
            FROM Corrective_Action__c
            WHERE Parent_CA__c = :caId
            LIMIT 10
        ];

        // 4. データをJSON構築
        Map<String, Object> data = new Map<String, Object>();
        data.put('caName', ca.Name);
        data.put('title', ca.Title__c);
        data.put('phase', ca.Phase__c);
        data.put('severity', ca.Severity__c);
        data.put('category', ca.Category__c);
        data.put('knowledgeCreated', ca.Knowledge_Created__c);

        if (ca.Target_Close_Date__c != null) {
            data.put('targetCloseDate', String.valueOf(ca.Target_Close_Date__c));
            Integer daysRemaining = Date.today().daysBetween(ca.Target_Close_Date__c);
            data.put('daysRemaining', daysRemaining);
            data.put('isOverdue', daysRemaining < 0);
        }
        if (ca.Actual_Close_Date__c != null) {
            data.put('actualCloseDate', String.valueOf(ca.Actual_Close_Date__c));
        }

        // 8Dフェーズ詳細（入力済みのもの）
        Map<String, Object> phases = new Map<String, Object>();
        if (ca.D2_Problem_Description__c != null) phases.put('D2_問題定義', truncate(ca.D2_Problem_Description__c, 500));
        if (ca.D3_Containment__c != null) phases.put('D3_暫定対応', truncate(ca.D3_Containment__c, 500));
        if (ca.D4_Root_Cause__c != null) phases.put('D4_原因分析', truncate(ca.D4_Root_Cause__c, 500));
        if (ca.D5_Permanent_Action__c != null) phases.put('D5_恒久対策', truncate(ca.D5_Permanent_Action__c, 500));
        if (ca.D6_Verification__c != null) phases.put('D6_実施検証', truncate(ca.D6_Verification__c, 500));
        if (ca.D7_Prevention__c != null) phases.put('D7_再発防止', truncate(ca.D7_Prevention__c, 500));
        data.put('phaseDetails', phases);

        if (ca.Product__r != null) data.put('product', ca.Product__r.Name);
        if (ca.Supplier__r != null) data.put('supplier', ca.Supplier__r.Name);
        if (ca.BOM_Part__r != null) data.put('part', ca.BOM_Part__r.Part_Name__c);
        if (ca.Team_Lead__r != null) data.put('teamLeader', ca.Team_Lead__r.Name);
        if (ca.Case__r != null) {
            data.put('caseNumber', ca.Case__r.CaseNumber);
            data.put('caseSubject', ca.Case__r.Subject);
            data.put('caseStatus', ca.Case__r.Status);
            if (ca.Case__r.Account != null) data.put('customer', ca.Case__r.Account.Name);
        }
        if (ca.Parent_CA__r != null) {
            data.put('parentCA', ca.Parent_CA__r.Name + ': ' + ca.Parent_CA__r.Title__c);
        }

        // サプライヤー調査
        if (!investigations.isEmpty()) {
            List<Map<String, Object>> siList = new List<Map<String, Object>>();
            for (Supplier_Investigation__c si : investigations) {
                Map<String, Object> siMap = new Map<String, Object>();
                siMap.put('name', si.Name);
                siMap.put('status', si.Status__c);
                siMap.put('supplier', si.Supplier__r?.Name);
                if (si.Response_Due_Date__c != null) siMap.put('responseDueDate', String.valueOf(si.Response_Due_Date__c));
                siList.add(siMap);
            }
            data.put('supplierInvestigations', siList);
        }

        // 子CA
        if (!childCAs.isEmpty()) {
            List<Map<String, Object>> childList = new List<Map<String, Object>>();
            for (Corrective_Action__c child : childCAs) {
                childList.add(new Map<String, Object>{
                    'name' => child.Name,
                    'title' => child.Title__c,
                    'phase' => child.Phase__c
                });
            }
            data.put('childCAs', childList);
        }

        data.put('todayDate', String.valueOf(Date.today()));

        // 5. Prompt Template呼出し
        String jsonData = JSON.serialize(data);
        return callPromptTemplate(jsonData);
    }

    private static String callPromptTemplate(String jsonData) {
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
        inputParams.put('Input:caData', wv);
        input.inputParams = inputParams;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation result =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                'CASummaryGeneration', input);

        if (result.generations == null || result.generations.isEmpty()) {
            throw new AuraHandledException('サマリー生成に失敗しました。Prompt Templateが応答を返しませんでした。');
        }
        return result.generations[0].text;
    }

    private static String truncate(String text, Integer maxLen) {
        return text.length() > maxLen ? text.substring(0, maxLen) + '...' : text;
    }
}
