public class OpportunitySimilaritySearchHelper {

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
                   Key_Risks__c, Lessons_Or_Insights__c
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

        // 3. 類似商談検索
        List<Map<String, Object>> similar = new List<Map<String, Object>>();

        if (!currentSummaries.isEmpty()) {
            Opportunity_Summary__c cs = currentSummaries[0];
            Set<Id> found = new Set<Id>();

            // deal_type一致（最大2件）
            if (cs.Deal_Type__c != null) {
                for (Opportunity_Summary__c s : [
                    SELECT Id, Opportunity__c, Opportunity__r.Name, Opportunity__r.Account.Name,
                           Opportunity__r.IsWon,
                           Deal_Type__c, Sales_Motion__c, Competitive_Situation__c,
                           Sales_Process_Pattern__c,
                           Customer_Challenge__c, Our_Value_Proposition__c,
                           Lessons_Or_Insights__c
                    FROM Opportunity_Summary__c
                    WHERE Deal_Type__c = :cs.Deal_Type__c
                      AND Opportunity__c != :opportunityId
                      AND Sales_Process_Pattern__c != null
                    ORDER BY CreatedDate DESC LIMIT 2
                ]) {
                    found.add(s.Id);
                    similar.add(buildEntry(s, '同じ案件タイプ'));
                }
            }

            // sales_motion一致（最大1件）
            if (cs.Sales_Motion__c != null && similar.size() < 4) {
                for (Opportunity_Summary__c s : [
                    SELECT Id, Opportunity__c, Opportunity__r.Name, Opportunity__r.Account.Name,
                           Opportunity__r.IsWon,
                           Deal_Type__c, Sales_Motion__c, Competitive_Situation__c,
                           Sales_Process_Pattern__c,
                           Customer_Challenge__c, Our_Value_Proposition__c,
                           Lessons_Or_Insights__c
                    FROM Opportunity_Summary__c
                    WHERE Sales_Motion__c = :cs.Sales_Motion__c
                      AND Opportunity__c != :opportunityId
                      AND Id NOT IN :found
                      AND Sales_Process_Pattern__c != null
                    ORDER BY CreatedDate DESC LIMIT 1
                ]) {
                    found.add(s.Id);
                    similar.add(buildEntry(s, '同じ営業アプローチ'));
                }
            }

            // urgency_driver一致（最大1件）
            if (cs.Urgency_Driver__c != null && cs.Urgency_Driver__c != '不明' && similar.size() < 4) {
                for (Opportunity_Summary__c s : [
                    SELECT Id, Opportunity__c, Opportunity__r.Name, Opportunity__r.Account.Name,
                           Opportunity__r.IsWon,
                           Deal_Type__c, Sales_Motion__c, Competitive_Situation__c,
                           Sales_Process_Pattern__c,
                           Customer_Challenge__c, Our_Value_Proposition__c,
                           Lessons_Or_Insights__c
                    FROM Opportunity_Summary__c
                    WHERE Urgency_Driver__c = :cs.Urgency_Driver__c
                      AND Opportunity__c != :opportunityId
                      AND Id NOT IN :found
                      AND Sales_Process_Pattern__c != null
                    ORDER BY CreatedDate DESC LIMIT 1
                ]) {
                    found.add(s.Id);
                    similar.add(buildEntry(s, '同じ緊急性の動因'));
                }
            }
        }

        output.put('similar', similar);
        return output;
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
        return e;
    }
}
