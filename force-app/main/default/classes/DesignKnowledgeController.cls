public with sharing class DesignKnowledgeController {

    public class KnowledgeResult {
        @AuraEnabled public String id;
        @AuraEnabled public String title;
        @AuraEnabled public String category;
        @AuraEnabled public String keywords;
        @AuraEnabled public String lessonSummary;
        @AuraEnabled public String sourceCAs;
        @AuraEnabled public String matchReason;
        @AuraEnabled public Integer relevanceScore;
    }

    @AuraEnabled(cacheable=true)
    public static List<KnowledgeResult> getRelatedKnowledge(Id designProjectId) {
        // 1. Design Project情報取得
        Design_Project__c dp = [
            SELECT Id, Base_BOM__c, Product__c, Base_Product__c,
                   Product__r.Name, Base_Product__r.Name, Base_Product__r.Family
            FROM Design_Project__c
            WHERE Id = :designProjectId
            LIMIT 1
        ];

        // 2. BOMからサプライヤー名・部品名・材料タイプを取得
        Set<String> searchTerms = new Set<String>();
        Set<String> supplierNames = new Set<String>();
        Set<String> materialCategories = new Set<String>();

        if (dp.Product__r != null && dp.Product__r.Name != null) {
            searchTerms.add(dp.Product__r.Name);
        }
        if (dp.Base_Product__r != null && dp.Base_Product__r.Name != null) {
            searchTerms.add(dp.Base_Product__r.Name);
        }
        if (dp.Base_Product__r != null && dp.Base_Product__r.Family != null) {
            searchTerms.add(dp.Base_Product__r.Family);
        }

        // BOM階層をたどる
        Id bomId = dp.Base_BOM__c;
        if (bomId != null) {
            // BOM_Part__c からサプライヤー・部品情報
            List<BOM_Part__c> parts = [
                SELECT Part_Name__c, Part_Number__c, Material__c,
                       Supplier__r.Name, Manufacturer__c,
                       BOM_SubComponent__c, BOM_SubComponent__r.Material_Type__c,
                       BOM_SubComponent__r.BOM_Line__r.BOM_Header__c
                FROM BOM_Part__c
                WHERE BOM_SubComponent__r.BOM_Line__r.BOM_Header__c = :bomId
            ];

            for (BOM_Part__c p : parts) {
                if (p.Supplier__r != null && p.Supplier__r.Name != null) {
                    supplierNames.add(p.Supplier__r.Name);
                    searchTerms.add(p.Supplier__r.Name);
                }
                if (p.Part_Name__c != null) {
                    searchTerms.add(p.Part_Name__c);
                }
                if (p.Material__c != null) {
                    searchTerms.add(p.Material__c);
                }
                if (p.Manufacturer__c != null) {
                    searchTerms.add(p.Manufacturer__c);
                }
                if (p.BOM_SubComponent__r != null && p.BOM_SubComponent__r.Material_Type__c != null) {
                    materialCategories.add(p.BOM_SubComponent__r.Material_Type__c);
                }
            }
        }

        // 3. RecordType取得
        Id rtId;
        List<RecordType> rts = [SELECT Id FROM RecordType WHERE SObjectType = 'Knowledge__kav' AND DeveloperName = 'Design_Knowledge' LIMIT 1];
        if (rts.isEmpty()) {
            return new List<KnowledgeResult>();
        }
        rtId = rts[0].Id;

        // 4. Design_Knowledge記事を全件取得し、Apex側で双方向マッチング
        List<Knowledge__kav> allArticles = [
            SELECT Id, Title, Part_Category__c, Search_Keywords__c,
                   Lesson__c, Source_CAs__c, PublishStatus
            FROM Knowledge__kav
            WHERE RecordTypeId = :rtId AND IsLatestVersion = true
            AND Language = 'en_US'
            LIMIT 200
        ];

        // BOMデータを一つの検索対象テキストに結合
        String bomText = String.join(new List<String>(searchTerms), ' ');

        // マッチする記事を選別
        List<Knowledge__kav> articles = new List<Knowledge__kav>();
        for (Knowledge__kav art : allArticles) {
            Boolean matched = false;

            // 方向1: ナレッジのキーワードがBOMデータに含まれるか
            if (art.Search_Keywords__c != null) {
                for (String kw : art.Search_Keywords__c.split('\\s+')) {
                    if (kw.length() >= 2 && bomText.containsIgnoreCase(kw)) {
                        matched = true;
                        break;
                    }
                }
            }

            // 方向2: BOMの検索語がナレッジのタイトル・キーワード・教訓に含まれるか
            if (!matched) {
                String artText = (art.Title != null ? art.Title : '') + ' '
                    + (art.Search_Keywords__c != null ? art.Search_Keywords__c : '') + ' '
                    + (art.Lesson__c != null ? art.Lesson__c : '');
                for (String term : searchTerms) {
                    if (term.length() >= 2 && artText.containsIgnoreCase(term)) {
                        matched = true;
                        break;
                    }
                }
            }

            if (matched) {
                articles.add(art);
            }
        }

        // 4. 関連度スコアリング
        Map<Id, KnowledgeResult> resultMap = new Map<Id, KnowledgeResult>();
        for (Knowledge__kav art : articles) {
            KnowledgeResult kr = new KnowledgeResult();
            kr.id = art.Id;
            kr.title = art.Title;
            kr.category = art.Part_Category__c;
            kr.keywords = art.Search_Keywords__c;
            kr.sourceCAs = art.Source_CAs__c;
            kr.relevanceScore = 0;

            // 教訓サマリー（HTMLタグ除去、先頭120文字）
            if (art.Lesson__c != null) {
                String plain = art.Lesson__c.replaceAll('<[^>]+>', '').replaceAll('&[^;]+;', '');
                kr.lessonSummary = plain.length() > 120 ? plain.substring(0, 120) + '...' : plain;
            }

            // スコアリング: カテゴリ一致
            List<String> matchReasons = new List<String>();
            if (art.Part_Category__c != null && !materialCategories.isEmpty()) {
                Map<String, String> scoreCatMap = new Map<String, String>{
                    '電子部品' => '電子部品', '樹脂' => '樹脂材料', '金属' => '金属部品',
                    'ゴム' => '化学材料', 'その他' => 'その他'
                };
                for (String mc : materialCategories) {
                    String mapped = scoreCatMap.get(mc);
                    if (mapped != null && mapped == art.Part_Category__c) {
                        kr.relevanceScore += 3;
                        matchReasons.add('部品カテゴリ一致');
                        break;
                    }
                }
            }

            // スコアリング: サプライヤー名一致
            if (art.Search_Keywords__c != null) {
                for (String sn : supplierNames) {
                    if (art.Search_Keywords__c.containsIgnoreCase(sn)) {
                        kr.relevanceScore += 5;
                        matchReasons.add('サプライヤー「' + sn + '」関連');
                        break;
                    }
                }
            }

            // スコアリング: 製品名一致
            String productName = dp.Product__r != null ? dp.Product__r.Name : '';
            String baseProductName = dp.Base_Product__r != null ? dp.Base_Product__r.Name : '';
            if (art.Search_Keywords__c != null || art.Title != null) {
                String combined = (art.Search_Keywords__c != null ? art.Search_Keywords__c : '') + ' ' + (art.Title != null ? art.Title : '');
                if (String.isNotBlank(productName) && combined.containsIgnoreCase(productName)) {
                    kr.relevanceScore += 4;
                    matchReasons.add('対象製品関連');
                }
                if (String.isNotBlank(baseProductName) && combined.containsIgnoreCase(baseProductName)) {
                    kr.relevanceScore += 4;
                    matchReasons.add('ベース製品関連');
                }
            }

            // 最低スコア1（検索でヒットした時点で関連性あり）
            if (kr.relevanceScore == 0) {
                kr.relevanceScore = 1;
                matchReasons.add('キーワード一致');
            }

            kr.matchReason = String.join(matchReasons, '、');
            resultMap.put(art.Id, kr);
        }

        // 5. スコア降順でソート
        List<KnowledgeResult> results = resultMap.values();
        results.sort(new KnowledgeScoreComparator());
        return results;
    }

    // スコア降順ソート用Comparator
    private class KnowledgeScoreComparator implements Comparator<KnowledgeResult> {
        public Integer compare(KnowledgeResult a, KnowledgeResult b) {
            return b.relevanceScore - a.relevanceScore;
        }
    }
}
