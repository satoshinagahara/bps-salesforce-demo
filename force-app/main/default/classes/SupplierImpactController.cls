public with sharing class SupplierImpactController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getSupplierImpact(Id accountId) {

        List<BOM_Part__c> parts = [
            SELECT Id, Part_Number__c, Part_Name__c, Extended_Cost__c,
                   Unit_Cost__c, Quantity__c, Unit_of_Measure__c, Manufacturer__c,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.ProductCode,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Total_Cost__c
            FROM BOM_Part__c
            WHERE Supplier__c = :accountId
            ORDER BY Part_Number__c
        ];

        Map<String, Object> result = new Map<String, Object>();
        if (parts.isEmpty()) {
            result.put('products', new List<Map<String, Object>>());
            result.put('parts', new List<Map<String, Object>>());
            result.put('totalParts', 0);
            result.put('totalProducts', 0);
            result.put('totalSupplyCost', 0);
            result.put('sharedPartCount', 0);
            result.put('totalCapacityAlerts', 0);
            return result;
        }

        // 部品番号を収集（キャパシティ検索用）
        Set<String> allPartNumbers = new Set<String>();
        for (BOM_Part__c p : parts) {
            if (p.Part_Number__c != null) allPartNumbers.add(p.Part_Number__c);
        }

        // キャパシティデータ取得
        Map<String, Supplier_Capacity__c> capByPartNumber = new Map<String, Supplier_Capacity__c>();
        if (!allPartNumbers.isEmpty()) {
            List<Supplier_Capacity__c> caps = [
                SELECT Part_Number__c, Monthly_Capacity__c,
                       Manufacturing_Site__c, Manufacturing_Site__r.Name
                FROM Supplier_Capacity__c
                WHERE Part_Number__c IN :allPartNumbers
                  AND (Effective_To__c = null OR Effective_To__c >= TODAY)
                  AND Effective_From__c <= TODAY
            ];
            for (Supplier_Capacity__c sc : caps) {
                // 部品番号ごとに1件（複数サイトある場合は最初のもの）
                if (!capByPartNumber.containsKey(sc.Part_Number__c)) {
                    capByPartNumber.put(sc.Part_Number__c, sc);
                }
            }
        }

        // Aggregate per product
        Map<Id, Map<String, Object>> productMap = new Map<Id, Map<String, Object>>();
        Map<String, Set<Id>> partToProducts = new Map<String, Set<Id>>();
        List<Map<String, Object>> partList = new List<Map<String, Object>>();
        Decimal totalSupplyCost = 0;
        Map<Id, Integer> capacityAlertsByProduct = new Map<Id, Integer>();
        Map<Id, Boolean> hasCapacityDataByProduct = new Map<Id, Boolean>();

        for (BOM_Part__c p : parts) {
            Id productId = p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c;
            String productName = p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name;
            String productCode = p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.ProductCode;
            Decimal bomTotalCost = p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Total_Cost__c;

            Decimal extCost = p.Extended_Cost__c != null ? p.Extended_Cost__c : 0;
            totalSupplyCost += extCost;

            if (!productMap.containsKey(productId)) {
                Map<String, Object> prod = new Map<String, Object>();
                prod.put('productId', productId);
                prod.put('productName', productName);
                prod.put('productCode', productCode);
                prod.put('bomTotalCost', bomTotalCost != null ? bomTotalCost : 0);
                prod.put('supplierCost', (Decimal)0);
                prod.put('partCount', 0);
                productMap.put(productId, prod);
                capacityAlertsByProduct.put(productId, 0);
                hasCapacityDataByProduct.put(productId, false);
            }
            Map<String, Object> prod = productMap.get(productId);
            prod.put('supplierCost', (Decimal)prod.get('supplierCost') + extCost);
            prod.put('partCount', (Integer)prod.get('partCount') + 1);

            // キャパシティチェック（稼働率80%超をアラート）
            if (p.Part_Number__c != null && capByPartNumber.containsKey(p.Part_Number__c)) {
                hasCapacityDataByProduct.put(productId, true);
                Supplier_Capacity__c cap = capByPartNumber.get(p.Part_Number__c);
                if (cap.Monthly_Capacity__c != null && cap.Monthly_Capacity__c > 0) {
                    // 簡易稼働率: 部品数量をキャパシティ比で推定
                    Decimal qty = p.Quantity__c != null ? p.Quantity__c : 0;
                    Decimal utilization = qty / cap.Monthly_Capacity__c * 100;
                    if (utilization > 80) {
                        Integer alerts = capacityAlertsByProduct.get(productId);
                        capacityAlertsByProduct.put(productId, alerts + 1);
                    }
                }
            }

            // Track shared parts
            if (p.Part_Number__c != null) {
                if (!partToProducts.containsKey(p.Part_Number__c))
                    partToProducts.put(p.Part_Number__c, new Set<Id>());
                partToProducts.get(p.Part_Number__c).add(productId);
            }

            // Part detail
            Map<String, Object> d = new Map<String, Object>();
            d.put('id', p.Id);
            d.put('partNumber', p.Part_Number__c);
            d.put('partName', p.Part_Name__c);
            d.put('productName', productName);
            d.put('productCode', productCode);
            d.put('quantity', p.Quantity__c);
            d.put('uom', p.Unit_of_Measure__c);
            d.put('unitCost', p.Unit_Cost__c);
            d.put('extendedCost', extCost);
            d.put('leadTime', p.Manufacturer__c);
            Boolean isShared = partToProducts.containsKey(p.Part_Number__c)
                && partToProducts.get(p.Part_Number__c).size() > 1;
            d.put('isShared', isShared);
            partList.add(d);
        }

        // Calculate dependency % and sort desc
        List<Map<String, Object>> products = new List<Map<String, Object>>();
        Integer totalCapacityAlerts = 0;
        for (Id prodId : productMap.keySet()) {
            Map<String, Object> prod = productMap.get(prodId);
            Decimal bomTotal = (Decimal)prod.get('bomTotalCost');
            Decimal supplierCost = (Decimal)prod.get('supplierCost');
            Decimal dependency = (bomTotal > 0)
                ? (supplierCost / bomTotal * 100).setScale(1) : 0;
            prod.put('dependency', dependency);
            prod.put('isHighRisk', dependency >= 20);
            prod.put('hasCapacityData', hasCapacityDataByProduct.get(prodId));
            prod.put('capacityAlerts', capacityAlertsByProduct.get(prodId));
            totalCapacityAlerts += capacityAlertsByProduct.get(prodId);
            products.add(prod);
        }
        for (Integer i = 0; i < products.size(); i++) {
            for (Integer j = i + 1; j < products.size(); j++) {
                if ((Decimal)products.get(j).get('dependency')
                  > (Decimal)products.get(i).get('dependency')) {
                    Map<String, Object> tmp = products.get(i);
                    products.set(i, products.get(j));
                    products.set(j, tmp);
                }
            }
        }

        // Update isShared after all products are processed
        for (Map<String, Object> d : partList) {
            String pn = (String)d.get('partNumber');
            d.put('isShared', pn != null && partToProducts.containsKey(pn)
                && partToProducts.get(pn).size() > 1);
        }

        // Count shared parts
        Integer sharedCount = 0;
        for (Set<Id> prods : partToProducts.values()) {
            if (prods.size() > 1) sharedCount++;
        }

        result.put('products', products);
        result.put('parts', partList);
        result.put('totalParts', parts.size());
        result.put('totalProducts', productMap.size());
        result.put('totalSupplyCost', totalSupplyCost);
        result.put('sharedPartCount', sharedCount);
        result.put('totalCapacityAlerts', totalCapacityAlerts);
        return result;
    }
}
