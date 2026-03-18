public with sharing class UniversalTableEditorController {

    private static final Set<String> STANDARD_WHITELIST = new Set<String>{
        'Account', 'Contact', 'Opportunity', 'Case', 'Lead', 'Product2',
        'Task', 'Event', 'Campaign', 'Quote', 'Contract', 'Order',
        'Asset', 'Pricebook2', 'PricebookEntry', 'User'
    };

    // ── オブジェクト一覧取得 ──────────────────────────────────────────────
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getObjectList() {
        List<Map<String, String>> result = new List<Map<String, String>>();
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();

        // カスタムオブジェクト（システム系を除外）
        Set<String> systemSuffixes = new Set<String>{
            '__history', '__share', '__feed', '__changeevent',
            '__ownersharingrule', '__tag', '__kav'
        };
        for (String key : gd.keySet()) {
            if (!key.endsWith('__c')) continue;
            boolean skip = false;
            for (String sfx : systemSuffixes) {
                if (key.endsWith(sfx)) { skip = true; break; }
            }
            if (skip) continue;
            Schema.DescribeSObjectResult dr = gd.get(key).getDescribe();
            if (!dr.isQueryable() || !dr.isAccessible()) continue;
            result.add(new Map<String, String>{
                'label' => dr.getLabel() + '  (' + dr.getName() + ')',
                'value' => dr.getName()
            });
        }

        // 標準オブジェクト（ホワイトリスト）
        for (String stdName : STANDARD_WHITELIST) {
            Schema.SObjectType sType = gd.get(stdName.toLowerCase());
            if (sType == null) continue;
            Schema.DescribeSObjectResult dr = sType.getDescribe();
            if (!dr.isQueryable() || !dr.isAccessible()) continue;
            result.add(new Map<String, String>{
                'label' => dr.getLabel() + '  (' + dr.getName() + ')',
                'value' => dr.getName()
            });
        }
        return result;
    }

    // ── フィールドスキーマ取得 ────────────────────────────────────────────
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getObjectSchema(String objectApiName) {
        Schema.SObjectType sType = Schema.getGlobalDescribe().get(objectApiName.toLowerCase());
        if (sType == null) throw new AuraHandledException('オブジェクトが見つかりません: ' + objectApiName);
        Schema.DescribeSObjectResult dr = sType.getDescribe();
        if (!dr.isAccessible()) throw new AuraHandledException('アクセス権がありません');

        List<Map<String, Object>> fields = new List<Map<String, Object>>();
        for (String key : dr.fields.getMap().keySet()) {
            Schema.DescribeFieldResult fr = dr.fields.getMap().get(key).getDescribe();
            if (!fr.isAccessible()) continue;
            Schema.DisplayType dt = fr.getType();
            // システム的な内部型は除外
            if (dt == Schema.DisplayType.BASE64 || dt == Schema.DisplayType.ENCRYPTEDSTRING) continue;

            String colType = resolveColType(dt);
            boolean editable = fr.isUpdateable()
                && dt != Schema.DisplayType.REFERENCE
                && dt != Schema.DisplayType.ID;

            Map<String, Object> f = new Map<String, Object>{
                'fieldName'   => fr.getName(),
                'label'       => fr.getLabel(),
                'type'        => colType,
                'sfType'      => String.valueOf(dt).toLowerCase(),
                'editable'    => editable,
                'isNameField' => fr.isNameField(),
                'scale'       => fr.getScale()
            };
            if (dt == Schema.DisplayType.PICKLIST || dt == Schema.DisplayType.MULTIPICKLIST) {
                List<String> vals = new List<String>();
                for (Schema.PicklistEntry pe : fr.getPicklistValues()) {
                    if (pe.isActive()) vals.add(pe.getValue());
                }
                f.put('picklistValues', vals);
            }
            fields.add(f);
        }
        return fields;
    }

    // ── レコード取得 ──────────────────────────────────────────────────────
    @AuraEnabled
    public static List<Map<String, Object>> getRecords(
        String objectApiName, String fieldsCsv, Integer limitSize
    ) {
        Schema.SObjectType sType = Schema.getGlobalDescribe().get(objectApiName.toLowerCase());
        if (sType == null) throw new AuraHandledException('Invalid object: ' + objectApiName);
        Map<String, Schema.SObjectField> fieldMap = sType.getDescribe().fields.getMap();

        // フィールドを検証してリスト構築
        List<String> safeFields = new List<String>{'Id'};
        if (String.isNotBlank(fieldsCsv)) {
            for (String f : fieldsCsv.split(',')) {
                String lower = f.trim().toLowerCase();
                if (lower == 'id') continue;
                if (fieldMap.containsKey(lower)) {
                    Schema.DescribeFieldResult fr = fieldMap.get(lower).getDescribe();
                    if (fr.isAccessible()) safeFields.add(fr.getName());
                }
            }
        }

        Integer lim = (limitSize != null && limitSize >= 1 && limitSize <= 200) ? limitSize : 50;
        String soql = 'SELECT ' + String.join(safeFields, ', ')
                    + ' FROM ' + String.escapeSingleQuotes(objectApiName)
                    + ' ORDER BY CreatedDate DESC LIMIT ' + lim;

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (SObject rec : Database.query(soql)) {
            Map<String, Object> row = new Map<String, Object>();
            for (String f : safeFields) { row.put(f, rec.get(f)); }
            result.add(row);
        }
        return result;
    }

    // ── レコード更新 ──────────────────────────────────────────────────────
    @AuraEnabled
    public static void updateRecords(String objectApiName, List<Map<String, Object>> changedRows) {
        if (changedRows == null || changedRows.isEmpty()) return;
        Schema.SObjectType sType = Schema.getGlobalDescribe().get(objectApiName.toLowerCase());
        if (sType == null) throw new AuraHandledException('Invalid object: ' + objectApiName);
        Map<String, Schema.SObjectField> fieldMap = sType.getDescribe().fields.getMap();

        List<SObject> toUpdate = new List<SObject>();
        for (Map<String, Object> row : changedRows) {
            Object rawId = row.get('Id');
            if (rawId == null) continue;
            SObject sObj = sType.newSObject(Id.valueOf(String.valueOf(rawId)));
            for (String field : row.keySet()) {
                if (field.equalsIgnoreCase('Id')) continue;
                String lower = field.toLowerCase();
                if (!fieldMap.containsKey(lower)) continue;
                Schema.DescribeFieldResult fr = fieldMap.get(lower).getDescribe();
                if (!fr.isUpdateable()) continue;
                sObj.put(fr.getName(), coerceValue(row.get(field), fr.getType()));
            }
            toUpdate.add(sObj);
        }
        if (!toUpdate.isEmpty()) {
            try {
                update toUpdate;
            } catch (DmlException e) {
                throw new AuraHandledException(e.getDmlMessage(0));
            }
        }
    }

    // ── ヘルパー ──────────────────────────────────────────────────────────
    private static String resolveColType(Schema.DisplayType dt) {
        if (dt == Schema.DisplayType.CURRENCY)  return 'currency';
        if (dt == Schema.DisplayType.PERCENT)   return 'percent';
        if (dt == Schema.DisplayType.INTEGER || dt == Schema.DisplayType.DOUBLE) return 'number';
        if (dt == Schema.DisplayType.BOOLEAN)   return 'boolean';
        if (dt == Schema.DisplayType.DATE)      return 'date-local';
        if (dt == Schema.DisplayType.DATETIME)  return 'date';
        if (dt == Schema.DisplayType.EMAIL)     return 'email';
        if (dt == Schema.DisplayType.URL)       return 'url';
        if (dt == Schema.DisplayType.PHONE)     return 'phone';
        return 'text';
    }

    private static Object coerceValue(Object val, Schema.DisplayType dt) {
        if (val == null) return null;
        String s = String.valueOf(val).trim();
        if (String.isBlank(s)) return null;
        try {
            if (dt == Schema.DisplayType.DOUBLE || dt == Schema.DisplayType.CURRENCY
                    || dt == Schema.DisplayType.PERCENT)  return Decimal.valueOf(s);
            if (dt == Schema.DisplayType.INTEGER)         return Integer.valueOf(s);
            if (dt == Schema.DisplayType.BOOLEAN)         return Boolean.valueOf(s);
            if (dt == Schema.DisplayType.DATE)            return Date.valueOf(s.substringBefore('T'));
            if (dt == Schema.DisplayType.DATETIME) {
                String dt2 = s.replace('T', ' ').replaceAll('\\.\\d+Z?$', '');
                return Datetime.valueOf(dt2);
            }
        } catch (Exception e) { return null; }
        return val;
    }
}
