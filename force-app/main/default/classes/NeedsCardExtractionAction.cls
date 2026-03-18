public with sharing class NeedsCardExtractionAction {

    @InvocableMethod(label='ニーズカード抽出' description='面談記録からニーズカードを抽出する')
    public static List<ExtractionResult> extractNeeds(List<ExtractionInput> inputs) {
        List<ExtractionResult> results = new List<ExtractionResult>();
        for (ExtractionInput input : inputs) {
            results.add(processExtraction(input.meetingRecordId));
        }
        return results;
    }

    public class ExtractionInput {
        @InvocableVariable(required=true label='面談記録ID')
        public Id meetingRecordId;
    }

    public class ExtractionResult {
        @InvocableVariable(label='結果メッセージ')
        public String resultMessage;
        @InvocableVariable(label='新規作成数')
        public Integer createdCount;
        @InvocableVariable(label='統合数')
        public Integer mergedCount;
        @InvocableVariable(label='スキップ数')
        public Integer skippedCount;
        @InvocableVariable(label='エラー')
        public String errorMessage;
    }

    private static ExtractionResult processExtraction(Id meetingRecordId) {
        ExtractionResult result = new ExtractionResult();
        result.createdCount = 0;
        result.mergedCount = 0;
        result.skippedCount = 0;

        try {
            // 1. 面談記録を取得
            Meeting_Record__c meeting = [
                SELECT Id, Name, Account__c, Account__r.Name,
                       Account__r.RecordType.Name, Account__r.Type, Account__r.Industry,
                       Opportunity__c, Opportunity__r.Name, Opportunity__r.Amount, Opportunity__r.Business_Unit__c,
                       Meeting_Date__c, Meeting_Type__c, Participants__c,
                       Summary__c, Transcript__c, Needs_Extracted__c
                FROM Meeting_Record__c
                WHERE Id = :meetingRecordId
                LIMIT 1
            ];

            if (meeting.Account__c == null) {
                result.errorMessage = '取引先が設定されていません。';
                return result;
            }

            String meetingContent = meeting.Summary__c;
            if (String.isNotBlank(meeting.Transcript__c)) {
                meetingContent += '\n\n--- 文字起こし ---\n' + meeting.Transcript__c;
            }
            if (String.isBlank(meetingContent)) {
                result.errorMessage = '面談サマリーまたは文字起こしが空です。';
                return result;
            }

            // 2. 同一顧客の既存ニーズカードを取得
            List<Needs_Card__c> existingCards = [
                SELECT Id, Name, Title__c, Need_Type__c,
                       Product__c, Product__r.Name, Description__c,
                       Customer_Voice__c, Priority__c, Status__c,
                       Business_Impact__c, Impact_Source__c
                FROM Needs_Card__c
                WHERE Account__c = :meeting.Account__c
                  AND Status__c != '却下'
                ORDER BY CreatedDate DESC
                LIMIT 50
            ];

            // 3. 商談関連の金額情報を取得（Amount がnullの場合はRevenue_Forecastから）
            Decimal opportunityImpact = null;
            String impactSourceText = null;
            if (meeting.Opportunity__c != null) {
                if (meeting.Opportunity__r.Amount != null) {
                    opportunityImpact = meeting.Opportunity__r.Amount;
                    impactSourceText = '商談「' + meeting.Opportunity__r.Name + '」の金額';
                } else {
                    // Revenue_Forecast__c から加重金額合計を取得
                    AggregateResult[] forecasts = [
                        SELECT SUM(Forecast_Amount__c) totalAmount
                        FROM Revenue_Forecast__c
                        WHERE Opportunity__c = :meeting.Opportunity__c
                          AND Status__c = '予測中'
                    ];
                    if (!forecasts.isEmpty() && forecasts[0].get('totalAmount') != null) {
                        opportunityImpact = (Decimal) forecasts[0].get('totalAmount');
                        impactSourceText = '商談「' + meeting.Opportunity__r.Name + '」のRevenue Forecast合計';
                    }
                }
            }

            // 4. 利用可能な製品名一覧を取得
            List<Product2> products = [
                SELECT Id, Name FROM Product2
                WHERE IsActive = true
                ORDER BY Name
            ];

            // 5. コンテキスト情報を構築
            String contextInfo = buildContextInfo(meeting, existingCards, products, opportunityImpact, impactSourceText);

            // 6. Prompt Template を呼び出し
            String llmResponse = callPromptTemplate(contextInfo);

            // 7. レスポンスをパースしてDML実行
            processLLMResponse(llmResponse, meeting, existingCards, products, opportunityImpact, impactSourceText, result);

            // 8. 面談記録の抽出済みフラグを更新
            meeting.Needs_Extracted__c = true;
            update meeting;

            Integer total = result.createdCount + result.mergedCount + result.skippedCount;
            result.resultMessage = '抽出完了: ' + result.createdCount + '件新規作成、'
                + result.mergedCount + '件統合、' + result.skippedCount + '件スキップ（計' + total + '件検出）';

        } catch (Exception e) {
            result.errorMessage = e.getMessage();
        }
        return result;
    }

    private static String buildContextInfo(Meeting_Record__c meeting, List<Needs_Card__c> existingCards,
                                            List<Product2> products, Decimal opportunityImpact, String impactSourceText) {
        String info = '## 面談情報\n';
        info += '- 顧客名: ' + meeting.Account__r.Name + '\n';
        info += '- 面談日: ' + String.valueOf(meeting.Meeting_Date__c) + '\n';
        info += '- 種別: ' + (meeting.Meeting_Type__c != null ? meeting.Meeting_Type__c : '不明') + '\n';
        if (meeting.Opportunity__c != null) {
            info += '- 関連商談: ' + meeting.Opportunity__r.Name + '\n';
            if (opportunityImpact != null) {
                info += '- 商談関連金額: ¥' + String.valueOf(opportunityImpact.longValue()) + '（' + impactSourceText + '）\n';
            }
        }
        info += '- 参加者:\n' + (meeting.Participants__c != null ? meeting.Participants__c : '不明') + '\n';
        info += '\n## 面談内容\n';
        info += meeting.Summary__c != null ? meeting.Summary__c : '';
        if (String.isNotBlank(meeting.Transcript__c)) {
            String transcript = meeting.Transcript__c;
            if (transcript.length() > 30000) {
                transcript = transcript.substring(0, 30000) + '\n...(以下省略)';
            }
            info += '\n\n## 文字起こし\n' + transcript;
        }

        // 製品名一覧（日本語のもののみ抽出してサイズ削減）
        info += '\n\n## 自社製品一覧（productNameはこの中から正確に選択すること）\n';
        for (Product2 p : products) {
            // 日本語名またはカスタム製品名のみ表示（SDOデモデータを除外）
            if (containsJapanese(p.Name) || p.Name.contains('EnerCharge') || p.Name.contains('SolarMax')) {
                info += '- ' + p.Name + '\n';
            }
        }

        if (!existingCards.isEmpty()) {
            info += '\n## 既存ニーズカード（同一顧客: ' + existingCards.size() + '件）\n';
            info += '★重要: 以下のカードと意味的に同じニーズが面談に含まれている場合は、必ずmergeを使い、新規作成しないこと。\n\n';
            for (Needs_Card__c card : existingCards) {
                info += '### [' + card.Name + '] ' + card.Title__c + '\n';
                info += '- ニーズ種別: ' + (card.Need_Type__c != null ? card.Need_Type__c : '未設定') + '\n';
                info += '- 優先度: ' + (card.Priority__c != null ? card.Priority__c : '未設定') + '\n';
                info += '- ステータス: ' + (card.Status__c != null ? card.Status__c : '未設定') + '\n';
                if (card.Product__r != null && card.Product__r.Name != null) {
                    info += '- 関連製品: ' + card.Product__r.Name + '\n';
                }
                info += '- 詳細: ' + (card.Description__c != null ? card.Description__c : '') + '\n\n';
            }
        } else {
            info += '\n## 既存ニーズカード\nなし（この顧客のニーズカードは初めてです）\n';
        }

        return info;
    }

    private static Boolean containsJapanese(String text) {
        if (text == null) return false;
        // Hiragana U+3040-309F, Katakana U+30A0-30FF, CJK U+4E00-9FFF
        Pattern jp = Pattern.compile('[\\u3040-\\u309F\\u30A0-\\u30FF\\u4E00-\\u9FFF]');
        return jp.matcher(text).find();
    }

    private static String callPromptTemplate(String contextInfo) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;

        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
        wv.value = contextInfo;
        inputParams.put('Input:meetingContext', wv);
        input.inputParams = inputParams;

        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptBuilderPreview';
        input.additionalConfig.temperature = 0.3;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                'NeedsCardExtraction', input
            );

        if (response.generations == null || response.generations.isEmpty()) {
            throw new NeedsCardException('Prompt Templateからの応答が空です。テンプレートがActivateされているか確認してください。');
        }

        return ((ConnectApi.EinsteinLLMGenerationItemOutput) response.generations[0]).text;
    }

    private static void processLLMResponse(String llmResponse, Meeting_Record__c meeting,
                                            List<Needs_Card__c> existingCards, List<Product2> products,
                                            Decimal opportunityImpact, String impactSourceText,
                                            ExtractionResult result) {
        // JSONブロックを抽出
        String jsonStr = extractJsonFromResponse(llmResponse);
        if (jsonStr == null) {
            throw new NeedsCardException('LLMレスポンスからJSONを抽出できませんでした。\n応答: ' + llmResponse.left(500));
        }

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
        List<Object> needs = (List<Object>) parsed.get('needs');
        if (needs == null || needs.isEmpty()) {
            result.skippedCount = 0;
            result.resultMessage = 'ニーズは検出されませんでした。';
            return;
        }

        // 既存カードのMapを作成
        Map<String, Needs_Card__c> cardByName = new Map<String, Needs_Card__c>();
        for (Needs_Card__c card : existingCards) {
            cardByName.put(card.Name, card);
        }

        // 製品名→ID のマップを構築（完全一致 + 部分一致用）
        Map<String, Id> productExactMap = new Map<String, Id>();
        List<Product2> allProducts = products;
        for (Product2 p : allProducts) {
            productExactMap.put(p.Name, p.Id);
        }

        List<Needs_Card__c> toInsert = new List<Needs_Card__c>();
        List<Needs_Card__c> toUpdate = new List<Needs_Card__c>();
        List<Needs_Card_Source__c> sourcesForMerge = new List<Needs_Card_Source__c>();

        for (Object n : needs) {
            Map<String, Object> need = (Map<String, Object>) n;
            String action = (String) need.get('action');

            if (action == 'skip') {
                result.skippedCount++;
                continue;
            }

            if (action == 'merge') {
                String existingCardName = (String) need.get('existingCardName');
                Needs_Card__c existing = cardByName.get(existingCardName);
                if (existing == null) {
                    // 既存カードが見つからない場合は新規作成にフォールバック
                    action = 'new';
                } else {
                    // 既存カードに追記
                    String additionalInfo = (String) need.get('additionalInfo');
                    if (String.isNotBlank(additionalInfo)) {
                        String currentDesc = existing.Description__c != null ? existing.Description__c : '';
                        existing.Description__c = currentDesc +
                            '\n\n【' + String.valueOf(meeting.Meeting_Date__c) + ' 面談で追加】\n' + additionalInfo;
                    }
                    String additionalVoice = (String) need.get('customerVoice');
                    if (String.isNotBlank(additionalVoice)) {
                        String currentVoice = existing.Customer_Voice__c != null ? existing.Customer_Voice__c : '';
                        existing.Customer_Voice__c = currentVoice +
                            '\n\n【' + String.valueOf(meeting.Meeting_Date__c) + '】\n' + additionalVoice;
                    }
                    // 優先度が上がる場合は更新
                    String newPriority = (String) need.get('priority');
                    if (newPriority == '高' && existing.Priority__c != '高') {
                        existing.Priority__c = '高';
                    }
                    // ビジネスインパクト: 大きい方で上書き
                    if (opportunityImpact != null) {
                        Decimal currentImpact = existing.Business_Impact__c != null ? existing.Business_Impact__c : 0;
                        if (opportunityImpact > currentImpact) {
                            existing.Business_Impact__c = opportunityImpact;
                            existing.Impact_Source__c = impactSourceText;
                        }
                    }
                    toUpdate.add(existing);
                    // ソース面談レコードを追加
                    sourcesForMerge.add(new Needs_Card_Source__c(
                        Needs_Card__c = existing.Id,
                        Meeting_Record__c = meeting.Id
                    ));
                    result.mergedCount++;
                    continue;
                }
            }

            if (action == 'new') {
                Needs_Card__c newCard = new Needs_Card__c();
                newCard.Account__c = meeting.Account__c;
                newCard.Title__c = (String) need.get('title');
                newCard.Need_Type__c = (String) need.get('needType');
                // 取引先の分類情報を転記
                if (meeting.Account__r.RecordType != null) {
                    newCard.Account_Record_Type__c = meeting.Account__r.RecordType.Name;
                }
                newCard.Account_Type__c = meeting.Account__r.Type;
                newCard.Account_Industry__c = meeting.Account__r.Industry;
                if (meeting.Opportunity__c != null && meeting.Opportunity__r.Business_Unit__c != null) {
                    newCard.Business_Unit__c = meeting.Opportunity__r.Business_Unit__c;
                }
                newCard.Description__c = (String) need.get('description');
                newCard.Customer_Voice__c = (String) need.get('customerVoice');
                newCard.Priority__c = (String) need.get('priority');
                newCard.Status__c = '新規';
                newCard.Source_Meeting__c = meeting.Id;
                if (meeting.Opportunity__c != null) {
                    newCard.Source_Opportunity__c = meeting.Opportunity__c;
                }
                // ビジネスインパクト: LLMが指定した値 > 商談/Forecast金額 > null
                Object impactObj = need.get('businessImpact');
                if (impactObj != null) {
                    if (impactObj instanceof Decimal) {
                        newCard.Business_Impact__c = (Decimal) impactObj;
                    } else if (impactObj instanceof Integer) {
                        newCard.Business_Impact__c = Decimal.valueOf((Integer) impactObj);
                    } else if (impactObj instanceof Long) {
                        newCard.Business_Impact__c = Decimal.valueOf((Long) impactObj);
                    }
                    String impactSrc = (String) need.get('impactSource');
                    if (String.isNotBlank(impactSrc)) {
                        newCard.Impact_Source__c = impactSrc;
                    }
                } else if (opportunityImpact != null) {
                    newCard.Business_Impact__c = opportunityImpact;
                    newCard.Impact_Source__c = impactSourceText;
                }
                // 製品紐付け: 完全一致 → 部分一致フォールバック
                String prodName = (String) need.get('productName');
                if (String.isNotBlank(prodName)) {
                    if (productExactMap.containsKey(prodName)) {
                        newCard.Product__c = productExactMap.get(prodName);
                    } else {
                        // 部分一致: LLMが返した名前を含む製品、または製品名を含むLLM名
                        Id matchedId = findProductByPartialMatch(prodName, allProducts);
                        if (matchedId != null) {
                            newCard.Product__c = matchedId;
                        }
                    }
                }
                toInsert.add(newCard);
                result.createdCount++;
            }
        }

        if (!toInsert.isEmpty()) {
            insert toInsert;
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
        // ソース面談レコードを作成（新規カード分 + merge分）
        List<Needs_Card_Source__c> allSources = new List<Needs_Card_Source__c>();
        for (Needs_Card__c card : toInsert) {
            allSources.add(new Needs_Card_Source__c(
                Needs_Card__c = card.Id,
                Meeting_Record__c = meeting.Id
            ));
        }
        allSources.addAll(sourcesForMerge);
        if (!allSources.isEmpty()) {
            insert allSources;
        }
    }

    private static Id findProductByPartialMatch(String searchName, List<Product2> products) {
        String lowerSearch = searchName.toLowerCase();
        // 製品名がLLM出力に含まれる、またはLLM出力が製品名に含まれる
        for (Product2 p : products) {
            String lowerProd = p.Name.toLowerCase();
            if (lowerProd.contains(lowerSearch) || lowerSearch.contains(lowerProd)) {
                return p.Id;
            }
        }
        // キーワードベースのフォールバック（「電源」→「パワーインバーター」等）
        Map<String, String> keywordMap = new Map<String, String>{
            '電源' => 'パワーインバーター',
            'インバーター' => 'パワーインバーター',
            'チャージコントローラー' => 'ソーラーチャージコントローラー',
            'コントローラー' => 'ソーラーチャージコントローラー',
            'ソーラーパネル' => 'ソーラーパネル',
            'パネル' => 'ソーラーパネル',
            '蓄電' => 'EnerCharge Pro 蓄電システム',
            'バッテリー' => '高容量リチウムイオン電池',
            'リチウム' => '高容量リチウムイオン電池',
            '架台' => '架台システム',
            '風力' => '小型風力タービン',
            'EV充電' => 'ソーラーEV充電ステーション',
            '充電ステーション' => 'ソーラーEV充電ステーション'
        };
        for (String keyword : keywordMap.keySet()) {
            if (lowerSearch.contains(keyword.toLowerCase())) {
                String targetName = keywordMap.get(keyword);
                for (Product2 p : products) {
                    if (p.Name == targetName) {
                        return p.Id;
                    }
                }
            }
        }
        return null;
    }

    private static String extractJsonFromResponse(String response) {
        Integer jsonStart = response.indexOf('```json');
        if (jsonStart >= 0) {
            jsonStart = response.indexOf('\n', jsonStart) + 1;
            Integer jsonEnd = response.indexOf('```', jsonStart);
            if (jsonEnd > jsonStart) {
                return response.substring(jsonStart, jsonEnd).trim();
            }
        }
        jsonStart = response.indexOf('```');
        if (jsonStart >= 0) {
            jsonStart = response.indexOf('\n', jsonStart) + 1;
            Integer jsonEnd = response.indexOf('```', jsonStart);
            if (jsonEnd > jsonStart) {
                String candidate = response.substring(jsonStart, jsonEnd).trim();
                if (candidate.startsWith('{')) return candidate;
            }
        }
        jsonStart = response.indexOf('{');
        if (jsonStart >= 0) {
            Integer jsonEnd = response.lastIndexOf('}');
            if (jsonEnd > jsonStart) {
                return response.substring(jsonStart, jsonEnd + 1);
            }
        }
        return null;
    }

    public class NeedsCardException extends Exception {}
}
