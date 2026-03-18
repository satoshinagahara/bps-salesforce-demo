public class AccountInsightGetAccount {

    public class Request {
        @InvocableVariable(label='取引先ID' description='取引先のSalesforce ID' required=true)
        public String accountId;
    }

    public class Result {
        @InvocableVariable(label='取引先情報')
        public String accountInfo;
    }

    @InvocableMethod(label='取引先概要取得' description='取引先IDから基本情報と関連レコード数の統計を返します')
    public static List<Result> getAccount(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            List<Account> accounts = [
                SELECT Id, Name, Industry, Type, AnnualRevenue, NumberOfEmployees,
                       Phone, BillingCity, BillingState, Website, Description, OwnerId, Owner.Name,
                       (SELECT Id FROM Opportunities),
                       (SELECT Id FROM Cases),
                       (SELECT Id FROM Contacts)
                FROM Account
                WHERE Id = :req.accountId
                LIMIT 1
            ];
            if (accounts.isEmpty()) {
                res.accountInfo = '{"error":"取引先が見つかりません: ' + req.accountId + '"}';
            } else {
                Account a = accounts[0];
                Map<String, Object> info = new Map<String, Object>();
                info.put('id', a.Id);
                info.put('name', a.Name);
                info.put('industry', a.Industry);
                info.put('type', a.Type);
                info.put('annualRevenue', a.AnnualRevenue);
                info.put('numberOfEmployees', a.NumberOfEmployees);
                info.put('phone', a.Phone);
                info.put('billingCity', a.BillingCity);
                info.put('billingState', a.BillingState);
                info.put('website', a.Website);
                info.put('description', a.Description);
                info.put('ownerName', a.Owner.Name);
                info.put('opportunityCount', a.Opportunities.size());
                info.put('caseCount', a.Cases.size());
                info.put('contactCount', a.Contacts.size());
                res.accountInfo = JSON.serialize(info);
            }
            results.add(res);
        }
        return results;
    }
}
