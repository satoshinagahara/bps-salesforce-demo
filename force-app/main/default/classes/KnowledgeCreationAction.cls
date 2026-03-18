public with sharing class KnowledgeCreationAction {

    @InvocableMethod(label='ナレッジ作成' description='是正措置（CA）の知見をナレッジ記事として作成または既存ナレッジに統合する。CAのレコードページにいる場合は現在のレコードIDをそのまま渡す。')
    public static List<Result> createKnowledge(List<Request> requests) {
        Request req = requests[0];
        Result res = new Result();

        try {
            // CA情報取得
            Corrective_Action__c ca = getCAData(req.caId);
            if (ca == null) {
                // Name検索フォールバック
                List<Corrective_Action__c> casByName = [
                    SELECT Id FROM Corrective_Action__c WHERE Name = :req.caId LIMIT 1
                ];
                if (!casByName.isEmpty()) {
                    ca = getCAData(casByName[0].Id);
                }
            }
            if (ca == null) {
                res.report = '指定された是正措置が見つかりません: ' + req.caId;
                return new List<Result>{ res };
            }

            // 既にナレッジ化済みかチェック
            if (ca.Knowledge_Created__c) {
                res.report = 'この是正措置（' + ca.Name + '）は既にナレッジ化済みです。再度ナレッジ化する場合は、Knowledge_Created__cフラグを解除してから再実行してください。';
                return new List<Result>{ res };
            }

            // CA要約データを構築
            Map<String, Object> caData = buildCAData(ca);

            // SOSLで既存ナレッジを類似検索
            List<Map<String, Object>> similarArticles = findSimilarArticles(ca);
            caData.put('existingArticles', similarArticles);
            caData.put('hasExistingArticles', !similarArticles.isEmpty());

            // Prompt Template呼出し
            String jsonData = JSON.serialize(caData);
            String llmResponse = callPromptTemplate(jsonData);

            // LLMレスポンスをパース
            Map<String, Object> parsed = parseResponse(llmResponse);
            if (parsed == null) {
                res.report = 'ナレッジ生成結果のパースに失敗しました。\n\n--- LLM応答 ---\n' + llmResponse;
                return new List<Result>{ res };
            }

            // ナレッジ記事を保存
            String saveReport = saveKnowledgeArticles(parsed, ca);

            // CAのナレッジ化済みフラグを更新
            ca.Knowledge_Created__c = true;
            update ca;

            res.report = saveReport;
        } catch (Exception e) {
            res.report = 'ナレッジ作成中にエラーが発生しました: ' + e.getMessage();
        }

        return new List<Result>{ res };
    }

    private static Corrective_Action__c getCAData(String caId) {
        try {
            List<Corrective_Action__c> cas = [
                SELECT Id, Name, Title__c, Category__c, Phase__c, Severity__c,
                       D2_Problem_Description__c, D3_Containment__c, D4_Root_Cause__c,
                       D5_Permanent_Action__c, D6_Verification__c, D7_Prevention__c,
                       Knowledge_Input__c, Knowledge_Created__c,
                       Impact_Scope__c,
                       Product__c, Product__r.Name, Product__r.ProductCode, Product__r.Family,
                       BOM_Part__c, BOM_Part__r.Part_Name__c, BOM_Part__r.Part_Number__c,
                       BOM_Part__r.Supplier__r.Name,
                       Supplier__c, Supplier__r.Name,
                       Parent_CA__c, Parent_CA__r.Name,
                       Case__r.Subject, Case__r.CaseNumber
                FROM Corrective_Action__c
                WHERE Id = :caId
                LIMIT 1
            ];
            return cas.isEmpty() ? null : cas[0];
        } catch (Exception e) {
            return null;
        }
    }

    private static Map<String, Object> buildCAData(Corrective_Action__c ca) {
        Map<String, Object> data = new Map<String, Object>();
        data.put('caName', ca.Name);
        data.put('caTitle', ca.Title__c);
        data.put('category', ca.Category__c);
        data.put('phase', ca.Phase__c);
        data.put('severity', ca.Severity__c);
        data.put('problemDescription', ca.D2_Problem_Description__c);
        data.put('containment', ca.D3_Containment__c);
        data.put('rootCause', ca.D4_Root_Cause__c);
        data.put('permanentAction', ca.D5_Permanent_Action__c);
        data.put('verification', ca.D6_Verification__c);
        data.put('prevention', ca.D7_Prevention__c);
        data.put('knowledgeInput', ca.Knowledge_Input__c);
        data.put('impactScope', ca.Impact_Scope__c);

        if (ca.Product__c != null) {
            data.put('productName', ca.Product__r.Name);
            data.put('productCode', ca.Product__r.ProductCode);
            data.put('productFamily', ca.Product__r.Family);
        }
        if (ca.BOM_Part__c != null) {
            data.put('partName', ca.BOM_Part__r.Part_Name__c);
            data.put('partNumber', ca.BOM_Part__r.Part_Number__c);
            if (ca.BOM_Part__r.Supplier__r != null) {
                data.put('partSupplier', ca.BOM_Part__r.Supplier__r.Name);
            }
        }
        if (ca.Supplier__c != null) {
            data.put('supplierName', ca.Supplier__r.Name);
        }
        if (ca.Case__r != null) {
            data.put('caseNumber', ca.Case__r.CaseNumber);
            data.put('caseSubject', ca.Case__r.Subject);
        }

        // 関連CA（親CA経由の兄弟）
        List<Map<String, Object>> relatedCAs = new List<Map<String, Object>>();
        if (ca.Parent_CA__c != null) {
            for (Corrective_Action__c sibling : [
                SELECT Id, Name, Title__c, Category__c, Phase__c
                FROM Corrective_Action__c
                WHERE Parent_CA__c = :ca.Parent_CA__c AND Id != :ca.Id
                LIMIT 10
            ]) {
                relatedCAs.add(new Map<String, Object>{
                    'name' => sibling.Name,
                    'title' => sibling.Title__c,
                    'category' => sibling.Category__c,
                    'phase' => sibling.Phase__c
                });
            }
        }
        data.put('relatedCAs', relatedCAs);

        return data;
    }

    private static List<Map<String, Object>> findSimilarArticles(Corrective_Action__c ca) {
        List<Map<String, Object>> results = new List<Map<String, Object>>();

        // 検索キーワードを構築（部品番号、サプライヤー名、カテゴリ、Impact_Scope）
        List<String> searchTerms = new List<String>();
        if (ca.BOM_Part__r?.Part_Number__c != null) searchTerms.add(ca.BOM_Part__r.Part_Number__c);
        if (ca.BOM_Part__r?.Part_Name__c != null) searchTerms.add(ca.BOM_Part__r.Part_Name__c);
        if (ca.Supplier__r?.Name != null) searchTerms.add(ca.Supplier__r.Name);
        if (ca.BOM_Part__r?.Supplier__r?.Name != null && ca.BOM_Part__r.Supplier__r.Name != ca.Supplier__r?.Name) {
            searchTerms.add(ca.BOM_Part__r.Supplier__r.Name);
        }
        if (ca.Product__r?.Name != null) searchTerms.add(ca.Product__r.Name);
        if (ca.Impact_Scope__c != null) {
            for (String kw : ca.Impact_Scope__c.split('[,\\s]+')) {
                if (kw.length() > 1) searchTerms.add(kw);
            }
        }

        if (searchTerms.isEmpty()) return results;

        // SOSLで検索（OR結合）
        String searchQuery = String.join(searchTerms, ' OR ');
        // SOSL最大200文字制限を考慮
        if (searchQuery.length() > 180) {
            searchQuery = searchQuery.substring(0, 180);
        }

        // Design_Knowledgeレコードタイプのみ検索
        Id rtId = Schema.SObjectType.Knowledge__kav.getRecordTypeInfosByDeveloperName()
            .get('Design_Knowledge')?.getRecordTypeId();

        try {
            List<List<SObject>> soslResults = [
                FIND :searchQuery IN ALL FIELDS
                RETURNING Knowledge__kav(
                    Id, Title, Part_Category__c, Search_Keywords__c,
                    Lesson__c, Design_Guideline__c, Procurement_Guideline__c,
                    Source_CAs__c, PublishStatus, VersionNumber
                    WHERE RecordTypeId = :rtId AND IsLatestVersion = true
                    AND Language = 'en_US'
                )
                LIMIT 10
            ];

            for (Knowledge__kav art : (List<Knowledge__kav>) soslResults[0]) {
                Map<String, Object> artMap = new Map<String, Object>();
                artMap.put('id', art.Id);
                artMap.put('title', art.Title);
                artMap.put('category', art.Part_Category__c);
                artMap.put('keywords', art.Search_Keywords__c);
                artMap.put('lesson', art.Lesson__c);
                artMap.put('designGuideline', art.Design_Guideline__c);
                artMap.put('procurementGuideline', art.Procurement_Guideline__c);
                artMap.put('sourceCAs', art.Source_CAs__c);
                artMap.put('publishStatus', art.PublishStatus);
                results.add(artMap);
            }
        } catch (Exception e) {
            // SOSL検索失敗時は既存ナレッジなしとして続行
        }

        return results;
    }

    private static String callPromptTemplate(String jsonData) {
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsInput input =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            input.isPreview = false;
            input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            input.additionalConfig.applicationName = 'PromptBuilderPreview';
            input.additionalConfig.numGenerations = 1;
            input.additionalConfig.temperature = 0.4;

            Map<String, ConnectApi.WrappedValue> inputParams =
                new Map<String, ConnectApi.WrappedValue>();
            ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
            wv.value = jsonData;
            inputParams.put('Input:analysisData', wv);
            input.inputParams = inputParams;

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation result =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                    'KnowledgeArticleGeneration', input);

            if (result.generations == null || result.generations.isEmpty()) {
                return '{"error": "Prompt Template returned empty generations"}';
            }
            return result.generations[0].text;
        } catch (Exception e) {
            return '{"error": "' + e.getMessage().replace('"', '\\"') + '"}';
        }
    }

    private static Map<String, Object> parseResponse(String llmResponse) {
        try {
            // JSON部分を抽出（前後にテキストがある場合に対応）
            String jsonStr = llmResponse;
            Integer startIdx = llmResponse.indexOf('{');
            Integer endIdx = llmResponse.lastIndexOf('}');
            if (startIdx >= 0 && endIdx > startIdx) {
                jsonStr = llmResponse.substring(startIdx, endIdx + 1);
            }
            return (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
        } catch (Exception e) {
            return null;
        }
    }

    private static String saveKnowledgeArticles(Map<String, Object> parsed, Corrective_Action__c ca) {
        List<String> reportLines = new List<String>();
        reportLines.add('■ ナレッジ作成レポート（' + ca.Name + ': ' + ca.Title__c + '）');
        reportLines.add('');

        Id rtId = Schema.SObjectType.Knowledge__kav.getRecordTypeInfosByDeveloperName()
            .get('Design_Knowledge')?.getRecordTypeId();

        // actionsリスト: 各アクション（新規 or 統合）を処理
        List<Object> actions = (List<Object>) parsed.get('actions');
        if (actions == null || actions.isEmpty()) {
            reportLines.add('LLMがナレッジ化不要と判断しました。');
            return String.join(reportLines, '\n');
        }

        Integer newCount = 0;
        Integer mergeCount = 0;

        for (Object actionObj : actions) {
            Map<String, Object> action = (Map<String, Object>) actionObj;
            String actionType = (String) action.get('type');
            String reason = (String) action.get('reason');

            if (actionType == 'new') {
                // 新規作成
                Knowledge__kav article = new Knowledge__kav();
                article.RecordTypeId = rtId;
                article.Title = (String) action.get('title');
                article.UrlName = generateUrlName((String) action.get('title'));
                article.Part_Category__c = (String) action.get('category');
                article.Lesson__c = (String) action.get('lesson');
                article.Design_Guideline__c = (String) action.get('designGuideline');
                article.Procurement_Guideline__c = (String) action.get('procurementGuideline');
                article.Search_Keywords__c = (String) action.get('keywords');
                article.Source_CA__c = ca.Id;
                article.Source_CAs__c = ca.Name + ': ' + ca.Title__c;
                insert article;

                newCount++;
                reportLines.add('【新規作成】' + article.Title);
                reportLines.add('  理由: ' + reason);
                reportLines.add('  カテゴリ: ' + article.Part_Category__c);
                reportLines.add('  ステータス: ドラフト');
                reportLines.add('');

            } else if (actionType == 'merge') {
                // 既存ナレッジに統合
                String targetArticleId = (String) action.get('targetArticleId');
                String targetTitle = (String) action.get('targetTitle');

                // 既存記事を取得
                List<Knowledge__kav> existingArts = [
                    SELECT Id, KnowledgeArticleId, Title, Lesson__c, Design_Guideline__c,
                           Procurement_Guideline__c, Search_Keywords__c, Source_CAs__c
                    FROM Knowledge__kav
                    WHERE Id = :targetArticleId AND IsLatestVersion = true
                    LIMIT 1
                ];

                if (!existingArts.isEmpty()) {
                    Knowledge__kav existing = existingArts[0];

                    // 公開記事の場合はドラフト版を作成
                    Id draftId;
                    try {
                        draftId = KbManagement.PublishingService.editOnlineArticle(
                            existing.KnowledgeArticleId, false);
                    } catch (Exception e) {
                        // 既にドラフトの場合はそのまま使う
                        draftId = existing.Id;
                    }

                    // ドラフト版を取得して更新
                    Knowledge__kav draft = [
                        SELECT Id, Lesson__c, Design_Guideline__c, Procurement_Guideline__c,
                               Search_Keywords__c, Source_CAs__c
                        FROM Knowledge__kav
                        WHERE Id = :draftId
                        LIMIT 1
                    ];

                    // LLMが生成した統合後コンテンツで更新
                    draft.Lesson__c = (String) action.get('lesson');
                    draft.Design_Guideline__c = (String) action.get('designGuideline');
                    draft.Procurement_Guideline__c = (String) action.get('procurementGuideline');

                    // キーワード追加
                    String newKeywords = (String) action.get('keywords');
                    if (newKeywords != null) {
                        draft.Search_Keywords__c = newKeywords;
                    }

                    // Source_CAs更新
                    String existingCAs = draft.Source_CAs__c != null ? draft.Source_CAs__c : '';
                    String newCA = ca.Name + ': ' + ca.Title__c;
                    if (!existingCAs.contains(ca.Name)) {
                        draft.Source_CAs__c = existingCAs + (existingCAs.length() > 0 ? '\n' : '') + newCA;
                    }

                    update draft;

                    mergeCount++;
                    reportLines.add('【既存ナレッジに統合】' + targetTitle);
                    reportLines.add('  理由: ' + reason);
                    reportLines.add('  ステータス: ドラフト（レビュー待ち）');
                    reportLines.add('');
                }

            } else if (actionType == 'skip') {
                reportLines.add('【統合不要と判断】' + (String) action.get('targetTitle'));
                reportLines.add('  理由: ' + reason);
                reportLines.add('');
            }
        }

        reportLines.add('━━━━━━━━━━━━━━━━━━━━');
        reportLines.add('新規作成: ' + newCount + '件 / 既存統合: ' + mergeCount + '件');
        reportLines.add('全てドラフト状態で保存済み。内容を確認後、公開してください。');

        return String.join(reportLines, '\n');
    }

    private static String generateUrlName(String title) {
        // タイトルからURL-safe名を生成
        String urlName = 'dk-' + String.valueOf(Datetime.now().getTime());
        return urlName;
    }

    public class Request {
        @InvocableVariable(label='是正措置ID' description='ナレッジ化する是正措置のID。レコードページにいる場合は現在のレコードIDをそのまま渡す。' required=true)
        public String caId;
    }

    public class Result {
        @InvocableVariable(label='ナレッジ作成レポート' description='ナレッジ作成結果のレポート')
        public String report;
    }
}
