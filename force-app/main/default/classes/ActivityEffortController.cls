public with sharing class ActivityEffortController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getEffortData(Id recordId) {
        Map<String, Object> result = new Map<String, Object>();

        // ---- Events (duration calculable) ----
        List<Event> events = [
            SELECT Id, OwnerId, Owner.Name, Subject,
                   StartDateTime, EndDateTime, DurationInMinutes
            FROM Event
            WHERE WhatId = :recordId
            ORDER BY StartDateTime ASC
        ];

        // ---- Tasks ----
        List<Task> tasks = [
            SELECT Id, OwnerId, Owner.Name, Subject, ActivityDate
            FROM Task
            WHERE WhatId = :recordId
            ORDER BY ActivityDate ASC
        ];

        // ---- Aggregate by member ----
        Map<Id, String> memberNames = new Map<Id, String>();
        Map<Id, Decimal> memberMinutes = new Map<Id, Decimal>();
        Map<Id, Integer> memberEventCount = new Map<Id, Integer>();
        Map<Id, Integer> memberTaskCount = new Map<Id, Integer>();

        Decimal totalMinutes = 0;

        for (Event ev : events) {
            Id oid = ev.OwnerId;
            memberNames.put(oid, ev.Owner.Name);

            Decimal mins = 0;
            if (ev.DurationInMinutes != null) {
                mins = ev.DurationInMinutes;
            } else if (ev.StartDateTime != null && ev.EndDateTime != null) {
                Long diff = ev.EndDateTime.getTime() - ev.StartDateTime.getTime();
                mins = Decimal.valueOf(diff) / 60000;
            }

            memberMinutes.put(oid, (memberMinutes.containsKey(oid) ? memberMinutes.get(oid) : 0) + mins);
            memberEventCount.put(oid, (memberEventCount.containsKey(oid) ? memberEventCount.get(oid) : 0) + 1);
            totalMinutes += mins;
        }

        for (Task t : tasks) {
            Id oid = t.OwnerId;
            memberNames.put(oid, t.Owner.Name);
            if (!memberMinutes.containsKey(oid)) {
                memberMinutes.put(oid, 0);
            }
            if (!memberEventCount.containsKey(oid)) {
                memberEventCount.put(oid, 0);
            }
            memberTaskCount.put(oid, (memberTaskCount.containsKey(oid) ? memberTaskCount.get(oid) : 0) + 1);
        }

        // ---- Build member list ----
        List<Map<String, Object>> members = new List<Map<String, Object>>();
        for (Id oid : memberNames.keySet()) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('userId', oid);
            m.put('name', memberNames.get(oid));
            m.put('minutes', memberMinutes.get(oid));
            m.put('eventCount', memberEventCount.containsKey(oid) ? memberEventCount.get(oid) : 0);
            m.put('taskCount', memberTaskCount.containsKey(oid) ? memberTaskCount.get(oid) : 0);
            members.add(m);
        }

        // Sort by minutes desc
        members.sort(new MemberMinutesSorter());

        // ---- Date range ----
        Datetime earliest = null;
        Datetime latest = null;
        for (Event ev : events) {
            if (ev.StartDateTime != null) {
                if (earliest == null || ev.StartDateTime < earliest) earliest = ev.StartDateTime;
                if (ev.EndDateTime != null && ev.EndDateTime > latest) latest = ev.EndDateTime;
                else if (latest == null || ev.StartDateTime > latest) latest = ev.StartDateTime;
            }
        }
        for (Task t : tasks) {
            if (t.ActivityDate != null) {
                Datetime tdt = Datetime.newInstance(t.ActivityDate, Time.newInstance(0, 0, 0, 0));
                if (earliest == null || tdt < earliest) earliest = tdt;
                if (latest == null || tdt > latest) latest = tdt;
            }
        }

        result.put('totalMinutes', totalMinutes);
        result.put('totalEvents', events.size());
        result.put('totalTasks', tasks.size());
        result.put('memberCount', memberNames.size());
        result.put('members', members);
        result.put('earliestDate', earliest != null ? earliest.format('yyyy/MM/dd') : null);
        result.put('latestDate', latest != null ? latest.format('yyyy/MM/dd') : null);

        return result;
    }

    // Custom comparator for sorting members by minutes desc
    private class MemberMinutesSorter implements Comparator<Map<String, Object>> {
        public Integer compare(Map<String, Object> a, Map<String, Object> b) {
            Decimal mA = (Decimal) a.get('minutes');
            Decimal mB = (Decimal) b.get('minutes');
            if (mA == mB) return 0;
            return mA > mB ? -1 : 1;
        }
    }
}
