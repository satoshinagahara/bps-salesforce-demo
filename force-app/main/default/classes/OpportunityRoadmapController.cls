public with sharing class OpportunityRoadmapController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getRoadmapData(Id opportunityId) {
        Map<String, Object> result = new Map<String, Object>();

        // 商談の製品ファミリーを取得
        Set<String> families = new Set<String>();
        Set<Id> productIds = new Set<Id>();
        for (OpportunityLineItem oli : [
            SELECT Product2Id, Product2.Family, Product2.Name
            FROM OpportunityLineItem
            WHERE OpportunityId = :opportunityId
                AND Product2Id != null
        ]) {
            productIds.add(oli.Product2Id);
            if (oli.Product2.Family != null) {
                families.add(oli.Product2.Family);
            }
        }

        if (families.isEmpty() && productIds.isEmpty()) {
            result.put('initiatives', new List<Map<String, Object>>());
            result.put('designProjects', new List<Map<String, Object>>());
            result.put('families', new List<String>());
            return result;
        }

        result.put('families', new List<String>(families));

        // 関連する製品施策を取得（同じProduct Familyまたは同じProduct）
        List<Product_Initiative__c> initiatives = [
            SELECT Id, Name, Title__c, Status__c, Priority__c,
                   Product__r.Name, Product__r.Family,
                   Target_Start__c, Target_Release__c,
                   What_Description__c
            FROM Product_Initiative__c
            WHERE (Product__r.Family IN :families OR Product__c IN :productIds)
                AND Status__c NOT IN ('不採用', '完了')
            ORDER BY Priority__c, Status__c
        ];

        List<Map<String, Object>> initList = new List<Map<String, Object>>();
        Set<Id> initiativeIds = new Set<Id>();
        for (Product_Initiative__c pi : initiatives) {
            initiativeIds.add(pi.Id);
            Map<String, Object> m = new Map<String, Object>();
            m.put('id', pi.Id);
            m.put('name', pi.Name);
            m.put('title', pi.Title__c);
            m.put('status', pi.Status__c);
            m.put('priority', pi.Priority__c);
            m.put('product', pi.Product__r != null ? pi.Product__r.Name : '');
            m.put('family', pi.Product__r != null ? pi.Product__r.Family : '');
            m.put('targetStart', pi.Target_Start__c);
            m.put('targetRelease', pi.Target_Release__c);
            m.put('description', pi.What_Description__c != null
                ? (pi.What_Description__c.length() > 200
                    ? pi.What_Description__c.substring(0, 200) + '...'
                    : pi.What_Description__c)
                : '');
            initList.add(m);
        }
        result.put('initiatives', initList);

        // 関連する設計開発プロジェクトを取得（施策経由 + 同じProduct Family）
        List<Design_Project__c> projects = [
            SELECT Id, Name, Project_Name__c, Status__c,
                   Product__r.Name, Product__r.Family,
                   Initiative__r.Name, Initiative__r.Title__c,
                   Planned_Start__c, Planned_End__c
            FROM Design_Project__c
            WHERE (Product__r.Family IN :families OR Product__c IN :productIds
                   OR Initiative__c IN :initiativeIds)
                AND Status__c != '完了'
            ORDER BY Status__c, Planned_Start__c
        ];

        List<Map<String, Object>> projList = new List<Map<String, Object>>();
        for (Design_Project__c dp : projects) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('id', dp.Id);
            m.put('name', dp.Name);
            m.put('projectName', dp.Project_Name__c);
            m.put('status', dp.Status__c);
            m.put('product', dp.Product__r != null ? dp.Product__r.Name : '');
            m.put('family', dp.Product__r != null ? dp.Product__r.Family : '');
            m.put('initiative', dp.Initiative__r != null ? dp.Initiative__r.Title__c : '');
            m.put('initiativeName', dp.Initiative__r != null ? dp.Initiative__r.Name : '');
            m.put('startDate', dp.Planned_Start__c);
            m.put('targetEndDate', dp.Planned_End__c);
            projList.add(m);
        }
        result.put('designProjects', projList);

        return result;
    }
}
