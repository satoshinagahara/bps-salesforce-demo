public with sharing class DualBOMController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getDualBOMData(Id recordId) {
        Map<String, Object> result = new Map<String, Object>();

        // Get Design Project
        Design_Project__c proj = [
            SELECT Id, Project_Name__c,
                   Product__c, Product__r.Name, Product__r.ProductCode,
                   BOM_Header__c, BOM_Header__r.Name, BOM_Header__r.Revision__c,
                   BOM_Header__r.Status__c, BOM_Header__r.BOM_Type__c,
                   Base_Product__c, Base_Product__r.Name, Base_Product__r.ProductCode,
                   Base_BOM__c, Base_BOM__r.Name, Base_BOM__r.Revision__c,
                   Base_BOM__r.Status__c, Base_BOM__r.BOM_Type__c
            FROM Design_Project__c
            WHERE Id = :recordId
            LIMIT 1
        ];

        // Project info
        Map<String, Object> projInfo = new Map<String, Object>();
        projInfo.put('newProductName', proj.Product__r != null ? proj.Product__r.Name : null);
        projInfo.put('newProductCode', proj.Product__r != null ? proj.Product__r.ProductCode : null);
        projInfo.put('newBomName', proj.BOM_Header__r != null ? proj.BOM_Header__r.Name : null);
        projInfo.put('newBomRevision', proj.BOM_Header__r != null ? proj.BOM_Header__r.Revision__c : null);
        projInfo.put('newBomStatus', proj.BOM_Header__r != null ? proj.BOM_Header__r.Status__c : null);
        projInfo.put('newBomType', proj.BOM_Header__r != null ? proj.BOM_Header__r.BOM_Type__c : null);
        projInfo.put('baseProductName', proj.Base_Product__r != null ? proj.Base_Product__r.Name : null);
        projInfo.put('baseProductCode', proj.Base_Product__r != null ? proj.Base_Product__r.ProductCode : null);
        projInfo.put('baseBomName', proj.Base_BOM__r != null ? proj.Base_BOM__r.Name : null);
        projInfo.put('baseBomRevision', proj.Base_BOM__r != null ? proj.Base_BOM__r.Revision__c : null);
        projInfo.put('baseBomStatus', proj.Base_BOM__r != null ? proj.Base_BOM__r.Status__c : null);
        projInfo.put('baseBomType', proj.Base_BOM__r != null ? proj.Base_BOM__r.BOM_Type__c : null);
        result.put('project', projInfo);

        // Build BOM trees
        if (proj.Base_BOM__c != null) {
            result.put('baseTree', buildBOMTree(proj.Base_BOM__c, true));
        }
        if (proj.BOM_Header__c != null) {
            result.put('newTree', buildBOMTree(proj.BOM_Header__c, false));
        }

        return result;
    }

    private static Map<String, Object> buildBOMTree(Id bomHeaderId, Boolean checkRisks) {
        Map<String, Object> tree = new Map<String, Object>();

        // Lines
        List<BOM_Line__c> lines = [
            SELECT Id, Name, Line_Number__c, Component_Type__c,
                   Component_Product__c, Component_Product__r.Name,
                   Quantity__c, Unit_of_Measure__c
            FROM BOM_Line__c
            WHERE BOM_Header__c = :bomHeaderId
            ORDER BY Line_Number__c ASC
        ];

        // SubComponents
        Set<Id> lineIds = new Set<Id>();
        for (BOM_Line__c l : lines) lineIds.add(l.Id);

        List<BOM_SubComponent__c> subs = [
            SELECT Id, Name, Component_Name__c, BOM_Line__c,
                   Sequence__c, Material_Type__c, Quantity__c
            FROM BOM_SubComponent__c
            WHERE BOM_Line__c IN :lineIds
            ORDER BY Sequence__c ASC
        ];

        // Parts
        Set<Id> subIds = new Set<Id>();
        for (BOM_SubComponent__c s : subs) subIds.add(s.Id);

        List<BOM_Part__c> parts = [
            SELECT Id, Name, Part_Name__c, Part_Number__c, BOM_SubComponent__c,
                   Supplier__c, Supplier__r.Name, Quantity__c,
                   Unit_Cost__c, Make_or_Buy__c
            FROM BOM_Part__c
            WHERE BOM_SubComponent__c IN :subIds
            ORDER BY Name ASC
        ];

        // Risk check: find CAs linked to these parts or their suppliers
        Map<Id, List<Map<String, String>>> partRisks = new Map<Id, List<Map<String, String>>>();
        Map<Id, List<Map<String, String>>> supplierRisks = new Map<Id, List<Map<String, String>>>();

        if (checkRisks) {
            Set<Id> partIds = new Set<Id>();
            Set<Id> supplierIds = new Set<Id>();
            for (BOM_Part__c p : parts) {
                partIds.add(p.Id);
                if (p.Supplier__c != null) supplierIds.add(p.Supplier__c);
            }

            // CAs by BOM_Part
            List<Corrective_Action__c> casByPart = [
                SELECT Id, Name, BOM_Part__c, Category__c, Phase__c
                FROM Corrective_Action__c
                WHERE BOM_Part__c IN :partIds
            ];
            for (Corrective_Action__c ca : casByPart) {
                if (!partRisks.containsKey(ca.BOM_Part__c)) {
                    partRisks.put(ca.BOM_Part__c, new List<Map<String, String>>());
                }
                Map<String, String> caInfo = new Map<String, String>();
                caInfo.put('id', ca.Id);
                caInfo.put('name', ca.Name);
                caInfo.put('category', ca.Category__c);
                caInfo.put('phase', ca.Phase__c);
                partRisks.get(ca.BOM_Part__c).add(caInfo);
            }

            // CAs by Supplier
            List<Corrective_Action__c> casBySup = [
                SELECT Id, Name, Supplier__c, Category__c, Phase__c
                FROM Corrective_Action__c
                WHERE Supplier__c IN :supplierIds
                AND BOM_Part__c NOT IN :partIds
            ];
            for (Corrective_Action__c ca : casBySup) {
                if (!supplierRisks.containsKey(ca.Supplier__c)) {
                    supplierRisks.put(ca.Supplier__c, new List<Map<String, String>>());
                }
                Map<String, String> caInfo = new Map<String, String>();
                caInfo.put('id', ca.Id);
                caInfo.put('name', ca.Name);
                caInfo.put('category', ca.Category__c);
                caInfo.put('phase', ca.Phase__c);
                supplierRisks.get(ca.Supplier__c).add(caInfo);
            }
        }

        // Build sub → parts map
        Map<Id, List<Map<String, Object>>> subPartsMap = new Map<Id, List<Map<String, Object>>>();
        for (BOM_Part__c p : parts) {
            if (!subPartsMap.containsKey(p.BOM_SubComponent__c)) {
                subPartsMap.put(p.BOM_SubComponent__c, new List<Map<String, Object>>());
            }
            Map<String, Object> pm = new Map<String, Object>();
            pm.put('id', p.Id);
            pm.put('name', p.Part_Name__c != null ? p.Part_Name__c : p.Name);
            pm.put('partNumber', p.Part_Number__c);
            pm.put('supplierName', p.Supplier__r != null ? p.Supplier__r.Name : null);
            pm.put('quantity', p.Quantity__c);
            pm.put('unitCost', p.Unit_Cost__c);
            pm.put('makeOrBuy', p.Make_or_Buy__c);

            // Risk flags
            Boolean hasRisk = false;
            List<Map<String, String>> risks = new List<Map<String, String>>();
            if (partRisks.containsKey(p.Id)) {
                hasRisk = true;
                risks.addAll(partRisks.get(p.Id));
            }
            if (p.Supplier__c != null && supplierRisks.containsKey(p.Supplier__c)) {
                hasRisk = true;
                risks.addAll(supplierRisks.get(p.Supplier__c));
            }
            pm.put('hasRisk', hasRisk);
            pm.put('risks', risks);

            subPartsMap.get(p.BOM_SubComponent__c).add(pm);
        }

        // Build line → subs map
        Map<Id, List<Map<String, Object>>> lineSubsMap = new Map<Id, List<Map<String, Object>>>();
        for (BOM_SubComponent__c s : subs) {
            if (!lineSubsMap.containsKey(s.BOM_Line__c)) {
                lineSubsMap.put(s.BOM_Line__c, new List<Map<String, Object>>());
            }
            Map<String, Object> sm = new Map<String, Object>();
            sm.put('id', s.Id);
            sm.put('name', s.Component_Name__c != null ? s.Component_Name__c : s.Name);
            sm.put('materialType', s.Material_Type__c);
            sm.put('parts', subPartsMap.containsKey(s.Id) ? subPartsMap.get(s.Id) : new List<Map<String, Object>>());

            // Propagate risk from parts
            Boolean subHasRisk = false;
            if (subPartsMap.containsKey(s.Id)) {
                for (Map<String, Object> pm : subPartsMap.get(s.Id)) {
                    if ((Boolean) pm.get('hasRisk')) {
                        subHasRisk = true;
                        break;
                    }
                }
            }
            sm.put('hasRisk', subHasRisk);

            lineSubsMap.get(s.BOM_Line__c).add(sm);
        }

        // Build line nodes
        List<Map<String, Object>> lineNodes = new List<Map<String, Object>>();
        for (BOM_Line__c l : lines) {
            Map<String, Object> lm = new Map<String, Object>();
            lm.put('id', l.Id);
            lm.put('name', l.Component_Product__r != null ? l.Component_Product__r.Name : l.Name);
            lm.put('componentType', l.Component_Type__c);
            lm.put('quantity', l.Quantity__c);
            lm.put('subComponents', lineSubsMap.containsKey(l.Id) ? lineSubsMap.get(l.Id) : new List<Map<String, Object>>());

            // Propagate risk
            Boolean lineHasRisk = false;
            if (lineSubsMap.containsKey(l.Id)) {
                for (Map<String, Object> sm : lineSubsMap.get(l.Id)) {
                    if ((Boolean) sm.get('hasRisk')) {
                        lineHasRisk = true;
                        break;
                    }
                }
            }
            lm.put('hasRisk', lineHasRisk);

            lineNodes.add(lm);
        }

        tree.put('lines', lineNodes);
        tree.put('lineCount', lines.size());
        tree.put('partCount', parts.size());

        return tree;
    }
}
