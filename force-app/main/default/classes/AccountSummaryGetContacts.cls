public class AccountSummaryGetContacts {

    public class Request {
        @InvocableVariable(label='取引先名' description='担当者を取得する取引先の名前（部分一致）' required=true)
        public String accountName;
    }

    public class Result {
        @InvocableVariable(label='取引先責任者情報')
        public String contactInfo;
    }

    @InvocableMethod(label='取引先責任者取得' description='取引先に紐づく取引先責任者の一覧を返します')
    public static List<Result> getContacts(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            String keyword = '%' + req.accountName + '%';
            List<Contact> contacts = [
                SELECT Name, Title, Department, Email, Phone, MobilePhone
                FROM Contact
                WHERE Account.Name LIKE :keyword
                ORDER BY LastModifiedDate DESC
                LIMIT 10
            ];
            if (contacts.isEmpty()) {
                res.contactInfo = '関連する取引先責任者はいません。';
            } else {
                String info = '【取引先責任者一覧】(' + contacts.size() + '名)\n';
                for (Contact c : contacts) {
                    info += '  ・' + c.Name + '\n';
                    info += '    役職: ' + (c.Title != null ? c.Title : '未設定') + '\n';
                    info += '    部門: ' + (c.Department != null ? c.Department : '未設定') + '\n';
                    info += '    メール: ' + (c.Email != null ? c.Email : '未設定') + '\n';
                    info += '    電話: ' + (c.Phone != null ? c.Phone : (c.MobilePhone != null ? c.MobilePhone : '未設定')) + '\n\n';
                }
                res.contactInfo = info;
            }
            results.add(res);
        }
        return results;
    }
}
