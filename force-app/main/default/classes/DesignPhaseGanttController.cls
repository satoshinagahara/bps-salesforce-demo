public with sharing class DesignPhaseGanttController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getGanttData(Id recordId) {
        Map<String, Object> result = new Map<String, Object>();

        // Project info
        Design_Project__c proj = [
            SELECT Id, Project_Name__c, Status__c,
                   Planned_Start__c, Planned_End__c,
                   Actual_Start__c, Actual_End__c,
                   Project_Manager__r.Name
            FROM Design_Project__c
            WHERE Id = :recordId
            LIMIT 1
        ];
        result.put('project', proj);

        // Phases
        List<Design_Phase__c> phases = [
            SELECT Id, Name, Phase_Order__c,
                   Planned_Start__c, Planned_End__c,
                   Actual_Start__c, Actual_End__c,
                   Status__c, Gate_Result__c, Gate_Date__c,
                   Owner__c, Owner__r.Name, Notes__c
            FROM Design_Phase__c
            WHERE Design_Project__c = :recordId
            ORDER BY Phase_Order__c ASC
        ];

        // Build phase list with computed fields
        List<Map<String, Object>> phaseList = new List<Map<String, Object>>();
        Integer completedCount = 0;
        Integer delayedCount = 0;
        Date nextGateDate = null;
        Date earliest = null;
        Date latest = null;

        for (Design_Phase__c ph : phases) {
            Map<String, Object> p = new Map<String, Object>();
            p.put('id', ph.Id);
            p.put('name', ph.Name);
            p.put('order', ph.Phase_Order__c);
            p.put('plannedStart', ph.Planned_Start__c);
            p.put('plannedEnd', ph.Planned_End__c);
            p.put('actualStart', ph.Actual_Start__c);
            p.put('actualEnd', ph.Actual_End__c);
            p.put('status', ph.Status__c);
            p.put('gateResult', ph.Gate_Result__c);
            p.put('gateDate', ph.Gate_Date__c);
            p.put('ownerName', ph.Owner__r != null ? ph.Owner__r.Name : null);

            phaseList.add(p);

            if (ph.Status__c == '完了') completedCount++;
            if (ph.Status__c == '遅延') delayedCount++;

            // Next gate: earliest未実施 gate with planned end
            if (ph.Gate_Result__c == '未実施' && ph.Planned_End__c != null) {
                if (nextGateDate == null || ph.Planned_End__c < nextGateDate) {
                    nextGateDate = ph.Planned_End__c;
                }
            }

            // Timeline range
            if (ph.Planned_Start__c != null) {
                if (earliest == null || ph.Planned_Start__c < earliest) earliest = ph.Planned_Start__c;
            }
            if (ph.Actual_Start__c != null) {
                if (earliest == null || ph.Actual_Start__c < earliest) earliest = ph.Actual_Start__c;
            }
            if (ph.Planned_End__c != null) {
                if (latest == null || ph.Planned_End__c > latest) latest = ph.Planned_End__c;
            }
            if (ph.Actual_End__c != null) {
                if (latest == null || ph.Actual_End__c > latest) latest = ph.Actual_End__c;
            }
        }

        result.put('phases', phaseList);
        result.put('totalPhases', phases.size());
        result.put('completedPhases', completedCount);
        result.put('delayedPhases', delayedCount);
        result.put('nextGateDate', nextGateDate);
        result.put('timelineStart', earliest);
        result.put('timelineEnd', latest);
        result.put('today', Date.today());

        return result;
    }
}
