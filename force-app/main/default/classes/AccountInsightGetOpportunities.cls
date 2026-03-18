public class AccountInsightGetOpportunities {

    public class Request {
        @InvocableVariable(label='取引先ID' description='取引先のSalesforce ID' required=true)
        public String accountId;
    }

    public class Result {
        @InvocableVariable(label='商談分析情報')
        public String opportunityInfo;
    }

    @InvocableMethod(label='商談パイプライン分析' description='取引先の商談をステージ別に集計し、注目案件を含めて返します')
    public static List<Result> getOpportunities(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            List<Opportunity> opps = [
                SELECT Id, Name, StageName, Amount, CloseDate, Probability,
                       IsClosed, IsWon, OwnerId, Owner.Name, LastActivityDate
                FROM Opportunity
                WHERE AccountId = :req.accountId
                ORDER BY CloseDate ASC
                LIMIT 50
            ];
            Map<String, Object> analysis = new Map<String, Object>();
            analysis.put('totalCount', opps.size());

            if (opps.isEmpty()) {
                analysis.put('summary', '関連する商談はありません。');
            } else {
                // Stage breakdown
                Map<String, Integer> stageCount = new Map<String, Integer>();
                Map<String, Decimal> stageAmount = new Map<String, Decimal>();
                Decimal totalOpen = 0;
                Decimal totalWon = 0;
                Decimal totalLost = 0;
                Integer openCount = 0;
                Integer wonCount = 0;
                Integer lostCount = 0;
                List<Map<String, Object>> highlightDeals = new List<Map<String, Object>>();
                Date today = Date.today();

                for (Opportunity o : opps) {
                    String stage = o.StageName;
                    stageCount.put(stage, (stageCount.containsKey(stage) ? stageCount.get(stage) : 0) + 1);
                    Decimal amt = o.Amount != null ? o.Amount : 0;
                    stageAmount.put(stage, (stageAmount.containsKey(stage) ? stageAmount.get(stage) : 0) + amt);

                    if (o.IsClosed && o.IsWon) {
                        wonCount++;
                        totalWon += amt;
                    } else if (o.IsClosed && !o.IsWon) {
                        lostCount++;
                        totalLost += amt;
                    } else {
                        openCount++;
                        totalOpen += amt;
                        // Highlight: closing within 30 days or high amount
                        if ((o.CloseDate != null && o.CloseDate <= today.addDays(30)) ||
                            (o.Amount != null && o.Amount >= 1000000)) {
                            Map<String, Object> deal = new Map<String, Object>();
                            deal.put('name', o.Name);
                            deal.put('stage', o.StageName);
                            deal.put('amount', o.Amount);
                            deal.put('closeDate', String.valueOf(o.CloseDate));
                            deal.put('probability', o.Probability);
                            deal.put('owner', o.Owner.Name);
                            deal.put('lastActivityDate', o.LastActivityDate != null ? String.valueOf(o.LastActivityDate) : null);
                            deal.put('daysUntilClose', o.CloseDate != null ? today.daysBetween(o.CloseDate) : null);
                            highlightDeals.add(deal);
                        }
                    }
                }

                Map<String, Object> summary = new Map<String, Object>();
                summary.put('openCount', openCount);
                summary.put('openAmount', totalOpen);
                summary.put('wonCount', wonCount);
                summary.put('wonAmount', totalWon);
                summary.put('lostCount', lostCount);
                summary.put('lostAmount', totalLost);

                List<Map<String, Object>> stageBreakdown = new List<Map<String, Object>>();
                for (String stage : stageCount.keySet()) {
                    Map<String, Object> sb = new Map<String, Object>();
                    sb.put('stage', stage);
                    sb.put('count', stageCount.get(stage));
                    sb.put('amount', stageAmount.get(stage));
                    stageBreakdown.add(sb);
                }

                analysis.put('summary', summary);
                analysis.put('stageBreakdown', stageBreakdown);
                analysis.put('highlightDeals', highlightDeals);
            }

            res.opportunityInfo = JSON.serialize(analysis);
            results.add(res);
        }
        return results;
    }
}
