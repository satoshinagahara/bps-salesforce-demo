public class OpportunitySimilaritySearchHelper {

    private static final String VECTOR_SEARCH_TEMPLATE = 'OpportunitySimilarityVectorSearch';
    private static final Integer MAX_SIMILAR = 6; // Tier 1 + Tier 2 合計上限

    // 類似商談検索の共通ロジック（Agentforce / LWC 両方から呼ばれる）
    public static Map<String, Object> searchSimilar(Id opportunityId) {
        Map<String, Object> output = new Map<String, Object>();

        // 1. 対象商談の基本情報
        List<Opportunity> opps = [
            SELECT Id, Name, StageName, Amount, CloseDate,
                   Account.Name, Account.Industry, IsClosed, IsWon
            FROM Opportunity WHERE Id = :opportunityId LIMIT 1
        ];
        if (opps.isEmpty()) {
            output.put('error', '商談が見つかりません');
            return output;
        }
        Opportunity opp = opps[0];

        // 2. サマリカード取得
        List<Opportunity_Summary__c> currentSummaries = [
            SELECT Id, Deal_Type__c, Customer_Segment__c, Sales_Motion__c,
                   Competitive_Situation__c, Urgency_Driver__c, Sales_Process_Pattern__c,
                   Customer_Challenge__c, Our_Value_Proposition__c,
                   Deal_Narrative__c, Key_Risks__c, Lessons_Or_Insights__c
            FROM Opportunity_Summary__c
            WHERE Opportunity__c = :opportunityId LIMIT 1
        ];

        // 現在の商談情報
        Map<String, Object> cur = new Map<String, Object>();
        cur.put('name', opp.Name);
        cur.put('stage', opp.StageName);
        cur.put('amount', opp.Amount);
        cur.put('account', opp.Account.Name);

        if (!currentSummaries.isEmpty()) {
            Opportunity_Summary__c cs = currentSummaries[0];
            cur.put('hasSummaryCard', true);
            cur.put('dealType', cs.Deal_Type__c);
            cur.put('salesMotion', cs.Sales_Motion__c);
            cur.put('competitiveSituation', cs.Competitive_Situation__c);
            cur.put('urgencyDriver', cs.Urgency_Driver__c);
            cur.put('salesProcessPattern', cs.Sales_Process_Pattern__c);
            cur.put('customerChallenge', cs.Customer_Challenge__c);
            cur.put('valueProposition', cs.Our_Value_Proposition__c);
            cur.put('keyRisks', cs.Key_Risks__c);
        } else {
            cur.put('hasSummaryCard', false);
        }
        output.put('current', cur);

        // 3. Tier 1: 構造一致検索
        List<Map<String, Object>> similar = new List<Map<String, Object>>();
        Set<String> foundOppIds = new Set<String>{ String.valueOf(opportunityId) };

        if (!currentSummaries.isEmpty()) {
            Opportunity_Summary__c cs = currentSummaries[0];
            Set<Id> foundSummaryIds = new Set<Id>();

            // deal_type一致（最大2件）
            if (cs.Deal_Type__c != null) {
                for (Opportunity_Summary__c s : [
                    SELECT Id, Opportunity__c, Opportunity__r.Name, Opportunity__r.Account.Name,
                           Opportunity__r.IsWon,
                           Deal_Type__c, Sales_Motion__c, Competitive_Situation__c,
                           Sales_Process_Pattern__c, Confidence_Score__c, Opportunity_Stage__c,
                           Customer_Challenge__c, Our_Value_Proposition__c,
                           Lessons_Or_Insights__c
                    FROM Opportunity_Summary__c
                    WHERE Deal_Type__c = :cs.Deal_Type__c
                      AND Opportunity__c != :opportunityId
                      AND Confidence_Score__c >= 4
                    ORDER BY CreatedDate DESC LIMIT 2
                ]) {
                    foundSummaryIds.add(s.Id);
                    foundOppIds.add(String.valueOf(s.Opportunity__c));
                    similar.add(buildEntry(s, '同じ案件タイプ'));
                }
            }

            // sales_motion一致（最大1件）
            if (cs.Sales_Motion__c != null && similar.size() < 4) {
                for (Opportunity_Summary__c s : [
                    SELECT Id, Opportunity__c, Opportunity__r.Name, Opportunity__r.Account.Name,
                           Opportunity__r.IsWon,
                           Deal_Type__c, Sales_Motion__c, Competitive_Situation__c,
                           Sales_Process_Pattern__c, Confidence_Score__c, Opportunity_Stage__c,
                           Customer_Challenge__c, Our_Value_Proposition__c,
                           Lessons_Or_Insights__c
                    FROM Opportunity_Summary__c
                    WHERE Sales_Motion__c = :cs.Sales_Motion__c
                      AND Opportunity__c != :opportunityId
                      AND Id NOT IN :foundSummaryIds
                      AND Confidence_Score__c >= 4
                    ORDER BY CreatedDate DESC LIMIT 1
                ]) {
                    foundSummaryIds.add(s.Id);
                    foundOppIds.add(String.valueOf(s.Opportunity__c));
                    similar.add(buildEntry(s, '同じ営業アプローチ'));
                }
            }

            // urgency_driver一致（最大1件）
            if (cs.Urgency_Driver__c != null && cs.Urgency_Driver__c != '不明' && similar.size() < 4) {
                for (Opportunity_Summary__c s : [
                    SELECT Id, Opportunity__c, Opportunity__r.Name, Opportunity__r.Account.Name,
                           Opportunity__r.IsWon,
                           Deal_Type__c, Sales_Motion__c, Competitive_Situation__c,
                           Sales_Process_Pattern__c, Confidence_Score__c, Opportunity_Stage__c,
                           Customer_Challenge__c, Our_Value_Proposition__c,
                           Lessons_Or_Insights__c
                    FROM Opportunity_Summary__c
                    WHERE Urgency_Driver__c = :cs.Urgency_Driver__c
                      AND Opportunity__c != :opportunityId
                      AND Id NOT IN :foundSummaryIds
                      AND Confidence_Score__c >= 4
                    ORDER BY CreatedDate DESC LIMIT 1
                ]) {
                    foundSummaryIds.add(s.Id);
                    foundOppIds.add(String.valueOf(s.Opportunity__c));
                    similar.add(buildEntry(s, '同じ緊急性の動因'));
                }
            }

            // 4. Tier 2: ベクトル検索（Data Cloud Retriever）
            if (similar.size() < MAX_SIMILAR) {
                String queryText = buildVectorQueryText(cs);
                if (String.isNotBlank(queryText)) {
                    List<Map<String, Object>> vectorResults = searchByRetriever(queryText);
                    for (Map<String, Object> vr : vectorResults) {
                        if (similar.size() >= MAX_SIMILAR) break;
                        String oppId = (String) vr.get('opportunityId');
                        if (oppId != null && !foundOppIds.contains(oppId)) {
                            Decimal confScore = (Decimal) vr.get('confidenceScore');
                            if (confScore != null && confScore >= 4) {
                                foundOppIds.add(oppId);
                                similar.add(buildVectorEntry(vr));
                            }
                        }
                    }
                }
            }
        }

        output.put('similar', similar);
        return output;
    }

    // Tier 2: Retriever検索用クエリテキストを構築
    private static String buildVectorQueryText(Opportunity_Summary__c cs) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(cs.Customer_Challenge__c)) parts.add(cs.Customer_Challenge__c);
        if (String.isNotBlank(cs.Our_Value_Proposition__c)) parts.add(cs.Our_Value_Proposition__c);
        if (String.isNotBlank(cs.Deal_Narrative__c)) parts.add(cs.Deal_Narrative__c);
        return String.join(parts, ' ');
    }

    // Prompt Template経由でData Cloud Retriever検索
    private static List<Map<String, Object>> searchByRetriever(String queryText) {
        List<Map<String, Object>> results = new List<Map<String, Object>>();
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsInput input =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            input.isPreview = false;
            input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            input.additionalConfig.applicationName = 'PromptBuilderPreview';
            input.additionalConfig.numGenerations = 1;
            input.additionalConfig.temperature = 0.0;

            Map<String, ConnectApi.WrappedValue> inputParams =
                new Map<String, ConnectApi.WrappedValue>();
            ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
            wv.value = queryText;
            inputParams.put('Input:searchQuery', wv);
            input.inputParams = inputParams;

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                    VECTOR_SEARCH_TEMPLATE, input);

            if (response.generations != null && !response.generations.isEmpty()) {
                String llmOutput = response.generations[0].text;
                results = parseVectorSearchResponse(llmOutput);
            }
        } catch (Exception e) {
            System.debug('ベクトル検索失敗: ' + e.getMessage());
        }
        return results;
    }

    // LLM出力のJSON配列をパース
    private static List<Map<String, Object>> parseVectorSearchResponse(String llmOutput) {
        List<Map<String, Object>> results = new List<Map<String, Object>>();
        // マークダウンコードブロックが含まれる場合は除去
        String cleaned = llmOutput.trim();
        if (cleaned.startsWith('```')) {
            cleaned = cleaned.substringAfter('\n');
            if (cleaned.endsWith('```')) {
                cleaned = cleaned.substringBeforeLast('```');
            }
            cleaned = cleaned.trim();
        }

        List<Object> parsed = (List<Object>) JSON.deserializeUntyped(cleaned);
        for (Object item : parsed) {
            Map<String, Object> record = (Map<String, Object>) item;
            // confidenceScoreを確実にDecimal型にする
            Object scoreVal = record.get('confidenceScore');
            if (scoreVal != null && !(scoreVal instanceof Decimal)) {
                record.put('confidenceScore', Decimal.valueOf(String.valueOf(scoreVal)));
            }
            results.add(record);
        }
        return results;
    }

    // ベクトル検索結果からエントリを構築
    private static Map<String, Object> buildVectorEntry(Map<String, Object> vr) {
        Map<String, Object> e = new Map<String, Object>();
        e.put('reason', '意味的に類似（ベクトル検索）');
        e.put('id', vr.get('opportunityId'));
        e.put('dealType', vr.get('dealType'));
        e.put('salesMotion', vr.get('salesMotion'));
        e.put('competitive', vr.get('competitive'));
        e.put('processPattern', vr.get('processPattern'));
        e.put('challenge', vr.get('challenge'));
        e.put('value', vr.get('value'));
        e.put('lessons', vr.get('lessons'));
        e.put('confidenceScore', vr.get('confidenceScore'));
        e.put('stage', vr.get('stage'));

        // 商談名・取引先名はRetrieverから取れないのでSOQLで補完
        String oppId = (String) vr.get('opportunityId');
        if (String.isNotBlank(oppId)) {
            try {
                Opportunity o = [SELECT Name, Account.Name, IsWon FROM Opportunity WHERE Id = :oppId LIMIT 1];
                e.put('name', o.Name);
                e.put('account', o.Account.Name);
                e.put('won', o.IsWon);
            } catch (Exception ex) {
                e.put('name', '（不明）');
            }
        }
        return e;
    }

    private static Map<String, Object> buildEntry(Opportunity_Summary__c s, String reason) {
        Map<String, Object> e = new Map<String, Object>();
        e.put('reason', reason);
        e.put('name', s.Opportunity__r.Name);
        e.put('id', s.Opportunity__c);
        e.put('account', s.Opportunity__r.Account.Name);
        e.put('won', s.Opportunity__r.IsWon);
        e.put('dealType', s.Deal_Type__c);
        e.put('salesMotion', s.Sales_Motion__c);
        e.put('competitive', s.Competitive_Situation__c);
        e.put('processPattern', s.Sales_Process_Pattern__c);
        e.put('challenge', s.Customer_Challenge__c);
        e.put('value', s.Our_Value_Proposition__c);
        e.put('lessons', s.Lessons_Or_Insights__c);
        e.put('confidenceScore', s.Confidence_Score__c);
        e.put('stage', s.Opportunity_Stage__c);
        return e;
    }
}
