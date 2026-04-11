public with sharing class NeedsCorrelationController {

    private static final Integer TOP_N_EDGES_PER_NODE = 3;

    public class EdgeScore implements Comparable {
        public Integer i;
        public Integer j;
        public Integer score;
        public EdgeScore(Integer i, Integer j, Integer score) {
            this.i = i;
            this.j = j;
            this.score = score;
        }
        public Integer compareTo(Object other) {
            EdgeScore o = (EdgeScore) other;
            if (this.score < o.score) return 1;
            if (this.score > o.score) return -1;
            return 0;
        }
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getCorrelationData(Integer minSimilarity, Integer maxNodes) {
        Map<String, Object> result = new Map<String, Object>();

        List<Needs_Card__c> allCards = [
            SELECT Id, Name, Title__c, Need_Type__c, Priority__c,
                   Account__c, Account__r.Name,
                   Account_Industry__c, Business_Impact__c,
                   Product__c, Product__r.Family,
                   Description__c, Customer_Voice__c, CreatedDate
            FROM Needs_Card__c
            WHERE Status__c != '却下' AND Account_Industry__c != null
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];

        List<Needs_Card__c> cards = new List<Needs_Card__c>();
        for (Integer i = 0; i < allCards.size() && i < maxNodes; i++) {
            cards.add(allCards[i]);
        }

        List<Set<String>> bigramSets = new List<Set<String>>();
        for (Needs_Card__c card : cards) {
            bigramSets.add(toBigrams(combineText(card)));
        }

        List<Map<String, Object>> nodes = new List<Map<String, Object>>();
        Map<String, Integer> industryCount = new Map<String, Integer>();

        for (Integer i = 0; i < cards.size(); i++) {
            Needs_Card__c card = cards[i];
            String industry = String.isNotBlank(card.Account_Industry__c)
                ? card.Account_Industry__c : 'Unknown';

            Map<String, Object> node = new Map<String, Object>();
            node.put('id', card.Id);
            node.put('label', String.isNotBlank(card.Title__c) ? card.Title__c : card.Name);
            node.put('industry', industry);
            node.put('accountName', card.Account__r != null ? card.Account__r.Name : '');
            node.put('productFamily', card.Product__r != null ? card.Product__r.Family : '');
            node.put('needType', card.Need_Type__c);
            node.put('priority', card.Priority__c);
            node.put('businessImpact', card.Business_Impact__c);
            nodes.add(node);

            Integer c = industryCount.containsKey(industry)
                ? industryCount.get(industry) + 1 : 1;
            industryCount.put(industry, c);
        }

        List<EdgeScore> allEdges = new List<EdgeScore>();
        for (Integer i = 0; i < cards.size(); i++) {
            for (Integer j = i + 1; j < cards.size(); j++) {
                Integer sim = jaccardSimilarity(bigramSets[i], bigramSets[j]);
                if (sim >= minSimilarity) {
                    allEdges.add(new EdgeScore(i, j, sim));
                }
            }
        }

        // k-NN: per-node keep top K strongest
        Map<Integer, List<EdgeScore>> nodeEdges = new Map<Integer, List<EdgeScore>>();
        for (EdgeScore e : allEdges) {
            if (!nodeEdges.containsKey(e.i)) nodeEdges.put(e.i, new List<EdgeScore>());
            if (!nodeEdges.containsKey(e.j)) nodeEdges.put(e.j, new List<EdgeScore>());
            nodeEdges.get(e.i).add(e);
            nodeEdges.get(e.j).add(e);
        }

        Set<String> keptKeys = new Set<String>();
        for (Integer nodeIdx : nodeEdges.keySet()) {
            List<EdgeScore> eds = nodeEdges.get(nodeIdx);
            eds.sort();
            Integer limitK = Math.min(eds.size(), TOP_N_EDGES_PER_NODE);
            for (Integer k = 0; k < limitK; k++) {
                keptKeys.add(eds[k].i + '-' + eds[k].j);
            }
        }

        List<Map<String, Object>> edges = new List<Map<String, Object>>();
        for (EdgeScore e : allEdges) {
            String key = e.i + '-' + e.j;
            if (keptKeys.contains(key)) {
                Map<String, Object> edge = new Map<String, Object>();
                edge.put('from', (String) nodes[e.i].get('id'));
                edge.put('to', (String) nodes[e.j].get('id'));
                edge.put('weight', e.score);
                edges.add(edge);
            }
        }

        result.put('nodes', nodes);
        result.put('edges', edges);
        result.put('industryCount', industryCount);
        result.put('crossIndustryInsights', analyzeCrossIndustry(cards, edges));

        return result;
    }

    private static String combineText(Needs_Card__c card) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(card.Title__c)) parts.add(card.Title__c);
        if (String.isNotBlank(card.Description__c)) parts.add(card.Description__c);
        if (String.isNotBlank(card.Customer_Voice__c)) parts.add(card.Customer_Voice__c);
        return String.join(parts, ' ');
    }

    private static Set<String> toBigrams(String text) {
        Set<String> grams = new Set<String>();
        if (String.isBlank(text)) return grams;
        String cleaned = text.toLowerCase()
            .replaceAll('[\\s\\p{Punct}、。・「」『』（）【】]', '');
        if (cleaned.length() < 2) return grams;
        for (Integer i = 0; i < cleaned.length() - 1; i++) {
            grams.add(cleaned.substring(i, i + 2));
        }
        return grams;
    }

    private static Integer jaccardSimilarity(Set<String> a, Set<String> b) {
        if (a.isEmpty() || b.isEmpty()) return 0;
        Set<String> inter = a.clone();
        inter.retainAll(b);
        Set<String> uni = a.clone();
        uni.addAll(b);
        if (uni.isEmpty()) return 0;
        return Integer.valueOf((Decimal.valueOf(inter.size()) / uni.size()) * 100);
    }

    private static List<Map<String, Object>> analyzeCrossIndustry(
        List<Needs_Card__c> cards, List<Map<String, Object>> edges) {

        Map<Id, Needs_Card__c> cardMap = new Map<Id, Needs_Card__c>(cards);
        Map<String, Integer> industryPairCount = new Map<String, Integer>();

        for (Map<String, Object> edge : edges) {
            Id fromId = (Id) edge.get('from');
            Id toId = (Id) edge.get('to');
            Needs_Card__c card1 = cardMap.get(fromId);
            Needs_Card__c card2 = cardMap.get(toId);

            if (card1 != null && card2 != null) {
                String ind1 = card1.Account_Industry__c;
                String ind2 = card2.Account_Industry__c;
                if (String.isNotBlank(ind1) && String.isNotBlank(ind2) && ind1 != ind2) {
                    List<String> pair = new List<String>{ ind1, ind2 };
                    pair.sort();
                    String key = String.join(pair, ' × ');
                    Integer count = industryPairCount.containsKey(key)
                        ? industryPairCount.get(key) + 1 : 1;
                    industryPairCount.put(key, count);
                }
            }
        }

        List<Map<String, Object>> insights = new List<Map<String, Object>>();
        for (String key : industryPairCount.keySet()) {
            Integer count = industryPairCount.get(key);
            if (count >= 2) {
                Map<String, Object> insight = new Map<String, Object>();
                insight.put('pair', key);
                insight.put('count', count);
                insights.add(insight);
            }
        }
        return insights;
    }
}
