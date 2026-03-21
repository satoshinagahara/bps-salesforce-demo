public with sharing class BOMAllocationController {

    // === 契約製品一覧（BOM情報付き） ===
    @AuraEnabled(cacheable=true)
    public static List<ProductBomInfo> getProductsWithBom(Id agreementId) {
        List<ProductBomInfo> result = new List<ProductBomInfo>();

        List<Sales_Agreement_Product__c> saps = [
            SELECT Id, Name, Product__c, Product__r.Name, Unit_Price__c,
                   BOM_Header__c, BOM_Header__r.Name, BOM_Header__r.BOM_Number__c,
                   BOM_Header__r.Status__c, BOM_Header__r.Revision__c,
                   BOM_Header__r.Assembly_Site__r.Name
            FROM Sales_Agreement_Product__c
            WHERE Sales_Agreement__c = :agreementId
            ORDER BY Product__r.Name, Name
        ];

        // 月間合計数量を取得
        Set<Id> sapIds = new Set<Id>();
        for (Sales_Agreement_Product__c sap : saps) sapIds.add(sap.Id);

        Map<Id, Double> monthlyAvg = new Map<Id, Double>();
        for (AggregateResult ar : [
            SELECT Sales_Agreement_Product__c sapId,
                   AVG(Plan_Quantity__c) avgQty,
                   COUNT(Id) cnt
            FROM Sales_Agreement_Schedule__c
            WHERE Sales_Agreement_Product__c IN :sapIds
            GROUP BY Sales_Agreement_Product__c
        ]) {
            Id sapId = (Id) ar.get('sapId');
            Double avg = (Double) ar.get('avgQty');
            monthlyAvg.put(sapId, avg);
        }

        // 製品ごとのBOM候補数を取得
        Set<Id> productIds = new Set<Id>();
        for (Sales_Agreement_Product__c sap : saps) {
            if (sap.Product__c != null) productIds.add(sap.Product__c);
        }
        Map<Id, Integer> bomCountByProduct = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Product__c, COUNT(Id) cnt
            FROM BOM_Header__c
            WHERE Product__c IN :productIds
            GROUP BY Product__c
        ]) {
            bomCountByProduct.put((Id) ar.get('Product__c'), (Integer) ar.get('cnt'));
        }

        for (Sales_Agreement_Product__c sap : saps) {
            ProductBomInfo info = new ProductBomInfo();
            info.sapId = sap.Id;
            info.sapName = sap.Name;
            info.productId = sap.Product__c;
            info.productName = sap.Product__r != null ? sap.Product__r.Name : '';
            info.unitPrice = sap.Unit_Price__c;
            info.bomHeaderId = sap.BOM_Header__c;
            info.monthlyQty = monthlyAvg.get(sap.Id);

            if (sap.BOM_Header__r != null && sap.BOM_Header__c != null) {
                info.bomNumber = sap.BOM_Header__r.BOM_Number__c;
                info.bomName = sap.BOM_Header__r.Name;
                info.bomStatus = sap.BOM_Header__r.Status__c;
                info.bomRevision = sap.BOM_Header__r.Revision__c;
                info.assemblySite = sap.BOM_Header__r.Assembly_Site__r != null
                    ? sap.BOM_Header__r.Assembly_Site__r.Name : null;
            }

            info.bomCandidateCount = bomCountByProduct.containsKey(sap.Product__c)
                ? bomCountByProduct.get(sap.Product__c) : 0;
            info.hasBom = sap.BOM_Header__c != null;
            info.needsAttention = !info.hasBom && info.bomCandidateCount > 1;

            result.add(info);
        }
        return result;
    }

    // === BOM候補一覧（製品別） ===
    @AuraEnabled
    public static List<BomCandidate> getBomCandidates(Id productId) {
        List<BomCandidate> result = new List<BomCandidate>();

        List<BOM_Header__c> headers = [
            SELECT Id, Name, BOM_Number__c, Status__c, Revision__c,
                   Assembly_Site__r.Name, Description__c
            FROM BOM_Header__c
            WHERE Product__c = :productId
            ORDER BY Status__c, BOM_Number__c
        ];

        Set<Id> headerIds = new Set<Id>();
        for (BOM_Header__c h : headers) headerIds.add(h.Id);

        // 各BOMの部品数・サプライヤー数を集計
        Map<Id, Integer> partCounts = new Map<Id, Integer>();
        Map<Id, Integer> supplierCounts = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT BOM_SubComponent__r.BOM_Line__r.BOM_Header__c bomId, COUNT(Id) cnt
            FROM BOM_Part__c
            WHERE BOM_SubComponent__r.BOM_Line__r.BOM_Header__c IN :headerIds
            GROUP BY BOM_SubComponent__r.BOM_Line__r.BOM_Header__c
        ]) {
            partCounts.put((Id) ar.get('bomId'), (Integer) ar.get('cnt'));
        }
        for (AggregateResult ar : [
            SELECT BOM_SubComponent__r.BOM_Line__r.BOM_Header__c bomId, COUNT_DISTINCT(Supplier__c) cnt
            FROM BOM_Part__c
            WHERE BOM_SubComponent__r.BOM_Line__r.BOM_Header__c IN :headerIds
              AND Supplier__c != null
            GROUP BY BOM_SubComponent__r.BOM_Line__r.BOM_Header__c
        ]) {
            supplierCounts.put((Id) ar.get('bomId'), (Integer) ar.get('cnt'));
        }

        for (BOM_Header__c h : headers) {
            BomCandidate c = new BomCandidate();
            c.bomHeaderId = h.Id;
            c.bomNumber = h.BOM_Number__c;
            c.bomName = h.Name;
            c.status = h.Status__c;
            c.revision = h.Revision__c;
            c.assemblySite = h.Assembly_Site__r != null ? h.Assembly_Site__r.Name : null;
            c.description = h.Description__c;
            c.partCount = partCounts.containsKey(h.Id) ? partCounts.get(h.Id) : 0;
            c.supplierCount = supplierCounts.containsKey(h.Id) ? supplierCounts.get(h.Id) : 0;
            c.isApproved = h.Status__c == '承認済';
            result.add(c);
        }
        return result;
    }

    // === BOM割当（単一） ===
    @AuraEnabled
    public static void assignBom(Id sapId, Id bomHeaderId) {
        Sales_Agreement_Product__c sap = new Sales_Agreement_Product__c(Id = sapId);
        sap.BOM_Header__c = bomHeaderId;
        update sap;
    }

    // === 行分割 ===
    @AuraEnabled
    public static Id splitProduct(Id sapId, Id newBomHeaderId, Decimal splitRatio) {
        // 1. 元の契約製品を取得
        Sales_Agreement_Product__c original = [
            SELECT Id, Sales_Agreement__c, Product__c, Unit_Price__c, BOM_Header__c
            FROM Sales_Agreement_Product__c
            WHERE Id = :sapId
        ];

        // 2. 新しい契約製品を作成（同一製品、異なるBOM）
        Sales_Agreement_Product__c newSap = new Sales_Agreement_Product__c();
        newSap.Sales_Agreement__c = original.Sales_Agreement__c;
        newSap.Product__c = original.Product__c;
        newSap.Unit_Price__c = original.Unit_Price__c;
        newSap.BOM_Header__c = newBomHeaderId;
        insert newSap;

        // 3. 元のスケジュールを取得
        List<Sales_Agreement_Schedule__c> origSchedules = [
            SELECT Id, Schedule_Month__c, Plan_Quantity__c, Plan_Amount__c,
                   Actual_Quantity__c, Actual_Amount__c
            FROM Sales_Agreement_Schedule__c
            WHERE Sales_Agreement_Product__c = :sapId
            ORDER BY Schedule_Month__c
        ];

        // 4. スケジュールを按分
        Decimal keepRatio = 1 - splitRatio;
        List<Sales_Agreement_Schedule__c> toUpdate = new List<Sales_Agreement_Schedule__c>();
        List<Sales_Agreement_Schedule__c> toInsert = new List<Sales_Agreement_Schedule__c>();

        for (Sales_Agreement_Schedule__c s : origSchedules) {
            Double origQty = s.Plan_Quantity__c != null ? s.Plan_Quantity__c : 0;
            Decimal keepQty = (Decimal.valueOf(origQty) * keepRatio).setScale(0, RoundingMode.HALF_UP);
            Decimal splitQty = Decimal.valueOf(origQty) - keepQty;

            // 元の行を更新
            s.Plan_Quantity__c = keepQty.doubleValue();
            if (original.Unit_Price__c != null) {
                s.Plan_Amount__c = keepQty * original.Unit_Price__c;
            }
            toUpdate.add(s);

            // 新しい行を作成
            Sales_Agreement_Schedule__c newSched = new Sales_Agreement_Schedule__c();
            newSched.Sales_Agreement_Product__c = newSap.Id;
            newSched.Schedule_Month__c = s.Schedule_Month__c;
            newSched.Plan_Quantity__c = splitQty.doubleValue();
            if (original.Unit_Price__c != null) {
                newSched.Plan_Amount__c = splitQty * original.Unit_Price__c;
            }
            toInsert.add(newSched);
        }

        update toUpdate;
        insert toInsert;

        return newSap.Id;
    }

    // === DTOs ===
    public class ProductBomInfo {
        @AuraEnabled public Id sapId;
        @AuraEnabled public String sapName;
        @AuraEnabled public Id productId;
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public Id bomHeaderId;
        @AuraEnabled public String bomNumber;
        @AuraEnabled public String bomName;
        @AuraEnabled public String bomStatus;
        @AuraEnabled public String bomRevision;
        @AuraEnabled public String assemblySite;
        @AuraEnabled public Double monthlyQty;
        @AuraEnabled public Integer bomCandidateCount;
        @AuraEnabled public Boolean hasBom;
        @AuraEnabled public Boolean needsAttention;
    }

    public class BomCandidate {
        @AuraEnabled public Id bomHeaderId;
        @AuraEnabled public String bomNumber;
        @AuraEnabled public String bomName;
        @AuraEnabled public String status;
        @AuraEnabled public String revision;
        @AuraEnabled public String assemblySite;
        @AuraEnabled public String description;
        @AuraEnabled public Integer partCount;
        @AuraEnabled public Integer supplierCount;
        @AuraEnabled public Boolean isApproved;
    }
}
