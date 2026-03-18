public class AccountSummaryGetOpportunities {

    public class Request {
        @InvocableVariable(label='取引先名' description='商談を取得する取引先の名前（部分一致）' required=true)
        public String accountName;
    }

    public class Result {
        @InvocableVariable(label='商談情報')
        public String opportunityInfo;
    }

    @InvocableMethod(label='関連商談取得' description='取引先に紐づく商談の一覧を返します')
    public static List<Result> getOpportunities(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            String keyword = '%' + req.accountName + '%';
            List<Opportunity> opps = [
                SELECT Name, StageName, Amount, CloseDate, Probability, OwnerId, Owner.Name
                FROM Opportunity
                WHERE Account.Name LIKE :keyword
                ORDER BY CloseDate ASC
                LIMIT 10
            ];
            if (opps.isEmpty()) {
                res.opportunityInfo = '関連する商談はありません。';
            } else {
                Decimal totalAmount = 0;
                String info = '【商談一覧】(' + opps.size() + '件)\n';
                for (Opportunity o : opps) {
                    info += '  ・' + o.Name + '\n';
                    info += '    フェーズ: ' + o.StageName + '\n';
                    info += '    金額: ' + (o.Amount != null ? String.valueOf(o.Amount) + '円' : '未設定') + '\n';
                    info += '    完了予定: ' + String.valueOf(o.CloseDate) + '\n';
                    info += '    確度: ' + (o.Probability != null ? String.valueOf(o.Probability) + '%' : '-') + '\n';
                    info += '    担当: ' + o.Owner.Name + '\n\n';
                    if (o.Amount != null) totalAmount += o.Amount;
                }
                info += '  合計金額: ' + totalAmount + '円\n';
                res.opportunityInfo = info;
            }
            results.add(res);
        }
        return results;
    }
}
