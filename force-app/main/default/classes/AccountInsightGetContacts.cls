public class AccountInsightGetContacts {

    public class Request {
        @InvocableVariable(label='取引先ID' description='取引先のSalesforce ID' required=true)
        public String accountId;
    }

    public class Result {
        @InvocableVariable(label='取引先責任者情報')
        public String contactInfo;
    }

    @InvocableMethod(label='取引先責任者一覧取得' description='取引先の責任者一覧を役職・部門情報付きで返します')
    public static List<Result> getContacts(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            List<Contact> contacts = [
                SELECT Id, Name, Title, Department, Email, Phone, MobilePhone,
                       LastActivityDate, CreatedDate
                FROM Contact
                WHERE AccountId = :req.accountId
                ORDER BY LastModifiedDate DESC
                LIMIT 20
            ];
            Map<String, Object> analysis = new Map<String, Object>();
            analysis.put('totalCount', contacts.size());

            if (contacts.isEmpty()) {
                analysis.put('summary', '関連する取引先責任者はいません。');
            } else {
                List<Map<String, Object>> contactList = new List<Map<String, Object>>();
                for (Contact c : contacts) {
                    Map<String, Object> ci = new Map<String, Object>();
                    ci.put('name', c.Name);
                    ci.put('title', c.Title);
                    ci.put('department', c.Department);
                    ci.put('email', c.Email);
                    ci.put('phone', c.Phone != null ? c.Phone : c.MobilePhone);
                    ci.put('lastActivityDate', c.LastActivityDate != null ? String.valueOf(c.LastActivityDate) : null);
                    contactList.add(ci);
                }
                analysis.put('contacts', contactList);
            }

            res.contactInfo = JSON.serialize(analysis);
            results.add(res);
        }
        return results;
    }
}
