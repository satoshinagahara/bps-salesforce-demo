public class AccountInsightGetCases {

    public class Request {
        @InvocableVariable(label='取引先ID' description='取引先のSalesforce ID' required=true)
        public String accountId;
    }

    public class Result {
        @InvocableVariable(label='ケース分析情報')
        public String caseInfo;
    }

    @InvocableMethod(label='ケース状況分析' description='取引先のケースを優先度・ステータス別に集計し、リスク判定を含めて返します')
    public static List<Result> getCases(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            List<Case> cases = [
                SELECT Id, CaseNumber, Subject, Status, Priority, Origin,
                       CreatedDate, ClosedDate, IsClosed, OwnerId, Owner.Name
                FROM Case
                WHERE AccountId = :req.accountId
                ORDER BY CreatedDate DESC
                LIMIT 50
            ];
            Map<String, Object> analysis = new Map<String, Object>();
            analysis.put('totalCount', cases.size());

            if (cases.isEmpty()) {
                analysis.put('summary', '関連するケースはありません。');
            } else {
                Integer openCount = 0;
                Integer closedCount = 0;
                Map<String, Integer> priorityCount = new Map<String, Integer>();
                Map<String, Integer> statusCount = new Map<String, Integer>();
                List<Map<String, Object>> criticalCases = new List<Map<String, Object>>();
                Date today = Date.today();

                for (Case c : cases) {
                    if (c.IsClosed) {
                        closedCount++;
                    } else {
                        openCount++;
                    }

                    String priority = c.Priority != null ? c.Priority : 'None';
                    priorityCount.put(priority, (priorityCount.containsKey(priority) ? priorityCount.get(priority) : 0) + 1);

                    String status = c.Status;
                    statusCount.put(status, (statusCount.containsKey(status) ? statusCount.get(status) : 0) + 1);

                    // Flag high-priority open cases
                    if (!c.IsClosed && (c.Priority == 'High' || c.Priority == 'Critical')) {
                        Map<String, Object> cc = new Map<String, Object>();
                        cc.put('caseNumber', c.CaseNumber);
                        cc.put('subject', c.Subject);
                        cc.put('priority', c.Priority);
                        cc.put('status', c.Status);
                        cc.put('owner', c.Owner.Name);
                        cc.put('createdDate', String.valueOf(c.CreatedDate.date()));
                        cc.put('ageDays', c.CreatedDate.date().daysBetween(today));
                        criticalCases.add(cc);
                    }
                }

                Map<String, Object> summary = new Map<String, Object>();
                summary.put('openCount', openCount);
                summary.put('closedCount', closedCount);

                List<Map<String, Object>> priorityBreakdown = new List<Map<String, Object>>();
                for (String p : priorityCount.keySet()) {
                    Map<String, Object> pb = new Map<String, Object>();
                    pb.put('priority', p);
                    pb.put('count', priorityCount.get(p));
                    priorityBreakdown.add(pb);
                }

                List<Map<String, Object>> statusBreakdown = new List<Map<String, Object>>();
                for (String s : statusCount.keySet()) {
                    Map<String, Object> sb = new Map<String, Object>();
                    sb.put('status', s);
                    sb.put('count', statusCount.get(s));
                    statusBreakdown.add(sb);
                }

                analysis.put('summary', summary);
                analysis.put('priorityBreakdown', priorityBreakdown);
                analysis.put('statusBreakdown', statusBreakdown);
                analysis.put('criticalCases', criticalCases);
            }

            res.caseInfo = JSON.serialize(analysis);
            results.add(res);
        }
        return results;
    }
}
