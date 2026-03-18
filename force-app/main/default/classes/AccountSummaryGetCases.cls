public class AccountSummaryGetCases {

    public class Request {
        @InvocableVariable(label='取引先名' description='ケースを取得する取引先の名前（部分一致）' required=true)
        public String accountName;
    }

    public class Result {
        @InvocableVariable(label='ケース情報')
        public String caseInfo;
    }

    @InvocableMethod(label='関連ケース取得' description='取引先に紐づくサポートケースの一覧を返します')
    public static List<Result> getCases(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            String keyword = '%' + req.accountName + '%';
            List<Case> cases = [
                SELECT CaseNumber, Subject, Status, Priority, Origin, CreatedDate, Description
                FROM Case
                WHERE Account.Name LIKE :keyword
                ORDER BY CreatedDate DESC
                LIMIT 10
            ];
            if (cases.isEmpty()) {
                res.caseInfo = '関連するケースはありません。';
            } else {
                Integer open = 0;
                String info = '【ケース一覧】(' + cases.size() + '件)\n';
                for (Case c : cases) {
                    info += '  ・[' + c.CaseNumber + '] ' + (c.Subject != null ? c.Subject : '件名なし') + '\n';
                    info += '    ステータス: ' + c.Status + '\n';
                    info += '    優先度: ' + (c.Priority != null ? c.Priority : '未設定') + '\n';
                    info += '    作成日: ' + String.valueOf(c.CreatedDate.date()) + '\n\n';
                    if (c.Status != 'Closed') open++;
                }
                info += '  未解決件数: ' + open + '件\n';
                res.caseInfo = info;
            }
            results.add(res);
        }
        return results;
    }
}
