public with sharing class BOMTreeController {

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getBOMTree(Id productId) {

        // ── L1: BOM Headers ──────────────────────────────────────────────
        List<BOM_Header__c> headers = [
            SELECT Id, Name, BOM_Number__c, Revision__c, Status__c,
                   BOM_Type__c, Effective_From__c, Effective_To__c, Total_Cost__c,
                   Assembly_Site__r.Name
            FROM BOM_Header__c
            WHERE Product__c = :productId
            ORDER BY BOM_Number__c, Name
        ];
        if (headers.isEmpty()) return new List<Map<String, Object>>();

        Set<Id> headerIds = (new Map<Id, BOM_Header__c>(headers)).keySet();

        // ── L2: BOM Lines ─────────────────────────────────────────────────
        List<BOM_Line__c> lines = [
            SELECT Id, Name, Line_Number__c, BOM_Header__c,
                   Component_Type__c, Component_Product__r.Name,
                   Quantity__c, Unit_of_Measure__c,
                   Unit_Cost__c, Extended_Cost__c, Is_Phantom__c
            FROM BOM_Line__c
            WHERE BOM_Header__c IN :headerIds
            ORDER BY Line_Number__c, Name
        ];

        Set<Id> lineIds = (new Map<Id, BOM_Line__c>(lines)).keySet();

        // ── L3: BOM SubComponents ─────────────────────────────────────────
        List<BOM_SubComponent__c> subs = new List<BOM_SubComponent__c>();
        if (!lineIds.isEmpty()) {
            subs = [
                SELECT Id, Name, Sequence__c, BOM_Line__c,
                       Component_Name__c, Material_Type__c, Process_Type__c,
                       Quantity__c, Unit_of_Measure__c,
                       Unit_Cost__c, Extended_Cost__c, Required_For_Production__c
                FROM BOM_SubComponent__c
                WHERE BOM_Line__c IN :lineIds
                ORDER BY Sequence__c, Name
            ];
        }

        Set<Id> subIds = (new Map<Id, BOM_SubComponent__c>(subs)).keySet();

        // ── L4: BOM Parts (with Supplier) ─────────────────────────────────
        List<BOM_Part__c> parts = new List<BOM_Part__c>();
        if (!subIds.isEmpty()) {
            parts = [
                SELECT Id, Name, Part_Number__c, Part_Name__c, BOM_SubComponent__c,
                       Make_or_Buy__c, Manufacturer__c, Material__c,
                       Quantity__c, Unit_of_Measure__c,
                       Unit_Cost__c, Extended_Cost__c,
                       Supplier__r.Name, Matching_Confidence__c,
                       Manufacturing_Site__c, Manufacturing_Site__r.Name
                FROM BOM_Part__c
                WHERE BOM_SubComponent__c IN :subIds
                ORDER BY Part_Number__c, Name
            ];
        }

        // ── Shared parts detection ────────────────────────────────────────
        Set<String> partNumbers = new Set<String>();
        for (BOM_Part__c p : parts) {
            if (p.Part_Number__c != null) partNumbers.add(p.Part_Number__c);
        }
        Set<String> sharedPartNumbers = new Set<String>();
        Map<String, Integer> sharedProductCounts = new Map<String, Integer>();
        if (!partNumbers.isEmpty()) {
            List<BOM_Part__c> allMatching = [
                SELECT Part_Number__c,
                       BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c
                FROM BOM_Part__c
                WHERE Part_Number__c IN :partNumbers
            ];
            Map<String, Set<Id>> productsByPart = new Map<String, Set<Id>>();
            for (BOM_Part__c p : allMatching) {
                Id prodId = p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c;
                if (!productsByPart.containsKey(p.Part_Number__c))
                    productsByPart.put(p.Part_Number__c, new Set<Id>());
                productsByPart.get(p.Part_Number__c).add(prodId);
            }
            for (String pn : productsByPart.keySet()) {
                Integer cnt = productsByPart.get(pn).size();
                if (cnt > 1) {
                    sharedPartNumbers.add(pn);
                    sharedProductCounts.put(pn, cnt);
                }
            }
        }

        // ── Group children by parent Id ───────────────────────────────────
        Map<Id, List<BOM_Line__c>> linesByHeader = new Map<Id, List<BOM_Line__c>>();
        for (BOM_Line__c l : lines) {
            if (!linesByHeader.containsKey(l.BOM_Header__c))
                linesByHeader.put(l.BOM_Header__c, new List<BOM_Line__c>());
            linesByHeader.get(l.BOM_Header__c).add(l);
        }

        Map<Id, List<BOM_SubComponent__c>> subsByLine = new Map<Id, List<BOM_SubComponent__c>>();
        for (BOM_SubComponent__c s : subs) {
            if (!subsByLine.containsKey(s.BOM_Line__c))
                subsByLine.put(s.BOM_Line__c, new List<BOM_SubComponent__c>());
            subsByLine.get(s.BOM_Line__c).add(s);
        }

        Map<Id, List<BOM_Part__c>> partsBySub = new Map<Id, List<BOM_Part__c>>();
        for (BOM_Part__c p : parts) {
            if (!partsBySub.containsKey(p.BOM_SubComponent__c))
                partsBySub.put(p.BOM_SubComponent__c, new List<BOM_Part__c>());
            partsBySub.get(p.BOM_SubComponent__c).add(p);
        }

        // ── Build tree ────────────────────────────────────────────────────
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (BOM_Header__c h : headers) {
            result.add(buildHeader(h, linesByHeader, subsByLine, partsBySub,
                                   sharedPartNumbers, sharedProductCounts));
        }
        return result;
    }

    // ─────────────────────────────────────────────────────────────────────
    private static Map<String, Object> buildHeader(
        BOM_Header__c h,
        Map<Id, List<BOM_Line__c>> linesByHeader,
        Map<Id, List<BOM_SubComponent__c>> subsByLine,
        Map<Id, List<BOM_Part__c>> partsBySub,
        Set<String> sharedPartNumbers,
        Map<String, Integer> sharedProductCounts
    ) {
        Map<String, Object> n = new Map<String, Object>();
        n.put('id',            h.Id);
        n.put('level',         'L1');
        n.put('bomNumber',     h.BOM_Number__c);
        n.put('revision',      h.Revision__c);
        n.put('status',        h.Status__c);
        n.put('bomType',       h.BOM_Type__c);
        n.put('effectiveFrom', h.Effective_From__c != null ? String.valueOf(h.Effective_From__c) : null);
        n.put('effectiveTo',   h.Effective_To__c   != null ? String.valueOf(h.Effective_To__c)   : null);
        n.put('extendedCost',  h.Total_Cost__c);
        n.put('assemblySite',  h.Assembly_Site__r != null ? h.Assembly_Site__r.Name : null);

        List<Map<String, Object>> children = new List<Map<String, Object>>();
        if (linesByHeader.containsKey(h.Id)) {
            for (BOM_Line__c l : linesByHeader.get(h.Id))
                children.add(buildLine(l, subsByLine, partsBySub,
                                       sharedPartNumbers, sharedProductCounts));
        }
        if (!children.isEmpty()) n.put('_children', children);
        return n;
    }

    private static Map<String, Object> buildLine(
        BOM_Line__c l,
        Map<Id, List<BOM_SubComponent__c>> subsByLine,
        Map<Id, List<BOM_Part__c>> partsBySub,
        Set<String> sharedPartNumbers,
        Map<String, Integer> sharedProductCounts
    ) {
        Map<String, Object> n = new Map<String, Object>();
        n.put('id',            l.Id);
        n.put('level',         'L2');
        n.put('lineNumber',    l.Line_Number__c);
        n.put('componentType', l.Component_Type__c);
        n.put('componentName', l.Component_Product__r != null ? l.Component_Product__r.Name : null);
        n.put('isPhantom',     l.Is_Phantom__c);
        n.put('quantity',      l.Quantity__c);
        n.put('uom',           l.Unit_of_Measure__c);
        n.put('unitCost',      l.Unit_Cost__c);
        n.put('extendedCost',  l.Extended_Cost__c);

        List<Map<String, Object>> children = new List<Map<String, Object>>();
        if (subsByLine.containsKey(l.Id)) {
            for (BOM_SubComponent__c s : subsByLine.get(l.Id))
                children.add(buildSub(s, partsBySub,
                                      sharedPartNumbers, sharedProductCounts));
        }
        if (!children.isEmpty()) n.put('_children', children);
        return n;
    }

    private static Map<String, Object> buildSub(
        BOM_SubComponent__c s,
        Map<Id, List<BOM_Part__c>> partsBySub,
        Set<String> sharedPartNumbers,
        Map<String, Integer> sharedProductCounts
    ) {
        Map<String, Object> n = new Map<String, Object>();
        n.put('id',            s.Id);
        n.put('level',         'L3');
        n.put('sequence',      s.Sequence__c);
        n.put('componentName', s.Component_Name__c);
        n.put('materialType',  s.Material_Type__c);
        n.put('processType',   s.Process_Type__c);
        n.put('required',      s.Required_For_Production__c);
        n.put('quantity',      s.Quantity__c);
        n.put('uom',           s.Unit_of_Measure__c);
        n.put('unitCost',      s.Unit_Cost__c);
        n.put('extendedCost',  s.Extended_Cost__c);

        List<Map<String, Object>> children = new List<Map<String, Object>>();
        if (partsBySub.containsKey(s.Id)) {
            for (BOM_Part__c p : partsBySub.get(s.Id))
                children.add(buildPart(p, sharedPartNumbers, sharedProductCounts));
        }
        if (!children.isEmpty()) n.put('_children', children);
        return n;
    }

    private static Map<String, Object> buildPart(
        BOM_Part__c p,
        Set<String> sharedPartNumbers,
        Map<String, Integer> sharedProductCounts
    ) {
        Map<String, Object> n = new Map<String, Object>();
        n.put('id',            p.Id);
        n.put('level',         'L4');
        n.put('partNumber',    p.Part_Number__c);
        n.put('componentName', p.Part_Name__c);
        n.put('makeOrBuy',     p.Make_or_Buy__c);
        n.put('materialType',  p.Material__c);
        n.put('manufacturer',  p.Manufacturer__c);
        n.put('supplierName',  p.Supplier__r != null ? p.Supplier__r.Name : null);
        n.put('supplierId',    p.Supplier__c);
        n.put('siteName',      p.Manufacturing_Site__r != null ? p.Manufacturing_Site__r.Name : null);
        n.put('siteId',        p.Manufacturing_Site__c);
        n.put('quantity',      p.Quantity__c);
        n.put('uom',           p.Unit_of_Measure__c);
        n.put('unitCost',      p.Unit_Cost__c);
        n.put('extendedCost',  p.Extended_Cost__c);
        n.put('confidence',    p.Matching_Confidence__c);
        Boolean isShared = p.Part_Number__c != null && sharedPartNumbers.contains(p.Part_Number__c);
        n.put('isShared',           isShared);
        n.put('sharedProductCount', isShared ? sharedProductCounts.get(p.Part_Number__c) : 0);
        return n;
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
}
