public with sharing class QualityKPIController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getKPIData() {
        Map<String, Object> result = new Map<String, Object>();
        Date today = Date.today();

        // 全CA取得（必要なフィールドのみ）
        List<Corrective_Action__c> allCAs = [
            SELECT Id, Phase__c, Severity__c, Category__c,
                   Target_Close_Date__c, CreatedDate
            FROM Corrective_Action__c
            ORDER BY CreatedDate DESC
        ];

        // オープン / クローズ分離
        List<Corrective_Action__c> openCAs = new List<Corrective_Action__c>();
        Integer closedCount = 0;
        for (Corrective_Action__c ca : allCAs) {
            if (ca.Phase__c == 'D8 完了') {
                closedCount++;
            } else {
                openCAs.add(ca);
            }
        }

        result.put('totalOpen', openCAs.size());
        result.put('totalClosed', closedCount);
        result.put('totalAll', allCAs.size());

        // 重大度別カウント（オープンのみ）
        Map<String, Integer> bySeverity = new Map<String, Integer>{
            '重大' => 0, '重要' => 0, '軽微' => 0
        };
        for (Corrective_Action__c ca : openCAs) {
            String sev = ca.Severity__c;
            if (sev != null && bySeverity.containsKey(sev)) {
                bySeverity.put(sev, bySeverity.get(sev) + 1);
            }
        }
        result.put('bySeverity', bySeverity);

        // フェーズ別カウント（全CA）
        Map<String, Integer> byPhase = new Map<String, Integer>{
            'D1 チーム編成' => 0, 'D2 問題定義' => 0, 'D3 暫定対応' => 0,
            'D4 原因分析' => 0, 'D5 恒久対策立案' => 0, 'D6 実施・検証' => 0,
            'D7 再発防止' => 0, 'D8 完了' => 0
        };
        for (Corrective_Action__c ca : allCAs) {
            String phase = ca.Phase__c;
            if (phase != null && byPhase.containsKey(phase)) {
                byPhase.put(phase, byPhase.get(phase) + 1);
            }
        }
        result.put('byPhase', byPhase);

        // カテゴリ別カウント（オープンのみ）
        Map<String, Integer> byCategory = new Map<String, Integer>();
        for (Corrective_Action__c ca : openCAs) {
            String cat = ca.Category__c;
            if (cat != null) {
                byCategory.put(cat, (byCategory.containsKey(cat) ? byCategory.get(cat) : 0) + 1);
            }
        }
        result.put('byCategory', byCategory);

        // 期限超過（オープンかつTarget_Close_Date < today）
        Integer overdueCount = 0;
        for (Corrective_Action__c ca : openCAs) {
            if (ca.Target_Close_Date__c != null && ca.Target_Close_Date__c < today) {
                overdueCount++;
            }
        }
        result.put('overdueCount', overdueCount);

        // 今月クローズ予定（オープンかつTarget_Close_Dateが今月中）
        Date monthStart = today.toStartOfMonth();
        Date monthEnd = monthStart.addMonths(1).addDays(-1);
        Integer dueThisMonth = 0;
        for (Corrective_Action__c ca : openCAs) {
            if (ca.Target_Close_Date__c != null
                && ca.Target_Close_Date__c >= monthStart
                && ca.Target_Close_Date__c <= monthEnd) {
                dueThisMonth++;
            }
        }
        result.put('dueThisMonth', dueThisMonth);

        return result;
    }
}
