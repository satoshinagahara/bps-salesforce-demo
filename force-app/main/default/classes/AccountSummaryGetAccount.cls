public class AccountSummaryGetAccount {

    public class Request {
        @InvocableVariable(label='取引先名' description='検索する取引先の名前（部分一致）' required=true)
        public String accountName;
    }

    public class Result {
        @InvocableVariable(label='取引先情報')
        public String accountInfo;
    }

    @InvocableMethod(label='取引先基本情報取得' description='取引先名で検索し、基本情報を返します')
    public static List<Result> getAccount(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            String keyword = '%' + req.accountName + '%';
            List<Account> accounts = [
                SELECT Id, Name, Industry, AnnualRevenue, NumberOfEmployees,
                       Phone, BillingCity, BillingState, Website, Description
                FROM Account
                WHERE Name LIKE :keyword
                ORDER BY LastModifiedDate DESC
                LIMIT 3
            ];
            if (accounts.isEmpty()) {
                res.accountInfo = '取引先が見つかりませんでした: ' + req.accountName;
            } else {
                String info = '';
                for (Account a : accounts) {
                    info += '【取引先】' + a.Name + '\n';
                    info += '  業種: ' + (a.Industry != null ? a.Industry : '未設定') + '\n';
                    info += '  年間売上: ' + (a.AnnualRevenue != null ? String.valueOf(a.AnnualRevenue) + '円' : '未設定') + '\n';
                    info += '  従業員数: ' + (a.NumberOfEmployees != null ? String.valueOf(a.NumberOfEmployees) + '名' : '未設定') + '\n';
                    info += '  電話: ' + (a.Phone != null ? a.Phone : '未設定') + '\n';
                    info += '  所在地: ' + (a.BillingCity != null ? a.BillingCity : '') + ' ' + (a.BillingState != null ? a.BillingState : '') + '\n';
                    info += '  WebサイT: ' + (a.Website != null ? a.Website : '未設定') + '\n';
                    info += '\n';
                }
                res.accountInfo = info;
            }
            results.add(res);
        }
        return results;
    }
}
