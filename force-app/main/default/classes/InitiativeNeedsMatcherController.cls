public with sharing class InitiativeNeedsMatcherController {

    private static final String CARD_FIELDS =
        'Id, Name, Title__c, Need_Type__c, Priority__c, ' +
        'Account__r.Name, Product__c, Product__r.Name, Product__r.Family, ' +
        'Business_Impact__c, Description__c, Customer_Voice__c, CreatedDate';

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getCandidateNeeds(Id initiativeId) {
        Product_Initiative__c initiative = [
            SELECT Id, Name, Title__c, What_Description__c, Why_Rationale__c,
                   Product__c, Product__r.Name, Product__r.Family, Status__c, Priority__c
            FROM Product_Initiative__c
            WHERE Id = :initiativeId
        ];

        Set<Id> linkedIds = new Set<Id>();
        for (Initiative_Need__c ineed : [
            SELECT Needs_Card__c FROM Initiative_Need__c WHERE Initiative__c = :initiativeId
        ]) {
            linkedIds.add(ineed.Needs_Card__c);
        }

        Id productId = initiative.Product__c;

        // Tier 1: 同一製品の完全一致（関連度: 高）
        Map<Id, Needs_Card__c> highRelevance = new Map<Id, Needs_Card__c>();
        if (productId != null) {
            for (Needs_Card__c c : Database.query(
                'SELECT ' + CARD_FIELDS + ' FROM Needs_Card__c ' +
                'WHERE Product__c = :productId AND Status__c != \'却下\'' +
                (linkedIds.isEmpty() ? '' : ' AND Id NOT IN :linkedIds') +
                ' ORDER BY Priority__c, CreatedDate DESC LIMIT 30'
            )) {
                highRelevance.put(c.Id, c);
            }
        }

        // Tier 2: SOSLキーワード検索（関連度: 中）
        Map<Id, Needs_Card__c> midRelevance = new Map<Id, Needs_Card__c>();
        List<String> keywords = extractKeywords(initiative);
        if (!keywords.isEmpty()) {
            String searchTerm = String.join(keywords, ' OR ');
            // SOSLクエリ
            String soslQuery = 'FIND \'' + String.escapeSingleQuotes(searchTerm) + '\' IN ALL FIELDS ' +
                'RETURNING Needs_Card__c(' + CARD_FIELDS +
                ' WHERE Status__c != \'却下\'' +
                (linkedIds.isEmpty() ? '' : ' AND Id NOT IN :linkedIds') +
                ' ORDER BY Priority__c, CreatedDate DESC LIMIT 40)';
            List<List<SObject>> searchResults = Search.query(soslQuery);
            if (!searchResults.isEmpty()) {
                for (SObject so : searchResults[0]) {
                    Needs_Card__c c = (Needs_Card__c) so;
                    if (!highRelevance.containsKey(c.Id)) {
                        midRelevance.put(c.Id, c);
                    }
                }
            }
        }

        // 結果を統合（高→中の順）
        List<Map<String, Object>> candList = new List<Map<String, Object>>();
        for (Needs_Card__c c : highRelevance.values()) {
            candList.add(buildCardMap(c, '高'));
        }
        for (Needs_Card__c c : midRelevance.values()) {
            candList.add(buildCardMap(c, '中'));
        }

        Map<String, Object> result = new Map<String, Object>();
        result.put('initiative', buildInitiativeMap(initiative));
        result.put('linkedCount', linkedIds.size());
        result.put('candidates', candList);
        return result;
    }

    @AuraEnabled
    public static String analyzeRelevance(Id initiativeId) {
        Product_Initiative__c initiative = [
            SELECT Id, Name, Title__c, What_Description__c, Why_Rationale__c,
                   Product__c, Product__r.Name, Product__r.Family
            FROM Product_Initiative__c WHERE Id = :initiativeId
        ];

        Set<Id> linkedIds = new Set<Id>();
        for (Initiative_Need__c ineed : [
            SELECT Needs_Card__c FROM Initiative_Need__c WHERE Initiative__c = :initiativeId
        ]) {
            linkedIds.add(ineed.Needs_Card__c);
        }

        // 同じ複合検索ロジックで候補取得
        Id productId = initiative.Product__c;
        Map<Id, Needs_Card__c> allCandidates = new Map<Id, Needs_Card__c>();

        if (productId != null) {
            for (Needs_Card__c c : Database.query(
                'SELECT ' + CARD_FIELDS + ' FROM Needs_Card__c ' +
                'WHERE Product__c = :productId AND Status__c != \'却下\'' +
                (linkedIds.isEmpty() ? '' : ' AND Id NOT IN :linkedIds') +
                ' ORDER BY Priority__c, CreatedDate DESC LIMIT 20'
            )) {
                allCandidates.put(c.Id, c);
            }
        }

        List<String> keywords = extractKeywords(initiative);
        if (!keywords.isEmpty()) {
            String searchTerm = String.join(keywords, ' OR ');
            String soslQuery = 'FIND \'' + String.escapeSingleQuotes(searchTerm) + '\' IN ALL FIELDS ' +
                'RETURNING Needs_Card__c(' + CARD_FIELDS +
                ' WHERE Status__c != \'却下\'' +
                (linkedIds.isEmpty() ? '' : ' AND Id NOT IN :linkedIds') +
                ' ORDER BY Priority__c, CreatedDate DESC LIMIT 20)';
            List<List<SObject>> searchResults = Search.query(soslQuery);
            if (!searchResults.isEmpty()) {
                for (SObject so : searchResults[0]) {
                    Needs_Card__c c = (Needs_Card__c) so;
                    if (!allCandidates.containsKey(c.Id)) {
                        allCandidates.put(c.Id, c);
                    }
                }
            }
        }

        if (allCandidates.isEmpty()) {
            return '関連する未紐付けのニーズカードはありません。';
        }

        // Build context
        String ctx = '## 施策情報\n';
        ctx += '- タイトル: ' + initiative.Title__c + '\n';
        ctx += '- 製品: ' + (initiative.Product__r != null ? initiative.Product__r.Name : 'N/A') + '\n';
        if (initiative.What_Description__c != null) {
            ctx += '- 概要: ' + initiative.What_Description__c + '\n';
        }
        if (initiative.Why_Rationale__c != null) {
            ctx += '- 根拠: ' + initiative.Why_Rationale__c + '\n';
        }
        ctx += '\n## 候補ニーズカード (' + allCandidates.size() + '件)\n\n';

        for (Needs_Card__c c : allCandidates.values()) {
            ctx += '### ' + c.Name + ': ' + c.Title__c + '\n';
            ctx += '- 顧客: ' + (c.Account__r != null ? c.Account__r.Name : '不明') + '\n';
            ctx += '- 種別: ' + (c.Need_Type__c != null ? c.Need_Type__c : '未設定') + '\n';
            if (c.Business_Impact__c != null) {
                ctx += '- 金額規模: ¥' + String.valueOf(c.Business_Impact__c.longValue()) + '\n';
            }
            if (c.Description__c != null) {
                String descText = c.Description__c.length() > 200 ? c.Description__c.substring(0, 200) + '...' : c.Description__c;
                ctx += '- 詳細: ' + descText + '\n';
            }
            if (c.Customer_Voice__c != null) {
                String voice = c.Customer_Voice__c.length() > 100 ? c.Customer_Voice__c.substring(0, 100) + '...' : c.Customer_Voice__c;
                ctx += '- 顧客の声: ' + voice + '\n';
            }
            ctx += '\n';
        }

        return callPromptTemplate(ctx);
    }

    @AuraEnabled
    public static Id linkNeeds(Id initiativeId, List<Id> needsCardIds) {
        List<Initiative_Need__c> records = new List<Initiative_Need__c>();
        for (Id cardId : needsCardIds) {
            records.add(new Initiative_Need__c(
                Initiative__c = initiativeId,
                Needs_Card__c = cardId
            ));
        }
        insert records;
        return initiativeId;
    }

    // --- キーワード抽出 ---

    private static List<String> extractKeywords(Product_Initiative__c initiative) {
        Set<String> words = new Set<String>();
        // タイトルから抽出
        if (initiative.Title__c != null) {
            for (String w : splitToWords(initiative.Title__c)) {
                words.add(w);
            }
        }
        // 製品名から抽出
        if (initiative.Product__r != null && initiative.Product__r.Name != null) {
            for (String w : splitToWords(initiative.Product__r.Name)) {
                words.add(w);
            }
        }
        // What_Descriptionから主要ワード抽出（先頭200文字）
        if (initiative.What_Description__c != null) {
            String whatText = initiative.What_Description__c.length() > 200
                ? initiative.What_Description__c.substring(0, 200)
                : initiative.What_Description__c;
            for (String w : splitToWords(whatText)) {
                words.add(w);
            }
        }
        // ストップワード除去
        words.removeAll(getStopWords());
        // SOSLは最大文字数制限があるため上位10ワードに絞る
        List<String> result = new List<String>(words);
        if (result.size() > 10) {
            List<String> trimmed = new List<String>();
            for (Integer i = 0; i < 10; i++) {
                trimmed.add(result[i]);
            }
            return trimmed;
        }
        return result;
    }

    private static List<String> splitToWords(String text) {
        List<String> words = new List<String>();
        if (text == null) return words;
        // 記号・句読点で分割し、2文字以上の単語を採用
        for (String w : text.split('[\\s,、。・（）()「」/\\-：:×%]+')) {
            String trimmed = w.trim();
            if (trimmed.length() >= 2) {
                words.add(trimmed);
            }
        }
        return words;
    }

    private static Set<String> getStopWords() {
        return new Set<String>{
            'する', 'した', 'して', 'させる', 'おける', 'について',
            'から', 'まで', 'により', 'による', 'および', 'ため',
            'もの', 'こと', 'これ', 'それ', 'ある', 'ない',
            'できる', 'なる', 'いる', 'れる', '行う', '含む',
            '向け', '向上', '実現', '達成', '対応', '開発',
            '新規', '既存', '現行', '次世代'
        };
    }

    // --- ヘルパー ---

    private static Map<String, Object> buildCardMap(Needs_Card__c c, String relevance) {
        Map<String, Object> m = new Map<String, Object>();
        m.put('id', c.Id);
        m.put('name', c.Name);
        m.put('title', c.Title__c);
        m.put('needType', c.Need_Type__c);
        m.put('priority', c.Priority__c);
        m.put('relevance', relevance);
        m.put('account', c.Account__r != null ? c.Account__r.Name : '');
        m.put('product', c.Product__r != null ? c.Product__r.Name : '');
        m.put('impact', c.Business_Impact__c);
        m.put('description', c.Description__c != null ?
            (c.Description__c.length() > 150 ? c.Description__c.substring(0, 150) + '...' : c.Description__c) : '');
        m.put('voice', c.Customer_Voice__c != null ?
            (c.Customer_Voice__c.length() > 100 ? c.Customer_Voice__c.substring(0, 100) + '...' : c.Customer_Voice__c) : '');
        return m;
    }

    private static Map<String, Object> buildInitiativeMap(Product_Initiative__c pi) {
        Map<String, Object> m = new Map<String, Object>();
        m.put('name', pi.Name);
        m.put('title', pi.Title__c);
        m.put('what', pi.What_Description__c);
        m.put('why', pi.Why_Rationale__c);
        m.put('product', pi.Product__r != null ? pi.Product__r.Name : '');
        m.put('family', pi.Product__r != null ? pi.Product__r.Family : '');
        m.put('status', pi.Status__c);
        m.put('priority', pi.Priority__c);
        return m;
    }

    private static String callPromptTemplate(String context) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput input =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptBuilderPreview';
        input.additionalConfig.temperature = 0.2;

        Map<String, ConnectApi.WrappedValue> inputParams =
            new Map<String, ConnectApi.WrappedValue>();
        ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
        wv.value = context;
        inputParams.put('Input:analysisData', wv);
        input.inputParams = inputParams;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                'InitiativeNeedsRelevance', input
            );

        if (response.generations == null || response.generations.isEmpty()) {
            throw new AuraHandledException('AI応答が空です。テンプレートがActivateされているか確認してください。');
        }

        return ((ConnectApi.EinsteinLLMGenerationItemOutput) response.generations[0]).text;
    }
}
