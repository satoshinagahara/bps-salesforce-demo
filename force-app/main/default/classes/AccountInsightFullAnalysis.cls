public class AccountInsightFullAnalysis {

    public class Request {
        @InvocableVariable(label='取引先ID' description='取引先のSalesforce ID' required=true)
        public String accountId;
    }

    public class Result {
        @InvocableVariable(label='取引先総合分析データ')
        public String analysisData;
    }

    @InvocableMethod(label='取引先総合分析' description='取引先の基本情報・商談・ケース・責任者・活動を一括取得し、分析用の構造化データを返します')
    public static List<Result> analyze(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            Map<String, Object> fullData = new Map<String, Object>();
            Date today = Date.today();

            // 1. Account basic info
            List<Account> accounts = [
                SELECT Id, Name, Industry, Type, AnnualRevenue, NumberOfEmployees,
                       Phone, BillingCity, BillingState, Website, Description, Owner.Name
                FROM Account WHERE Id = :req.accountId LIMIT 1
            ];
            if (accounts.isEmpty()) {
                res.analysisData = '{"error":"取引先が見つかりません"}';
                results.add(res);
                continue;
            }
            Account a = accounts[0];
            Map<String, Object> acctInfo = new Map<String, Object>();
            acctInfo.put('name', a.Name);
            acctInfo.put('industry', a.Industry);
            acctInfo.put('type', a.Type);
            acctInfo.put('annualRevenue', a.AnnualRevenue);
            acctInfo.put('numberOfEmployees', a.NumberOfEmployees);
            acctInfo.put('owner', a.Owner.Name);
            fullData.put('account', acctInfo);

            // 2. Opportunities summary
            List<Opportunity> opps = [
                SELECT Name, StageName, Amount, CloseDate, Probability,
                       IsClosed, IsWon, LastActivityDate, Owner.Name
                FROM Opportunity WHERE AccountId = :req.accountId
                ORDER BY CloseDate ASC LIMIT 50
            ];
            Integer oppOpen = 0; Decimal oppOpenAmt = 0;
            Integer oppWon = 0; Decimal oppWonAmt = 0;
            Integer oppLost = 0;
            List<Map<String, Object>> attentionDeals = new List<Map<String, Object>>();
            for (Opportunity o : opps) {
                Decimal amt = o.Amount != null ? o.Amount : 0;
                if (o.IsClosed && o.IsWon) { oppWon++; oppWonAmt += amt; }
                else if (o.IsClosed) { oppLost++; }
                else {
                    oppOpen++; oppOpenAmt += amt;
                    Boolean closingSoon = o.CloseDate != null && o.CloseDate <= today.addDays(30);
                    Boolean noRecentActivity = o.LastActivityDate == null || o.LastActivityDate.daysBetween(today) > 30;
                    Boolean highValue = o.Amount != null && o.Amount >= 1000000;
                    if (closingSoon || (highValue && noRecentActivity)) {
                        Map<String, Object> d = new Map<String, Object>();
                        d.put('name', o.Name);
                        d.put('stage', o.StageName);
                        d.put('amount', o.Amount);
                        d.put('closeDate', String.valueOf(o.CloseDate));
                        d.put('probability', o.Probability);
                        d.put('lastActivity', o.LastActivityDate != null ? String.valueOf(o.LastActivityDate) : 'なし');
                        d.put('daysUntilClose', o.CloseDate != null ? today.daysBetween(o.CloseDate) : null);
                        d.put('flags', new List<String>{
                            closingSoon ? '30日以内クローズ予定' : '',
                            noRecentActivity ? '30日以上活動なし' : '',
                            highValue ? '高額案件' : ''
                        });
                        attentionDeals.add(d);
                    }
                }
            }
            Map<String, Object> oppSummary = new Map<String, Object>();
            oppSummary.put('openCount', oppOpen);
            oppSummary.put('openAmount', oppOpenAmt);
            oppSummary.put('wonCount', oppWon);
            oppSummary.put('wonAmount', oppWonAmt);
            oppSummary.put('lostCount', oppLost);
            oppSummary.put('attentionDeals', attentionDeals);
            fullData.put('opportunities', oppSummary);

            // 3. Cases summary
            List<Case> cases = [
                SELECT CaseNumber, Subject, Status, Priority, IsClosed, CreatedDate, Owner.Name
                FROM Case WHERE AccountId = :req.accountId
                ORDER BY CreatedDate DESC LIMIT 50
            ];
            Integer caseOpen = 0; Integer caseClosed = 0;
            List<Map<String, Object>> criticalCases = new List<Map<String, Object>>();
            for (Case c : cases) {
                if (c.IsClosed) { caseClosed++; }
                else {
                    caseOpen++;
                    if (c.Priority == 'High' || c.Priority == 'Critical') {
                        Map<String, Object> cc = new Map<String, Object>();
                        cc.put('caseNumber', c.CaseNumber);
                        cc.put('subject', c.Subject);
                        cc.put('priority', c.Priority);
                        cc.put('status', c.Status);
                        cc.put('ageDays', c.CreatedDate.date().daysBetween(today));
                        criticalCases.add(cc);
                    }
                }
            }
            Map<String, Object> caseSummary = new Map<String, Object>();
            caseSummary.put('openCount', caseOpen);
            caseSummary.put('closedCount', caseClosed);
            caseSummary.put('criticalCases', criticalCases);
            fullData.put('cases', caseSummary);

            // 4. Key contacts
            List<Contact> contacts = [
                SELECT Name, Title, Department, Email, LastActivityDate
                FROM Contact WHERE AccountId = :req.accountId
                ORDER BY LastModifiedDate DESC LIMIT 10
            ];
            List<Map<String, Object>> contactList = new List<Map<String, Object>>();
            for (Contact c : contacts) {
                Map<String, Object> ci = new Map<String, Object>();
                ci.put('name', c.Name);
                ci.put('title', c.Title);
                ci.put('department', c.Department);
                contactList.add(ci);
            }
            fullData.put('contacts', contactList);

            // 5. Activities engagement
            List<Task> tasks = [
                SELECT ActivityDate, IsClosed, What.Type
                FROM Task WHERE AccountId = :req.accountId AND What.Type = 'Opportunity'
                ORDER BY ActivityDate DESC NULLS LAST LIMIT 30
            ];
            List<Event> events = [
                SELECT StartDateTime, What.Type
                FROM Event WHERE AccountId = :req.accountId AND What.Type = 'Opportunity'
                ORDER BY StartDateTime DESC NULLS LAST LIMIT 30
            ];
            Integer openTasks = 0; Integer overdueTasks = 0; Integer upcomingEvents = 0;
            Date lastActivity = null;
            for (Task t : tasks) {
                if (!t.IsClosed) {
                    openTasks++;
                    if (t.ActivityDate != null && t.ActivityDate < today) overdueTasks++;
                }
                if (t.ActivityDate != null && (lastActivity == null || t.ActivityDate > lastActivity))
                    lastActivity = t.ActivityDate;
            }
            for (Event e : events) {
                Date eDate = e.StartDateTime != null ? e.StartDateTime.date() : null;
                if (eDate != null && eDate >= today) upcomingEvents++;
                if (eDate != null && (lastActivity == null || eDate > lastActivity))
                    lastActivity = eDate;
            }
            Integer daysSince = lastActivity != null ? lastActivity.daysBetween(today) : null;
            String engagement = daysSince == null ? 'Unknown'
                : daysSince <= 7 ? 'High'
                : daysSince <= 30 ? 'Medium'
                : daysSince <= 90 ? 'Low' : 'Inactive';

            Map<String, Object> activitySummary = new Map<String, Object>();
            activitySummary.put('totalTasks', tasks.size());
            activitySummary.put('openTasks', openTasks);
            activitySummary.put('overdueTasks', overdueTasks);
            activitySummary.put('totalEvents', events.size());
            activitySummary.put('upcomingEvents', upcomingEvents);
            activitySummary.put('daysSinceLastActivity', daysSince);
            activitySummary.put('engagementLevel', engagement);
            fullData.put('activities', activitySummary);

            fullData.put('analysisDate', String.valueOf(today));
            res.analysisData = JSON.serialize(fullData);
            results.add(res);
        }
        return results;
    }
}
