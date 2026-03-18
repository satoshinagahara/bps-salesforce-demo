public class AccountInsightGetActivities {

    public class Request {
        @InvocableVariable(label='取引先ID' description='取引先のSalesforce ID' required=true)
        public String accountId;
    }

    public class Result {
        @InvocableVariable(label='活動・行動分析情報')
        public String activityInfo;
    }

    @InvocableMethod(label='商談関連活動・行動分析' description='取引先の商談に紐づく活動(Task)と行動(Event)を分析し、エンゲージメント状況を返します')
    public static List<Result> getActivities(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            Date today = Date.today();

            // Tasks related to this account's opportunities
            List<Task> tasks = [
                SELECT Id, Subject, Status, ActivityDate, What.Name, Type,
                       IsClosed, Priority, OwnerId, Owner.Name
                FROM Task
                WHERE AccountId = :req.accountId
                  AND What.Type = 'Opportunity'
                ORDER BY ActivityDate DESC NULLS LAST
                LIMIT 30
            ];

            // Events related to this account's opportunities
            List<Event> events = [
                SELECT Id, Subject, StartDateTime, EndDateTime, What.Name, Type,
                       OwnerId, Owner.Name
                FROM Event
                WHERE AccountId = :req.accountId
                  AND What.Type = 'Opportunity'
                ORDER BY StartDateTime DESC NULLS LAST
                LIMIT 30
            ];

            Map<String, Object> analysis = new Map<String, Object>();

            // Task analysis
            Integer totalTasks = tasks.size();
            Integer openTasks = 0;
            Integer completedTasks = 0;
            Integer overdueTasks = 0;
            Date lastTaskDate = null;
            List<Map<String, Object>> recentTasks = new List<Map<String, Object>>();

            for (Task t : tasks) {
                if (t.IsClosed) {
                    completedTasks++;
                } else {
                    openTasks++;
                    if (t.ActivityDate != null && t.ActivityDate < today) {
                        overdueTasks++;
                    }
                }
                if (t.ActivityDate != null && (lastTaskDate == null || t.ActivityDate > lastTaskDate)) {
                    lastTaskDate = t.ActivityDate;
                }
                if (recentTasks.size() < 5) {
                    Map<String, Object> ti = new Map<String, Object>();
                    ti.put('subject', t.Subject);
                    ti.put('status', t.Status);
                    ti.put('date', t.ActivityDate != null ? String.valueOf(t.ActivityDate) : null);
                    ti.put('opportunityName', t.What.Name);
                    ti.put('type', t.Type);
                    ti.put('owner', t.Owner.Name);
                    recentTasks.add(ti);
                }
            }

            Map<String, Object> taskSummary = new Map<String, Object>();
            taskSummary.put('total', totalTasks);
            taskSummary.put('open', openTasks);
            taskSummary.put('completed', completedTasks);
            taskSummary.put('overdue', overdueTasks);
            taskSummary.put('lastActivityDate', lastTaskDate != null ? String.valueOf(lastTaskDate) : null);
            taskSummary.put('recentTasks', recentTasks);

            // Event analysis
            Integer totalEvents = events.size();
            Integer upcomingEvents = 0;
            Integer pastEvents = 0;
            List<Map<String, Object>> upcomingList = new List<Map<String, Object>>();
            Date lastEventDate = null;

            for (Event e : events) {
                Date eventDate = e.StartDateTime != null ? e.StartDateTime.date() : null;
                if (eventDate != null && eventDate >= today) {
                    upcomingEvents++;
                    if (upcomingList.size() < 5) {
                        Map<String, Object> ei = new Map<String, Object>();
                        ei.put('subject', e.Subject);
                        ei.put('startDateTime', String.valueOf(e.StartDateTime));
                        ei.put('opportunityName', e.What.Name);
                        ei.put('type', e.Type);
                        ei.put('owner', e.Owner.Name);
                        upcomingList.add(ei);
                    }
                } else {
                    pastEvents++;
                }
                if (eventDate != null && (lastEventDate == null || eventDate > lastEventDate)) {
                    lastEventDate = eventDate;
                }
            }

            Map<String, Object> eventSummary = new Map<String, Object>();
            eventSummary.put('total', totalEvents);
            eventSummary.put('upcoming', upcomingEvents);
            eventSummary.put('past', pastEvents);
            eventSummary.put('lastEventDate', lastEventDate != null ? String.valueOf(lastEventDate) : null);
            eventSummary.put('upcomingEvents', upcomingList);

            // Engagement score (simple heuristic)
            Integer daysSinceLastActivity = 999;
            if (lastTaskDate != null) {
                daysSinceLastActivity = Math.min(daysSinceLastActivity, lastTaskDate.daysBetween(today));
            }
            if (lastEventDate != null) {
                daysSinceLastActivity = Math.min(daysSinceLastActivity, lastEventDate.daysBetween(today));
            }

            String engagementLevel;
            if (daysSinceLastActivity <= 7) {
                engagementLevel = 'High';
            } else if (daysSinceLastActivity <= 30) {
                engagementLevel = 'Medium';
            } else if (daysSinceLastActivity <= 90) {
                engagementLevel = 'Low';
            } else {
                engagementLevel = 'Inactive';
            }

            analysis.put('tasks', taskSummary);
            analysis.put('events', eventSummary);
            analysis.put('engagementLevel', engagementLevel);
            analysis.put('daysSinceLastActivity', daysSinceLastActivity < 999 ? daysSinceLastActivity : null);

            res.activityInfo = JSON.serialize(analysis);
            results.add(res);
        }
        return results;
    }
}
