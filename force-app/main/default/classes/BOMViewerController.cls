public with sharing class BOMViewerController {

    @AuraEnabled(cacheable=true)
    public static List<BomHeaderInfo> getBomHeaders(Id productId) {
        List<BomHeaderInfo> result = new List<BomHeaderInfo>();
        for (BOM_Header__c h : [
            SELECT Id, Name, BOM_Number__c, Status__c, Revision__c, Description__c,
                   Total_Cost__c, Effective_From__c, Effective_To__c, CreatedDate
            FROM BOM_Header__c
            WHERE Product__c = :productId
            ORDER BY CreatedDate DESC
        ]) {
            BomHeaderInfo info = new BomHeaderInfo();
            info.id = h.Id;
            info.name = h.Name;
            info.bomNumber = h.BOM_Number__c;
            info.status = h.Status__c;
            info.revision = h.Revision__c;
            info.description = h.Description__c;
            info.totalCost = h.Total_Cost__c;
            result.add(info);
        }
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<BomTreeNode> getBomTree(Id headerId) {
        // Line → SubComponent → Part の階層を取得
        List<BOM_Line__c> lines = [
            SELECT Id, Name, Line_Number__c, Notes__c, Quantity__c, Unit_of_Measure__c
            FROM BOM_Line__c
            WHERE BOM_Header__c = :headerId
            ORDER BY Line_Number__c
        ];

        Set<Id> lineIds = new Set<Id>();
        for (BOM_Line__c l : lines) lineIds.add(l.Id);

        List<BOM_SubComponent__c> subComps = [
            SELECT Id, Name, Component_Name__c, BOM_Line__c, Quantity__c, Sequence__c
            FROM BOM_SubComponent__c
            WHERE BOM_Line__c IN :lineIds
            ORDER BY Sequence__c
        ];

        Set<Id> subCompIds = new Set<Id>();
        for (BOM_SubComponent__c sc : subComps) subCompIds.add(sc.Id);

        List<BOM_Part__c> parts = [
            SELECT Id, Name, Part_Number__c, Part_Name__c, Quantity__c,
                   Unit_of_Measure__c, Unit_Cost__c, Extended_Cost__c,
                   Make_or_Buy__c, Supplier__c, Supplier__r.Name,
                   Notes__c, BOM_SubComponent__c,
                   Matching_Confidence__c
            FROM BOM_Part__c
            WHERE BOM_SubComponent__c IN :subCompIds
            ORDER BY Part_Number__c
        ];

        // SubComponent → Parts マップ
        Map<Id, List<BomTreeNode>> partsBySubComp = new Map<Id, List<BomTreeNode>>();
        for (BOM_Part__c p : parts) {
            BomTreeNode node = new BomTreeNode();
            node.id = p.Id;
            node.name = p.Part_Number__c;
            node.label = p.Part_Name__c;
            node.quantity = p.Quantity__c;
            node.unit = p.Unit_of_Measure__c;
            node.unitCost = p.Unit_Cost__c;
            node.makeOrBuy = p.Make_or_Buy__c;
            node.supplierId = p.Supplier__c;
            node.supplierName = p.Supplier__r != null ? p.Supplier__r.Name : null;
            node.confidence = p.Matching_Confidence__c;
            node.notes = p.Notes__c;
            node.nodeType = 'part';
            node.isExpanded = true;
            node.items = new List<BomTreeNode>();

            if (!partsBySubComp.containsKey(p.BOM_SubComponent__c)) {
                partsBySubComp.put(p.BOM_SubComponent__c, new List<BomTreeNode>());
            }
            partsBySubComp.get(p.BOM_SubComponent__c).add(node);
        }

        // Line → SubComponents マップ
        Map<Id, List<BomTreeNode>> subCompsByLine = new Map<Id, List<BomTreeNode>>();
        for (BOM_SubComponent__c sc : subComps) {
            BomTreeNode node = new BomTreeNode();
            node.id = sc.Id;
            node.name = sc.Name;
            node.label = sc.Component_Name__c;
            node.quantity = sc.Quantity__c;
            node.nodeType = 'subcomponent';
            node.isExpanded = true;
            node.items = partsBySubComp.containsKey(sc.Id) ? partsBySubComp.get(sc.Id) : new List<BomTreeNode>();

            if (!subCompsByLine.containsKey(sc.BOM_Line__c)) {
                subCompsByLine.put(sc.BOM_Line__c, new List<BomTreeNode>());
            }
            subCompsByLine.get(sc.BOM_Line__c).add(node);
        }

        // Line ノード構築
        List<BomTreeNode> tree = new List<BomTreeNode>();
        for (BOM_Line__c l : lines) {
            BomTreeNode node = new BomTreeNode();
            node.id = l.Id;
            node.name = 'Line #' + (l.Line_Number__c != null ? String.valueOf(l.Line_Number__c.intValue()) : '');
            node.label = l.Notes__c;
            node.quantity = l.Quantity__c;
            node.unit = l.Unit_of_Measure__c;
            node.nodeType = 'line';
            node.isExpanded = true;
            node.items = subCompsByLine.containsKey(l.Id) ? subCompsByLine.get(l.Id) : new List<BomTreeNode>();
            tree.add(node);
        }

        return tree;
    }

    @AuraEnabled
    public static void updatePartSupplier(Id partId, Id supplierId) {
        BOM_Part__c part = new BOM_Part__c(Id = partId);
        part.Supplier__c = supplierId;
        if (supplierId != null) {
            part.Matching_Confidence__c = 'Manual';
        }
        update part;
    }

    public class BomHeaderInfo {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String bomNumber;
        @AuraEnabled public String status;
        @AuraEnabled public String revision;
        @AuraEnabled public String description;
        @AuraEnabled public Decimal totalCost;
    }

    public class BomTreeNode {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String label;
        @AuraEnabled public Double quantity;
        @AuraEnabled public String unit;
        @AuraEnabled public Decimal unitCost;
        @AuraEnabled public String makeOrBuy;
        @AuraEnabled public Id supplierId;
        @AuraEnabled public String supplierName;
        @AuraEnabled public String confidence;
        @AuraEnabled public String notes;
        @AuraEnabled public String nodeType;
        @AuraEnabled public Boolean isExpanded;
        @AuraEnabled public List<BomTreeNode> items;
    }
}
