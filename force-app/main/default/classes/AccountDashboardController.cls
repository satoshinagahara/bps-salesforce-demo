public with sharing class AccountDashboardController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getDashboardData(Id accountId) {
        Map<String, Object> result = new Map<String, Object>();

        // ---- Account ----
        Account acc = [
            SELECT Id, Name, Industry, Type, Phone, Website,
                   BillingCity, BillingCountry,
                   AnnualRevenue, NumberOfEmployees, Rating,
                   Owner.Name
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];
        result.put('account', acc);

        // ---- Opportunities ----
        List<Opportunity> opps = [
            SELECT Id, StageName, Amount, CloseDate, IsClosed, IsWon
            FROM Opportunity
            WHERE AccountId = :accountId
        ];

        Map<String, Decimal> stageAmount = new Map<String, Decimal>();
        Map<String, Integer> stageCount  = new Map<String, Integer>();
        Decimal totalAmount = 0;
        Integer wonCount = 0, lostCount = 0, openCount = 0;

        for (Opportunity opp : opps) {
            String stage = opp.StageName;
            Decimal amt  = opp.Amount != null ? opp.Amount : 0;
            stageAmount.put(stage, (stageAmount.containsKey(stage) ? stageAmount.get(stage) : 0) + amt);
            stageCount .put(stage, (stageCount .containsKey(stage) ? stageCount .get(stage) : 0) + 1);
            totalAmount += amt;
            if      (opp.IsWon)    wonCount++;
            else if (opp.IsClosed) lostCount++;
            else                   openCount++;
        }

        // ---- Cases ----
        List<Case> cases = [
            SELECT Id, Status, Priority, IsClosed
            FROM Case
            WHERE AccountId = :accountId
        ];

        Map<String, Integer> caseByStatus   = new Map<String, Integer>();
        Map<String, Integer> caseByPriority = new Map<String, Integer>();
        Integer openCases = 0, closedCases = 0;

        for (Case c : cases) {
            String st  = c.Status;
            String pri = c.Priority != null ? c.Priority : 'Medium';
            caseByStatus  .put(st,  (caseByStatus  .containsKey(st)  ? caseByStatus  .get(st)  : 0) + 1);
            caseByPriority.put(pri, (caseByPriority.containsKey(pri) ? caseByPriority.get(pri) : 0) + 1);
            if (c.IsClosed) closedCases++; else openCases++;
        }

        // ---- Contacts ----
        Integer contactCount = [SELECT COUNT() FROM Contact WHERE AccountId = :accountId];

        // ---- Recent Activities (90 days) ----
        Integer recentTasks = [
            SELECT COUNT() FROM Task
            WHERE WhatId = :accountId
            AND CreatedDate >= :Datetime.now().addDays(-90)
        ];

        // ---- Build result ----
        result.put('oppTotal',       opps.size());
        result.put('oppAmount',      totalAmount);
        result.put('oppWon',         wonCount);
        result.put('oppLost',        lostCount);
        result.put('oppOpen',        openCount);
        result.put('stageAmount',    stageAmount);
        result.put('stageCount',     stageCount);
        result.put('caseTotal',      cases.size());
        result.put('caseOpen',       openCases);
        result.put('caseClosed',     closedCases);
        result.put('caseByStatus',   caseByStatus);
        result.put('caseByPriority', caseByPriority);
        result.put('contactCount',   contactCount);
        result.put('recentTasks',    recentTasks);

        return result;
    }
}
