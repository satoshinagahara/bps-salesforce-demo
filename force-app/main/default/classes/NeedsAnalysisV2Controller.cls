public with sharing class NeedsAnalysisV2Controller {

    private static final Integer FRESH_MONTHS = 3;
    private static final Integer AGING_MONTHS = 6;

    private static final String SELECT_FIELDS =
        'Id, Name, Title__c, Need_Type__c, Priority__c, Account__r.Name, ' +
        'Account_Industry__c, Business_Unit__c, Business_Impact__c, ' +
        'Description__c, Customer_Voice__c, Product__r.Name, Product__r.Family, CreatedDate';

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getAnalysisData(Integer monthsBack, String segment) {
        Map<String, Object> result = new Map<String, Object>();

        List<Needs_Card__c> cards = [
            SELECT Id, Name, Title__c, Need_Type__c, Priority__c, Status__c,
                   Account__c, Account__r.Name, Account_Record_Type__c,
                   Account_Type__c, Account_Industry__c, Business_Unit__c,
                   Business_Impact__c, Product__c, Product__r.Name, Product__r.Family,
                   Description__c, Customer_Voice__c, CreatedDate
            FROM Needs_Card__c
            WHERE Status__c != '却下'
            ORDER BY CreatedDate DESC
        ];

        // セグメント一覧を動的に収集
        Set<String> segmentSet = new Set<String>();
        for (Needs_Card__c c : cards) {
            String rt = c.Account_Record_Type__c;
            segmentSet.add(rt != null ? rt : '未分類');
        }
        List<String> segments = new List<String>(segmentSet);
        segments.sort();
        result.put('segments', segments);

        // セグメントフィルタ（Account_Record_Type__c の値でフィルタ）
        if (String.isNotBlank(segment) && segment != 'all') {
            List<Needs_Card__c> segFiltered = new List<Needs_Card__c>();
            for (Needs_Card__c c : cards) {
                String rt = c.Account_Record_Type__c != null ? c.Account_Record_Type__c : '未分類';
                if (rt == segment) {
                    segFiltered.add(c);
                }
            }
            cards = segFiltered;
        }

        // 最終言及日マップ
        Map<Id, Date> lastMentionedMap = getLastMentionedDates(cards);

        Date today = Date.today();
        Date freshBoundary = today.addMonths(-FRESH_MONTHS);
        Date agingBoundary = today.addMonths(-AGING_MONTHS);
        Date timeFilterBoundary = (monthsBack != null && monthsBack > 0)
            ? today.addMonths(-monthsBack) : null;

        // 時間フィルタ適用
        List<Needs_Card__c> filtered = new List<Needs_Card__c>();
        for (Needs_Card__c card : cards) {
            Date lm = lastMentionedMap.containsKey(card.Id)
                ? lastMentionedMap.get(card.Id)
                : card.CreatedDate.date();
            if (timeFilterBoundary == null || lm >= timeFilterBoundary) {
                filtered.add(card);
            }
        }

        result.put('totalCount', filtered.size());

        // --- 集計変数 ---
        // 単軸: 製品Family
        Map<String, Integer> byProductFamily = new Map<String, Integer>();
        Map<String, Decimal> impactByProductFamily = new Map<String, Decimal>();
        Map<String, Map<String, Integer>> productFamilyFreshness = new Map<String, Map<String, Integer>>();

        // クロス: 製品Family × ニーズ種別
        Map<String, Integer> byProductNeedType = new Map<String, Integer>();
        Map<String, Decimal> impactByProductNeedType = new Map<String, Decimal>();

        // クロス: 製品Family × 業種
        Map<String, Integer> byProductIndustry = new Map<String, Integer>();
        Map<String, Decimal> impactByProductIndustry = new Map<String, Decimal>();

        // クロス: 業種 × ニーズ種別
        Map<String, Integer> byIndustryNeedType = new Map<String, Integer>();
        Map<String, Decimal> impactByIndustryNeedType = new Map<String, Decimal>();

        // 顧客別
        Map<String, Integer> byAccount = new Map<String, Integer>();
        Map<String, Decimal> impactByAccount = new Map<String, Decimal>();
        Map<String, Map<String, Integer>> accountFreshness = new Map<String, Map<String, Integer>>();

        Decimal totalImpact = 0;
        Integer highPriorityCount = 0;
        Integer freshCount = 0;
        Integer agingCount = 0;
        Integer staleCount = 0;

        for (Needs_Card__c card : filtered) {
            Date lastMentioned = lastMentionedMap.containsKey(card.Id)
                ? lastMentionedMap.get(card.Id)
                : card.CreatedDate.date();
            String freshness;
            if (lastMentioned >= freshBoundary) {
                freshness = 'fresh';
                freshCount++;
            } else if (lastMentioned >= agingBoundary) {
                freshness = 'aging';
                agingCount++;
            } else {
                freshness = 'stale';
                staleCount++;
            }

            String priority = card.Priority__c != null ? card.Priority__c : '未設定';
            if (priority == '高') highPriorityCount++;

            Decimal impact = card.Business_Impact__c != null ? card.Business_Impact__c : 0;
            totalImpact += impact;

            String family = (card.Product__r != null && card.Product__r.Family != null)
                ? card.Product__r.Family : '未分類';
            String needType = card.Need_Type__c != null ? card.Need_Type__c : '未分類';
            String industry = card.Account_Industry__c != null ? card.Account_Industry__c : '未分類';
            String accountName = (card.Account__r != null && card.Account__r.Name != null)
                ? card.Account__r.Name : '不明';

            // 製品Family (単軸)
            incrementMap(byProductFamily, family);
            addDecimalMap(impactByProductFamily, family, impact);
            addFreshness(productFamilyFreshness, family, freshness);

            // 製品Family × ニーズ種別
            String pnKey = family + '|' + needType;
            incrementMap(byProductNeedType, pnKey);
            addDecimalMap(impactByProductNeedType, pnKey, impact);

            // 製品Family × 業種
            String piKey = family + '|' + industry;
            incrementMap(byProductIndustry, piKey);
            addDecimalMap(impactByProductIndustry, piKey, impact);

            // 業種 × ニーズ種別
            String inKey = industry + '|' + needType;
            incrementMap(byIndustryNeedType, inKey);
            addDecimalMap(impactByIndustryNeedType, inKey, impact);

            // 顧客別
            incrementMap(byAccount, accountName);
            addDecimalMap(impactByAccount, accountName, impact);
            addFreshness(accountFreshness, accountName, freshness);
        }

        // 結果格納
        result.put('totalImpact', totalImpact);
        result.put('highPriorityCount', highPriorityCount);
        result.put('freshCount', freshCount);
        result.put('agingCount', agingCount);
        result.put('staleCount', staleCount);

        result.put('byProductFamily', byProductFamily);
        result.put('impactByProductFamily', impactByProductFamily);
        result.put('productFamilyFreshness', flattenFreshness(productFamilyFreshness));

        result.put('byProductNeedType', byProductNeedType);
        result.put('impactByProductNeedType', impactByProductNeedType);

        result.put('byProductIndustry', byProductIndustry);
        result.put('impactByProductIndustry', impactByProductIndustry);

        result.put('byIndustryNeedType', byIndustryNeedType);
        result.put('impactByIndustryNeedType', impactByIndustryNeedType);

        result.put('byAccount', byAccount);
        result.put('impactByAccount', impactByAccount);
        result.put('accountFreshness', flattenFreshness(accountFreshness));

        return result;
    }

    // --- analyzeSegment ---

    @AuraEnabled
    public static String analyzeSegment(String filterType, String filterValue) {
        List<Needs_Card__c> cards;
        String filterLabel;

        if (filterType == 'productFamily') {
            cards = queryByProductFamily(filterValue);
            filterLabel = '製品ファミリー「' + filterValue + '」';

        } else if (filterType == 'productNeedType') {
            String[] parts = filterValue.split('\\|');
            String family = parts[0];
            String needType = parts.size() > 1 ? parts[1] : '';
            cards = queryByCross('Product__r.Family', family, 'Need_Type__c', needType);
            filterLabel = '製品「' + family + '」× 種別「' + needType + '」';

        } else if (filterType == 'productIndustry') {
            String[] parts = filterValue.split('\\|');
            String family = parts[0];
            String industry = parts.size() > 1 ? parts[1] : '';
            cards = queryByCross('Product__r.Family', family, 'Account_Industry__c', industry);
            filterLabel = '製品「' + family + '」× 業種「' + industry + '」';

        } else if (filterType == 'industryNeedType') {
            String[] parts = filterValue.split('\\|');
            String industry = parts[0];
            String needType = parts.size() > 1 ? parts[1] : '';
            cards = queryByCross('Account_Industry__c', industry, 'Need_Type__c', needType);
            filterLabel = '業種「' + industry + '」× 種別「' + needType + '」';

        } else if (filterType == 'account') {
            cards = [SELECT Id, Name, Title__c, Need_Type__c, Priority__c, Account__r.Name,
                            Account_Industry__c, Business_Unit__c, Business_Impact__c,
                            Description__c, Customer_Voice__c, Product__r.Name, Product__r.Family,
                            CreatedDate
                     FROM Needs_Card__c
                     WHERE Account__r.Name = :filterValue AND Status__c != '却下'
                     ORDER BY Priority__c, CreatedDate DESC];
            filterLabel = '顧客「' + filterValue + '」';

        } else {
            throw new AuraHandledException('不正なフィルタタイプ: ' + filterType);
        }

        if (cards == null || cards.isEmpty()) {
            return '該当するニーズカードがありません。';
        }

        return callPromptTemplate(buildAnalysisContext(filterLabel, cards));
    }

    // --- クエリヘルパー ---

    private static List<Needs_Card__c> queryByProductFamily(String family) {
        if (family == '未分類') {
            return [SELECT Id, Name, Title__c, Need_Type__c, Priority__c, Account__r.Name,
                           Account_Industry__c, Business_Unit__c, Business_Impact__c,
                           Description__c, Customer_Voice__c, Product__r.Name, Product__r.Family, CreatedDate
                    FROM Needs_Card__c
                    WHERE (Product__c = null OR Product__r.Family = null) AND Status__c != '却下'
                    ORDER BY Priority__c, CreatedDate DESC];
        }
        return [SELECT Id, Name, Title__c, Need_Type__c, Priority__c, Account__r.Name,
                       Account_Industry__c, Business_Unit__c, Business_Impact__c,
                       Description__c, Customer_Voice__c, Product__r.Name, Product__r.Family, CreatedDate
                FROM Needs_Card__c
                WHERE Product__r.Family = :family AND Status__c != '却下'
                ORDER BY Priority__c, CreatedDate DESC];
    }

    private static List<Needs_Card__c> queryByCross(String field1, String val1, String field2, String val2) {
        // 動的SOQLで2軸フィルタ
        String soql = 'SELECT Id, Name, Title__c, Need_Type__c, Priority__c, Account__r.Name, ' +
            'Account_Industry__c, Business_Unit__c, Business_Impact__c, ' +
            'Description__c, Customer_Voice__c, Product__r.Name, Product__r.Family, CreatedDate ' +
            'FROM Needs_Card__c WHERE Status__c != \'却下\'';

        // field1
        if (val1 == '未分類') {
            if (field1 == 'Product__r.Family') {
                soql += ' AND (Product__c = null OR Product__r.Family = null)';
            } else {
                soql += ' AND ' + field1 + ' = null';
            }
        } else {
            soql += ' AND ' + field1 + ' = :val1';
        }
        // field2
        if (val2 == '未分類') {
            if (field2 == 'Product__r.Family') {
                soql += ' AND (Product__c = null OR Product__r.Family = null)';
            } else {
                soql += ' AND ' + field2 + ' = null';
            }
        } else {
            soql += ' AND ' + field2 + ' = :val2';
        }
        soql += ' ORDER BY Priority__c, CreatedDate DESC';
        return Database.query(soql);
    }

    // --- 集計ヘルパー ---

    private static void incrementMap(Map<String, Integer> m, String key) {
        m.put(key, (m.containsKey(key) ? m.get(key) : 0) + 1);
    }

    private static void addDecimalMap(Map<String, Decimal> m, String key, Decimal val) {
        m.put(key, (m.containsKey(key) ? m.get(key) : 0) + val);
    }

    private static Map<Id, Date> getLastMentionedDates(List<Needs_Card__c> cards) {
        Set<Id> cardIds = new Set<Id>();
        for (Needs_Card__c c : cards) {
            cardIds.add(c.Id);
        }
        Map<Id, Date> lastDates = new Map<Id, Date>();
        for (Needs_Card_Source__c src : [
            SELECT Needs_Card__c, Meeting_Record__r.Meeting_Date__c
            FROM Needs_Card_Source__c
            WHERE Needs_Card__c IN :cardIds
                AND Meeting_Record__r.Meeting_Date__c != null
            ORDER BY Meeting_Record__r.Meeting_Date__c DESC
        ]) {
            Id cardId = src.Needs_Card__c;
            Date meetingDate = src.Meeting_Record__r.Meeting_Date__c;
            if (!lastDates.containsKey(cardId) || meetingDate > lastDates.get(cardId)) {
                lastDates.put(cardId, meetingDate);
            }
        }
        return lastDates;
    }

    private static void addFreshness(Map<String, Map<String, Integer>> freshnessMap, String key, String freshness) {
        if (!freshnessMap.containsKey(key)) {
            freshnessMap.put(key, new Map<String, Integer>{ 'fresh' => 0, 'aging' => 0, 'stale' => 0 });
        }
        Map<String, Integer> counts = freshnessMap.get(key);
        counts.put(freshness, counts.get(freshness) + 1);
    }

    private static Map<String, Integer> flattenFreshness(Map<String, Map<String, Integer>> freshnessMap) {
        Map<String, Integer> flat = new Map<String, Integer>();
        for (String key : freshnessMap.keySet()) {
            Map<String, Integer> counts = freshnessMap.get(key);
            for (String f : counts.keySet()) {
                flat.put(key + '|' + f, counts.get(f));
            }
        }
        return flat;
    }

    // --- AI分析コンテキスト構築 ---

    private static final Integer MAX_CARDS_FOR_AI = 30;

    private static String buildAnalysisContext(String filterLabel, List<Needs_Card__c> cards) {
        // Vertex AI 直接呼出では入力トークン量がレイテンシに直結するため、
        // 最新のカードから上限30件に絞る（元クエリがCreatedDate DESC順）
        if (cards.size() > MAX_CARDS_FOR_AI) {
            List<Needs_Card__c> trimmed = new List<Needs_Card__c>();
            for (Integer i = 0; i < MAX_CARDS_FOR_AI; i++) {
                trimmed.add(cards[i]);
            }
            cards = trimmed;
        }
        Map<Id, Date> lastMentionedMap = getLastMentionedDates(cards);
        Date today = Date.today();
        Date freshBoundary = today.addMonths(-FRESH_MONTHS);
        Date agingBoundary = today.addMonths(-AGING_MONTHS);

        Integer freshCnt = 0, agingCnt = 0, staleCnt = 0;
        for (Needs_Card__c card : cards) {
            Date lm = lastMentionedMap.containsKey(card.Id) ? lastMentionedMap.get(card.Id) : card.CreatedDate.date();
            if (lm >= freshBoundary) freshCnt++;
            else if (lm >= agingBoundary) agingCnt++;
            else staleCnt++;
        }

        String ctx = '## 分析対象: ' + filterLabel + '\n';
        ctx += '## カード数: ' + cards.size() + '件\n';
        ctx += '## 鮮度: 直近3ヶ月=' + freshCnt + '件, 3〜6ヶ月=' + agingCnt + '件, 6ヶ月超=' + staleCnt + '件\n';
        ctx += '（鮮度=最後に面談で言及された日からの経過。鮮度が高いほど今も顧客が関心を持っている）\n\n';

        // ニーズに紐づく施策情報を取得
        Set<Id> cardIds = new Set<Id>();
        for (Needs_Card__c c : cards) {
            cardIds.add(c.Id);
        }
        Map<Id, List<Map<String, String>>> cardInitiatives = getRelatedInitiatives(cardIds);

        for (Needs_Card__c card : cards) {
            Date lastMentioned = lastMentionedMap.containsKey(card.Id)
                ? lastMentionedMap.get(card.Id)
                : card.CreatedDate.date();
            String freshnessLabel;
            if (lastMentioned >= freshBoundary) freshnessLabel = '直近3ヶ月';
            else if (lastMentioned >= agingBoundary) freshnessLabel = '3〜6ヶ月前';
            else freshnessLabel = '6ヶ月超';

            ctx += '### ' + card.Name + ': ' + card.Title__c + '\n';
            ctx += '- 顧客: ' + (card.Account__r != null ? card.Account__r.Name : '不明') + '\n';
            ctx += '- 種別: ' + (card.Need_Type__c != null ? card.Need_Type__c : '未設定') + '\n';
            ctx += '- 優先度: ' + (card.Priority__c != null ? card.Priority__c : '未設定') + '\n';
            ctx += '- 鮮度: ' + freshnessLabel + '（最終言及: ' + String.valueOf(lastMentioned) + '）\n';
            if (card.Product__r != null && card.Product__r.Name != null) {
                ctx += '- 製品: ' + card.Product__r.Name;
                if (card.Product__r.Family != null) {
                    ctx += '（' + card.Product__r.Family + '）';
                }
                ctx += '\n';
            }
            if (card.Business_Impact__c != null) {
                ctx += '- 金額規模: ¥' + String.valueOf(card.Business_Impact__c.longValue()) + '\n';
            }
            if (String.isNotBlank(card.Description__c)) {
                String descText = card.Description__c.length() > 300
                    ? card.Description__c.substring(0, 300) + '...'
                    : card.Description__c;
                ctx += '- 詳細: ' + descText + '\n';
            }
            if (String.isNotBlank(card.Customer_Voice__c)) {
                String voice = card.Customer_Voice__c.length() > 200
                    ? card.Customer_Voice__c.substring(0, 200) + '...'
                    : card.Customer_Voice__c;
                ctx += '- 顧客の声: ' + voice + '\n';
            }
            // 紐づく施策情報
            if (cardInitiatives.containsKey(card.Id)) {
                for (Map<String, String> init : cardInitiatives.get(card.Id)) {
                    ctx += '- 関連施策: ' + init.get('name') + ' ' + init.get('title') +
                           '（' + init.get('status') + ', 優先度: ' + init.get('priority') + '）\n';
                }
            }
            ctx += '\n';
        }

        // 施策サマリーセクション
        ctx += buildInitiativeSummary(cardInitiatives);

        return ctx;
    }

    private static Map<Id, List<Map<String, String>>> getRelatedInitiatives(Set<Id> cardIds) {
        Map<Id, List<Map<String, String>>> result = new Map<Id, List<Map<String, String>>>();
        for (Initiative_Need__c ineed : [
            SELECT Needs_Card__c,
                   Initiative__r.Name, Initiative__r.Title__c,
                   Initiative__r.Status__c, Initiative__r.Priority__c,
                   Initiative__r.Product__r.Name, Initiative__r.Target_Release__c,
                   Relevance_Note__c
            FROM Initiative_Need__c
            WHERE Needs_Card__c IN :cardIds
        ]) {
            Id cardId = ineed.Needs_Card__c;
            if (!result.containsKey(cardId)) {
                result.put(cardId, new List<Map<String, String>>());
            }
            Map<String, String> info = new Map<String, String>();
            info.put('name', ineed.Initiative__r.Name);
            info.put('title', ineed.Initiative__r.Title__c);
            info.put('status', ineed.Initiative__r.Status__c != null ? ineed.Initiative__r.Status__c : '未設定');
            info.put('priority', ineed.Initiative__r.Priority__c != null ? ineed.Initiative__r.Priority__c : '未設定');
            info.put('product', ineed.Initiative__r.Product__r != null ? ineed.Initiative__r.Product__r.Name : '');
            info.put('targetRelease', ineed.Initiative__r.Target_Release__c != null
                ? String.valueOf(ineed.Initiative__r.Target_Release__c) : '未定');
            result.get(cardId).add(info);
        }
        return result;
    }

    private static String buildInitiativeSummary(Map<Id, List<Map<String, String>>> cardInitiatives) {
        // ユニークな施策を集約
        Map<String, Map<String, String>> uniqueInitiatives = new Map<String, Map<String, String>>();
        Integer linkedCount = 0;
        for (Id cardId : cardInitiatives.keySet()) {
            linkedCount++;
            for (Map<String, String> init : cardInitiatives.get(cardId)) {
                uniqueInitiatives.put(init.get('name'), init);
            }
        }
        if (uniqueInitiatives.isEmpty()) {
            return '\n## 関連施策\nこのセグメントのニーズに紐づく製品施策はまだありません。\n';
        }
        String summary = '\n## 関連施策（' + uniqueInitiatives.size() + '件、紐づきカード: ' + linkedCount + '件）\n';
        for (String name : uniqueInitiatives.keySet()) {
            Map<String, String> init = uniqueInitiatives.get(name);
            summary += '- ' + name + ': ' + init.get('title') +
                       '（ステータス: ' + init.get('status') +
                       ', 優先度: ' + init.get('priority') +
                       ', 目標リリース: ' + init.get('targetRelease') + '）\n';
        }
        return summary;
    }

    // --- 施策起案 ---

    @AuraEnabled
    public static Map<String, Object> suggestInitiative(String filterType, String filterValue) {
        List<Needs_Card__c> cards = getCardsForFilter(filterType, filterValue);
        if (cards == null || cards.isEmpty()) {
            throw new AuraHandledException('ニーズカードがありません。');
        }

        // 製品オプション収集
        Map<Id, String> productNames = new Map<Id, String>();
        Map<Id, Integer> productFreq = new Map<Id, Integer>();
        for (Needs_Card__c c : cards) {
            if (c.Product__c != null && c.Product__r != null) {
                productNames.put(c.Product__c, c.Product__r.Name);
                productFreq.put(c.Product__c,
                    (productFreq.containsKey(c.Product__c) ? productFreq.get(c.Product__c) : 0) + 1);
            }
        }
        Id defaultProductId = null;
        Integer maxFreq = 0;
        for (Id pid : productFreq.keySet()) {
            if (productFreq.get(pid) > maxFreq) {
                maxFreq = productFreq.get(pid);
                defaultProductId = pid;
            }
        }

        // AI施策提案を生成
        String filterLabel = getFilterLabel(filterType, filterValue);
        String ctx = buildAnalysisContext(filterLabel, cards);
        String suggestion = callSuggestionTemplate(ctx);

        // パース
        String sugTitle = parseBetween(suggestion, '【タイトル】', '【');
        String sugWhat = parseBetween(suggestion, '【概要】', '【');
        String sugWhy = parseBetween(suggestion, '【根拠】', null);

        // カードID
        List<String> cardIds = new List<String>();
        for (Needs_Card__c c : cards) {
            cardIds.add(c.Id);
        }

        // 製品オプション
        List<Map<String, String>> productOptions = new List<Map<String, String>>();
        for (Id pid : productNames.keySet()) {
            Map<String, String> opt = new Map<String, String>();
            opt.put('value', pid);
            opt.put('label', productNames.get(pid));
            productOptions.add(opt);
        }

        Map<String, Object> result = new Map<String, Object>();
        result.put('suggestedTitle', sugTitle != null ? sugTitle.trim() : filterLabel);
        result.put('suggestedWhat', sugWhat != null ? sugWhat.trim() : '');
        result.put('suggestedWhy', sugWhy != null ? sugWhy.trim() : '');
        result.put('products', productOptions);
        result.put('defaultProductId', defaultProductId);
        result.put('cardIds', cardIds);
        result.put('cardCount', cards.size());
        return result;
    }

    @AuraEnabled
    public static Id createInitiativeFromDashboard(String title, String whatDesc, String whyRationale,
            String productId, String priority, List<String> needsCardIds) {
        Product_Initiative__c pi = new Product_Initiative__c();
        pi.Title__c = title;
        pi.What_Description__c = whatDesc;
        pi.Why_Rationale__c = whyRationale;
        pi.Status__c = '起案';
        pi.Priority__c = priority;
        if (String.isNotBlank(productId)) {
            pi.Product__c = productId;
        }
        insert pi;

        // ニーズカード紐付け
        if (needsCardIds != null && !needsCardIds.isEmpty()) {
            List<Initiative_Need__c> links = new List<Initiative_Need__c>();
            for (String cardId : needsCardIds) {
                links.add(new Initiative_Need__c(
                    Initiative__c = pi.Id,
                    Needs_Card__c = cardId
                ));
            }
            insert links;
        }
        return pi.Id;
    }

    // --- カード取得ヘルパー ---

    private static List<Needs_Card__c> getCardsForFilter(String filterType, String filterValue) {
        if (filterType == 'productFamily') {
            return queryByProductFamily(filterValue);
        } else if (filterType == 'productNeedType') {
            String[] parts = filterValue.split('\\|');
            return queryByCross('Product__r.Family', parts[0], 'Need_Type__c', parts.size() > 1 ? parts[1] : '');
        } else if (filterType == 'productIndustry') {
            String[] parts = filterValue.split('\\|');
            return queryByCross('Product__r.Family', parts[0], 'Account_Industry__c', parts.size() > 1 ? parts[1] : '');
        } else if (filterType == 'industryNeedType') {
            String[] parts = filterValue.split('\\|');
            return queryByCross('Account_Industry__c', parts[0], 'Need_Type__c', parts.size() > 1 ? parts[1] : '');
        } else if (filterType == 'account') {
            return [SELECT Id, Name, Title__c, Need_Type__c, Priority__c, Account__r.Name,
                           Account_Industry__c, Business_Unit__c, Business_Impact__c,
                           Description__c, Customer_Voice__c, Product__r.Name, Product__r.Family, CreatedDate
                    FROM Needs_Card__c
                    WHERE Account__r.Name = :filterValue AND Status__c != '却下'
                    ORDER BY Priority__c, CreatedDate DESC];
        }
        return new List<Needs_Card__c>();
    }

    private static String getFilterLabel(String filterType, String filterValue) {
        if (filterType == 'productFamily') return '製品ファミリー「' + filterValue + '」';
        if (filterType == 'productNeedType') {
            String[] p = filterValue.split('\\|');
            return '製品「' + p[0] + '」× 種別「' + (p.size() > 1 ? p[1] : '') + '」';
        }
        if (filterType == 'productIndustry') {
            String[] p = filterValue.split('\\|');
            return '製品「' + p[0] + '」× 業種「' + (p.size() > 1 ? p[1] : '') + '」';
        }
        if (filterType == 'industryNeedType') {
            String[] p = filterValue.split('\\|');
            return '業種「' + p[0] + '」× 種別「' + (p.size() > 1 ? p[1] : '') + '」';
        }
        if (filterType == 'account') return '顧客「' + filterValue + '」';
        return filterValue;
    }

    private static String parseBetween(String text, String startTag, String endTag) {
        if (text == null) return null;
        Integer startIdx = text.indexOf(startTag);
        if (startIdx < 0) return null;
        startIdx += startTag.length();
        if (endTag != null) {
            Integer endIdx = text.indexOf(endTag, startIdx);
            if (endIdx < 0) return text.substring(startIdx).trim();
            return text.substring(startIdx, endIdx).trim();
        }
        return text.substring(startIdx).trim();
    }

    // --- GCP Vertex AI 直接呼出 ---

    private static final String GCP_PROMPT_ENDPOINT = 'https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net/generate-design-suggestion/prompt';

    private static final String ANALYSIS_SYSTEM_PROMPT =
        'あなたはBtoB製造業（エネルギー機器・ソリューション）の事業戦略アナリストです。\n' +
        '以下のニーズカードデータを分析し、経営・事業判断に役立つインサイトを日本語で提供してください。\n\n' +
        '## 出力ルール\n' +
        '1. 「共通テーマ」: このセグメントに共通するニーズの本質を2〜3文で要約\n' +
        '2. 「注目すべきシグナル」: 複数の顧客から同様の声が出ているもの、優先度が高いもの、金額規模が大きいものを抽出（箇条書き3〜5項目）\n' +
        '3. 「顧客の温度感」: 顧客の声（Customer_Voice）から読み取れる緊急度・本気度の評価\n' +
        '4. 「鮮度の示唆」: 鮮度データ（最終言及日）から読み取れる傾向（1〜2項目）\n' +
        '5. 「関連施策の状況」: データに関連施策がある場合、それらの施策がニーズにどの程度対応しているかの評価（施策データがない場合はこのセクションを省略）\n' +
        '6. 「潜在的な機会」: データから読み取れるが明示されていない潜在ニーズや市場機会（1〜2項目）\n' +
        '7. 「リスク・懸念」: 対応しないと失注や顧客離れにつながりうるポイント（あれば）\n\n' +
        '## 制約\n' +
        '- 推測や憶測を避け、データに基づく分析のみ\n' +
        '- 顧客の発言の引用は「」で囲む\n' +
        '- 7セクション全てを必ず出力する。該当なしの場合も「該当なし」と明記する\n' +
        '- 各セクションは2〜3行で簡潔に。冗長な前置きや繰り返しを避ける\n' +
        '- 顧客名・製品名・金額は具体的に引用する\n' +
        '- 提案やアクションプランは含めない（事実と分析のみ）';

    private static final String SUGGESTION_SYSTEM_PROMPT =
        'あなたはBtoB製造業（エネルギー機器・ソリューション）の事業企画担当です。\n' +
        '以下のニーズカードデータに基づき、製品施策（Product Initiative）を起案してください。\n\n' +
        '## 出力フォーマット（厳守）\n' +
        '以下の3項目を必ず【】で囲んだ見出しで出力してください。\n\n' +
        '【タイトル】施策の名称（30文字以内、具体的な製品名や技術要素を含む）\n' +
        '【概要】何をやるか（What）。ニーズデータから読み取れる顧客要求を踏まえ、200文字以内で具体的に記述\n' +
        '【根拠】なぜやるか（Why）。ニーズの件数・顧客数・金額規模・鮮度に基づく根拠を200文字以内で記述\n\n' +
        '## 制約\n' +
        '- データに基づく提案のみ。推測は含めない\n' +
        '- 複数のニーズを統合した一貫性のある施策にする\n' +
        '- 顧客の声を反映した具体的な内容にする';

    private static String callVertexAI(String systemPrompt, String context, Decimal temperature) {
        Map<String, Object> requestBody = new Map<String, Object>{
            'systemPrompt' => systemPrompt,
            'context' => context,
            'temperature' => temperature
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(GCP_PROMPT_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(requestBody));

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() != 200) {
            throw new AuraHandledException(
                'GCP Vertex AIからの応答エラー (' + res.getStatusCode() + '): ' + res.getBody()
            );
        }

        Map<String, Object> gcpResponse = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        return (String) gcpResponse.get('text');
    }

    private static String callSuggestionTemplate(String context) {
        return callVertexAI(SUGGESTION_SYSTEM_PROMPT, context, 0.3);
    }

    private static String callPromptTemplate(String context) {
        return callVertexAI(ANALYSIS_SYSTEM_PROMPT, context, 0.2);
    }
}
