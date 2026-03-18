public with sharing class ManufacturingSiteMapController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getAllSites() {

        List<Manufacturing_Site__c> sites = [
            SELECT Id, Name, Address__c, Prefecture__c,
                   Latitude__c, Longitude__c, Description__c,
                   Supplier__c, Supplier__r.Name
            FROM Manufacturing_Site__c
            WHERE Latitude__c != null AND Longitude__c != null
            ORDER BY Supplier__r.Name, Name
        ];
        if (sites.isEmpty()) {
            Map<String, Object> empty = new Map<String, Object>();
            empty.put('sites', new List<Map<String, Object>>());
            empty.put('suppliers', new List<Map<String, Object>>());
            empty.put('prefectures', new List<String>());
            return empty;
        }

        Set<Id> siteIds = new Map<Id, Manufacturing_Site__c>(sites).keySet();

        // Query BOM Headers to map assembly sites -> products
        List<BOM_Header__c> bomHeaders = [
            SELECT Id, Product__c, Product__r.Name, Assembly_Site__c, Total_Cost__c
            FROM BOM_Header__c
            WHERE Assembly_Site__c IN :siteIds
        ];
        Map<Id, Set<String>> assemblyProductsBySite = new Map<Id, Set<String>>();
        Map<Id, Integer> assemblyBomCountBySite = new Map<Id, Integer>();
        for (BOM_Header__c h : bomHeaders) {
            Id asId = h.Assembly_Site__c;
            if (!assemblyProductsBySite.containsKey(asId))
                assemblyProductsBySite.put(asId, new Set<String>());
            if (h.Product__r.Name != null)
                assemblyProductsBySite.get(asId).add(h.Product__r.Name);
            assemblyBomCountBySite.put(asId,
                (assemblyBomCountBySite.containsKey(asId) ? assemblyBomCountBySite.get(asId) : 0) + 1);
        }

        List<BOM_Part__c> parts = [
            SELECT Id, Part_Number__c, Part_Name__c, Manufacturing_Site__c,
                   Extended_Cost__c, Unit_Cost__c, Quantity__c,
                   Unit_of_Measure__c, Manufacturer__c,
                   Supplier__r.Name,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.ProductCode
            FROM BOM_Part__c
            WHERE Manufacturing_Site__c IN :siteIds
            ORDER BY Part_Number__c
        ];

        // Group parts by site
        Map<Id, List<Map<String, Object>>> partsBySite = new Map<Id, List<Map<String, Object>>>();
        Map<Id, Set<String>> productsBySite = new Map<Id, Set<String>>();
        Map<Id, Decimal> costBySite = new Map<Id, Decimal>();

        for (BOM_Part__c p : parts) {
            Id siteId = p.Manufacturing_Site__c;
            if (!partsBySite.containsKey(siteId))
                partsBySite.put(siteId, new List<Map<String, Object>>());
            if (!productsBySite.containsKey(siteId))
                productsBySite.put(siteId, new Set<String>());
            if (!costBySite.containsKey(siteId))
                costBySite.put(siteId, 0);

            Map<String, Object> d = new Map<String, Object>();
            d.put('id', p.Id);
            d.put('partNumber', p.Part_Number__c);
            d.put('partName', p.Part_Name__c);
            d.put('productName', p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name);
            d.put('productCode', p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.ProductCode);
            d.put('quantity', p.Quantity__c);
            d.put('unitCost', p.Unit_Cost__c);
            d.put('extendedCost', p.Extended_Cost__c);
            d.put('leadTime', p.Manufacturer__c);
            partsBySite.get(siteId).add(d);

            String prodName = p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name;
            if (prodName != null) productsBySite.get(siteId).add(prodName);

            Decimal ext = p.Extended_Cost__c != null ? p.Extended_Cost__c : 0;
            costBySite.put(siteId, costBySite.get(siteId) + ext);
        }

        // キャパシティデータ取得（サイト別＋部品別）
        List<Supplier_Capacity__c> capRecords = [
            SELECT Manufacturing_Site__c, Part_Number__c, Monthly_Capacity__c
            FROM Supplier_Capacity__c
            WHERE Manufacturing_Site__c IN :siteIds
              AND (Effective_To__c = null OR Effective_To__c >= TODAY)
              AND Effective_From__c <= TODAY
        ];
        Map<Id, Integer> capCountBySite = new Map<Id, Integer>();
        Map<Id, Decimal> totalCapBySite = new Map<Id, Decimal>();
        Map<String, Decimal> capByKey = new Map<String, Decimal>(); // siteId-partNumber → capacity
        for (Supplier_Capacity__c sc : capRecords) {
            Id sid = sc.Manufacturing_Site__c;
            capCountBySite.put(sid, (capCountBySite.containsKey(sid) ? capCountBySite.get(sid) : 0) + 1);
            Decimal cap = sc.Monthly_Capacity__c != null ? sc.Monthly_Capacity__c : 0;
            totalCapBySite.put(sid, (totalCapBySite.containsKey(sid) ? totalCapBySite.get(sid) : 0) + cap);
            if (sc.Part_Number__c != null) {
                capByKey.put(sid + '-' + sc.Part_Number__c, cap);
            }
        }

        // 部品データにキャパシティを付与
        for (Id sid : partsBySite.keySet()) {
            for (Map<String, Object> d : partsBySite.get(sid)) {
                String pn = (String) d.get('partNumber');
                if (pn != null) {
                    String capKey = sid + '-' + pn;
                    Decimal partCap = capByKey.get(capKey);
                    d.put('monthlyCapacity', partCap);
                }
            }
        }

        // Build site list + collect suppliers & prefectures
        Map<Id, String> supplierMap = new Map<Id, String>();
        Set<String> prefectureSet = new Set<String>();
        List<Map<String, Object>> siteList = new List<Map<String, Object>>();

        for (Manufacturing_Site__c s : sites) {
            Map<String, Object> site = new Map<String, Object>();
            site.put('id', s.Id);
            site.put('name', s.Name);
            site.put('address', s.Address__c);
            site.put('prefecture', s.Prefecture__c);
            site.put('latitude', s.Latitude__c);
            site.put('longitude', s.Longitude__c);
            site.put('description', s.Description__c);
            site.put('supplierId', s.Supplier__c);
            site.put('supplierName', s.Supplier__r.Name);

            // Merge supply products + assembly products
            Set<String> allProducts = new Set<String>();
            if (productsBySite.containsKey(s.Id)) allProducts.addAll(productsBySite.get(s.Id));
            if (assemblyProductsBySite.containsKey(s.Id)) allProducts.addAll(assemblyProductsBySite.get(s.Id));
            Integer bomCount = assemblyBomCountBySite.containsKey(s.Id) ? assemblyBomCountBySite.get(s.Id) : 0;

            site.put('partCount', partsBySite.containsKey(s.Id) ? partsBySite.get(s.Id).size() : 0);
            site.put('productCount', allProducts.size());
            site.put('bomCount', bomCount);
            site.put('isAssemblySite', bomCount > 0);
            site.put('totalCost', costBySite.containsKey(s.Id) ? costBySite.get(s.Id) : 0);
            site.put('parts', partsBySite.containsKey(s.Id)
                ? partsBySite.get(s.Id) : new List<Map<String, Object>>());
            site.put('products', new List<String>(allProducts));

            // キャパシティ情報
            site.put('capacityCount', capCountBySite.containsKey(s.Id) ? capCountBySite.get(s.Id) : 0);
            site.put('totalCapacity', totalCapBySite.containsKey(s.Id) ? totalCapBySite.get(s.Id) : 0);

            siteList.add(site);

            if (s.Supplier__c != null) supplierMap.put(s.Supplier__c, s.Supplier__r.Name);
            if (s.Prefecture__c != null) prefectureSet.add(s.Prefecture__c);
        }

        // Build supplier options
        List<Map<String, Object>> supplierOptions = new List<Map<String, Object>>();
        for (Id sid : supplierMap.keySet()) {
            Map<String, Object> opt = new Map<String, Object>();
            opt.put('label', supplierMap.get(sid));
            opt.put('value', sid);
            supplierOptions.add(opt);
        }

        List<String> prefList = new List<String>(prefectureSet);
        prefList.sort();

        Map<String, Object> result = new Map<String, Object>();
        result.put('sites', siteList);
        result.put('suppliers', supplierOptions);
        result.put('prefectures', prefList);
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> simulateDisaster(List<String> prefectures) {
        // 1. Find all sites in affected prefectures
        List<Manufacturing_Site__c> affectedSites = [
            SELECT Id, Name, Address__c, Prefecture__c, Latitude__c, Longitude__c,
                   Is_Own_Site__c, Supplier__c, Supplier__r.Name
            FROM Manufacturing_Site__c
            WHERE Prefecture__c IN :prefectures
            ORDER BY Is_Own_Site__c DESC, Name
        ];

        Set<Id> affectedSiteIds = new Map<Id, Manufacturing_Site__c>(affectedSites).keySet();

        // 2. Get ALL BOM Headers with parts (to analyze per-BOM impact)
        List<BOM_Header__c> allHeaders = [
            SELECT Id, BOM_Number__c, Product__c, Product__r.Name, Product__r.ProductCode,
                   Assembly_Site__c, Assembly_Site__r.Name, Assembly_Site__r.Prefecture__c,
                   Total_Cost__c
            FROM BOM_Header__c
            WHERE Assembly_Site__c != null
            ORDER BY Product__r.Name, BOM_Number__c
        ];

        // 3. Find affected parts (supplier sites in disaster area)
        List<BOM_Part__c> affectedParts = [
            SELECT Id, Part_Number__c, Part_Name__c, Manufacturing_Site__c,
                   Manufacturing_Site__r.Name, Extended_Cost__c, Supplier__c, Supplier__r.Name,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__c
            FROM BOM_Part__c
            WHERE Manufacturing_Site__c IN :affectedSiteIds
            ORDER BY Part_Number__c
        ];

        // Group affected parts by BOM Header Id
        Map<Id, List<BOM_Part__c>> partsByHeader = new Map<Id, List<BOM_Part__c>>();
        Set<String> affectedPartNumbers = new Set<String>();
        Set<Id> affectedSupplierIds = new Set<Id>();
        for (BOM_Part__c p : affectedParts) {
            Id hdrId = p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__c;
            if (hdrId == null) continue;
            if (!partsByHeader.containsKey(hdrId))
                partsByHeader.put(hdrId, new List<BOM_Part__c>());
            partsByHeader.get(hdrId).add(p);
            if (p.Part_Number__c != null) affectedPartNumbers.add(p.Part_Number__c);
            if (p.Supplier__c != null) affectedSupplierIds.add(p.Supplier__c);
        }

        // 4. Safe own sites
        List<Manufacturing_Site__c> safeOwnSites = [
            SELECT Id, Name, Prefecture__c
            FROM Manufacturing_Site__c
            WHERE Is_Own_Site__c = true
            AND Prefecture__c NOT IN :prefectures
        ];

        // オフロード分析: 被災地域外の代替キャパシティを検索
        List<Map<String, Object>> offloadProposals = new List<Map<String, Object>>();
        Boolean hasOffloadOptions = false;

        if (!affectedPartNumbers.isEmpty()) {
            // 被災サイトのキャパシティ
            List<Supplier_Capacity__c> affectedCaps = [
                SELECT Part_Number__c, Part_Name__c, Monthly_Capacity__c,
                       Manufacturing_Site__c, Manufacturing_Site__r.Name,
                       Manufacturing_Site__r.Supplier__c
                FROM Supplier_Capacity__c
                WHERE Part_Number__c IN :affectedPartNumbers
                  AND Manufacturing_Site__c IN :affectedSiteIds
                  AND (Effective_To__c = null OR Effective_To__c >= TODAY)
                  AND Effective_From__c <= TODAY
            ];

            // 被災地域外の同一部品番号のキャパシティ（同一サプライヤー優先）
            List<Supplier_Capacity__c> safeCaps = [
                SELECT Part_Number__c, Part_Name__c, Monthly_Capacity__c,
                       Manufacturing_Site__c, Manufacturing_Site__r.Name,
                       Manufacturing_Site__r.Supplier__c, Manufacturing_Site__r.Supplier__r.Name
                FROM Supplier_Capacity__c
                WHERE Part_Number__c IN :affectedPartNumbers
                  AND Manufacturing_Site__r.Prefecture__c NOT IN :prefectures
                  AND (Effective_To__c = null OR Effective_To__c >= TODAY)
                  AND Effective_From__c <= TODAY
            ];

            // 安全サイトを部品番号でグループ化
            Map<String, List<Supplier_Capacity__c>> safeCapsByPart = new Map<String, List<Supplier_Capacity__c>>();
            for (Supplier_Capacity__c sc : safeCaps) {
                if (!safeCapsByPart.containsKey(sc.Part_Number__c)) {
                    safeCapsByPart.put(sc.Part_Number__c, new List<Supplier_Capacity__c>());
                }
                safeCapsByPart.get(sc.Part_Number__c).add(sc);
            }

            // 被災キャパシティごとにオフロード提案を作成
            for (Supplier_Capacity__c ac : affectedCaps) {
                List<Supplier_Capacity__c> alternatives = safeCapsByPart.get(ac.Part_Number__c);
                if (alternatives == null || alternatives.isEmpty()) continue;

                // 同一サプライヤーを優先してソート
                List<Supplier_Capacity__c> sameSupplier = new List<Supplier_Capacity__c>();
                List<Supplier_Capacity__c> otherSupplier = new List<Supplier_Capacity__c>();
                for (Supplier_Capacity__c alt : alternatives) {
                    if (alt.Manufacturing_Site__r.Supplier__c == ac.Manufacturing_Site__r.Supplier__c) {
                        sameSupplier.add(alt);
                    } else {
                        otherSupplier.add(alt);
                    }
                }

                List<Supplier_Capacity__c> sortedAlts = new List<Supplier_Capacity__c>();
                sortedAlts.addAll(sameSupplier);
                sortedAlts.addAll(otherSupplier);

                Decimal affectedCapacity = ac.Monthly_Capacity__c != null ? ac.Monthly_Capacity__c : 0;

                for (Supplier_Capacity__c alt : sortedAlts) {
                    Decimal altCapacity = alt.Monthly_Capacity__c != null ? alt.Monthly_Capacity__c : 0;
                    Boolean canOffload = altCapacity >= affectedCapacity;
                    Decimal offloadPct = affectedCapacity > 0 ? (altCapacity / affectedCapacity * 100).setScale(1) : 0;

                    Map<String, Object> proposal = new Map<String, Object>();
                    proposal.put('affectedPart', ac.Part_Number__c);
                    proposal.put('affectedPartName', ac.Part_Name__c);
                    proposal.put('affectedSite', ac.Manufacturing_Site__r.Name);
                    proposal.put('affectedCapacity', affectedCapacity);
                    proposal.put('alternativeSite', alt.Manufacturing_Site__r.Name);
                    proposal.put('alternativeSupplier', alt.Manufacturing_Site__r.Supplier__r.Name);
                    proposal.put('alternativeSpareCapacity', altCapacity);
                    proposal.put('canOffload', canOffload);
                    proposal.put('offloadPct', offloadPct);
                    proposal.put('isSameSupplier', alt.Manufacturing_Site__r.Supplier__c == ac.Manufacturing_Site__r.Supplier__c);
                    offloadProposals.add(proposal);
                    hasOffloadOptions = true;
                }
            }
        }

        // 5. Build per-product, per-BOM impact analysis
        // Group headers by product
        Map<Id, List<BOM_Header__c>> headersByProduct = new Map<Id, List<BOM_Header__c>>();
        for (BOM_Header__c h : allHeaders) {
            if (!headersByProduct.containsKey(h.Product__c))
                headersByProduct.put(h.Product__c, new List<BOM_Header__c>());
            headersByProduct.get(h.Product__c).add(h);
        }

        List<Map<String, Object>> productList = new List<Map<String, Object>>();

        for (Id prodId : headersByProduct.keySet()) {
            List<BOM_Header__c> headers = headersByProduct.get(prodId);
            BOM_Header__c firstHdr = headers[0];

            // Analyze each BOM for this product
            List<Map<String, Object>> bomBreakdown = new List<Map<String, Object>>();
            Boolean anyAssemblyHit = false;
            Boolean anySupplyHit = false;
            Boolean hasUnaffectedBom = false;
            Decimal totalAffectedCost = 0;
            Integer totalAffectedPartCount = 0;
            List<Map<String, Object>> allAffectedPartsList = new List<Map<String, Object>>();

            for (BOM_Header__c h : headers) {
                Boolean assemblyHit = prefectures.contains(h.Assembly_Site__r.Prefecture__c);
                List<BOM_Part__c> hdrParts = partsByHeader.get(h.Id);
                Boolean supplyHit = hdrParts != null && !hdrParts.isEmpty();
                Decimal bomAffectedCost = 0;
                Integer bomAffectedPartCount = 0;
                List<Map<String, Object>> bomPartsList = new List<Map<String, Object>>();

                if (supplyHit) {
                    for (BOM_Part__c p : hdrParts) {
                        bomAffectedPartCount++;
                        Decimal cost = p.Extended_Cost__c != null ? p.Extended_Cost__c : 0;
                        bomAffectedCost += cost;
                        Map<String, Object> partInfo = new Map<String, Object>();
                        partInfo.put('partNumber', p.Part_Number__c);
                        partInfo.put('partName', p.Part_Name__c);
                        partInfo.put('supplierName', p.Supplier__r.Name);
                        partInfo.put('siteName', p.Manufacturing_Site__r.Name);
                        partInfo.put('extendedCost', p.Extended_Cost__c);
                        bomPartsList.add(partInfo);
                    }
                }

                Boolean bomIsAffected = assemblyHit || supplyHit;
                if (!bomIsAffected) hasUnaffectedBom = true;
                if (assemblyHit) anyAssemblyHit = true;
                if (supplyHit) anySupplyHit = true;

                // BOM-level status
                String bomStatus;
                if (assemblyHit && supplyHit) bomStatus = '組立+供給 被災';
                else if (assemblyHit) bomStatus = '組立拠点 被災';
                else if (supplyHit) bomStatus = '供給元 被災';
                else bomStatus = '影響なし';

                Map<String, Object> bom = new Map<String, Object>();
                bom.put('bomId', h.Id);
                bom.put('bomNumber', h.BOM_Number__c);
                bom.put('assemblySite', h.Assembly_Site__r.Name);
                bom.put('assemblySitePrefecture', h.Assembly_Site__r.Prefecture__c);
                bom.put('assemblyAffected', assemblyHit);
                bom.put('supplyAffected', supplyHit);
                bom.put('isAffected', bomIsAffected);
                bom.put('status', bomStatus);
                bom.put('affectedPartCount', bomAffectedPartCount);
                bom.put('affectedSupplyCost', bomAffectedCost);
                bom.put('totalCost', h.Total_Cost__c);
                bom.put('affectedParts', bomPartsList);
                bomBreakdown.add(bom);

                totalAffectedCost += bomAffectedCost;
                totalAffectedPartCount += bomAffectedPartCount;
                allAffectedPartsList.addAll(bomPartsList);
            }

            // Skip products with zero impact
            if (!anyAssemblyHit && !anySupplyHit) continue;

            // Supply dependency % (use max across affected BOMs)
            Decimal maxSupplyDep = 0;
            for (Map<String, Object> bom : bomBreakdown) {
                Decimal tc = (Decimal)bom.get('totalCost');
                Decimal ac = (Decimal)bom.get('affectedSupplyCost');
                if (tc != null && tc > 0) {
                    Decimal dep = ac / tc * 100;
                    if (dep > maxSupplyDep) maxSupplyDep = dep;
                }
            }

            // Risk level (considers alternative BOMs)
            String risk;
            if (anyAssemblyHit && anySupplyHit && !hasUnaffectedBom) {
                risk = 'CRITICAL';
            } else if (anyAssemblyHit && !hasUnaffectedBom) {
                risk = 'HIGH';
            } else if (anySupplyHit && maxSupplyDep > 30 && !hasUnaffectedBom) {
                risk = 'HIGH';
            } else if (hasUnaffectedBom && (anyAssemblyHit || anySupplyHit)) {
                risk = 'MEDIUM';
            } else if (anySupplyHit) {
                risk = 'MEDIUM';
            } else {
                risk = 'LOW';
            }
            Integer sortRank = risk == 'CRITICAL' ? 0 : risk == 'HIGH' ? 1 : risk == 'MEDIUM' ? 2 : 3;

            // Primary assembly site info (from first affected BOM, or first BOM)
            String primaryAssemblySite = firstHdr.Assembly_Site__r.Name;

            Map<String, Object> pi = new Map<String, Object>();
            pi.put('productId', prodId);
            pi.put('productName', firstHdr.Product__r.Name);
            pi.put('productCode', firstHdr.Product__r.ProductCode);
            pi.put('assemblySite', primaryAssemblySite);
            pi.put('assemblyAffected', anyAssemblyHit);
            pi.put('supplyAffected', anySupplyHit);
            pi.put('hasAlternativeSite', hasUnaffectedBom);
            pi.put('bomCount', headers.size());
            pi.put('affectedBomCount', headers.size() - (hasUnaffectedBom ? 1 : 0));
            pi.put('affectedPartCount', totalAffectedPartCount);
            pi.put('affectedSupplyCost', totalAffectedCost);
            pi.put('supplyDependencyPct', maxSupplyDep.setScale(1));
            pi.put('riskLevel', risk);
            pi.put('sortRank', sortRank);
            pi.put('affectedParts', allAffectedPartsList);
            pi.put('bomBreakdown', bomBreakdown);
            productList.add(pi);
        }

        // Build affected sites list for display
        List<Map<String, Object>> siteList = new List<Map<String, Object>>();
        Integer ownSitesAffected = 0;
        Integer supplierSitesAffected = 0;
        for (Manufacturing_Site__c s : affectedSites) {
            Map<String, Object> sm = new Map<String, Object>();
            sm.put('id', s.Id);
            sm.put('name', s.Name);
            sm.put('address', s.Address__c);
            sm.put('prefecture', s.Prefecture__c);
            sm.put('latitude', s.Latitude__c);
            sm.put('longitude', s.Longitude__c);
            sm.put('isOwnSite', s.Is_Own_Site__c);
            sm.put('supplierName', s.Supplier__r.Name);
            siteList.add(sm);
            if (s.Is_Own_Site__c) ownSitesAffected++;
            else supplierSitesAffected++;
        }

        Decimal totalRiskCost = 0;
        for (Map<String, Object> pi : productList) {
            totalRiskCost += (Decimal)pi.get('affectedSupplyCost');
        }

        Map<String, Object> result = new Map<String, Object>();
        result.put('affectedSites', siteList);
        result.put('productImpact', productList);
        result.put('ownSitesAffected', ownSitesAffected);
        result.put('supplierSitesAffected', supplierSitesAffected);
        result.put('totalProductsAffected', productList.size());
        result.put('totalRiskCost', totalRiskCost);
        result.put('safeOwnSites', safeOwnSites.size());
        result.put('offloadProposals', offloadProposals);
        result.put('hasOffloadOptions', hasOffloadOptions);
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getSitesBySupplier(Id accountId) {

        List<Manufacturing_Site__c> sites = [
            SELECT Id, Name, Address__c, Prefecture__c,
                   Latitude__c, Longitude__c, Description__c,
                   Supplier__c, Supplier__r.Name
            FROM Manufacturing_Site__c
            WHERE Supplier__c = :accountId
            ORDER BY Name
        ];
        if (sites.isEmpty()) return new List<Map<String, Object>>();

        Set<Id> siteIds = new Map<Id, Manufacturing_Site__c>(sites).keySet();

        List<BOM_Part__c> parts = [
            SELECT Id, Part_Number__c, Part_Name__c, Manufacturing_Site__c,
                   Extended_Cost__c, Unit_Cost__c, Quantity__c,
                   Unit_of_Measure__c, Manufacturer__c,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.ProductCode
            FROM BOM_Part__c
            WHERE Manufacturing_Site__c IN :siteIds
            ORDER BY Part_Number__c
        ];

        // Group parts by site
        Map<Id, List<Map<String, Object>>> partsBySite = new Map<Id, List<Map<String, Object>>>();
        Map<Id, Set<String>> productsBySite = new Map<Id, Set<String>>();
        Map<Id, Decimal> costBySite = new Map<Id, Decimal>();

        for (BOM_Part__c p : parts) {
            Id siteId = p.Manufacturing_Site__c;
            if (!partsBySite.containsKey(siteId))
                partsBySite.put(siteId, new List<Map<String, Object>>());
            if (!productsBySite.containsKey(siteId))
                productsBySite.put(siteId, new Set<String>());
            if (!costBySite.containsKey(siteId))
                costBySite.put(siteId, 0);

            Map<String, Object> d = new Map<String, Object>();
            d.put('id', p.Id);
            d.put('partNumber', p.Part_Number__c);
            d.put('partName', p.Part_Name__c);
            d.put('productName', p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name);
            d.put('productCode', p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.ProductCode);
            d.put('quantity', p.Quantity__c);
            d.put('uom', p.Unit_of_Measure__c);
            d.put('unitCost', p.Unit_Cost__c);
            d.put('extendedCost', p.Extended_Cost__c);
            d.put('leadTime', p.Manufacturer__c);
            partsBySite.get(siteId).add(d);

            String prodName = p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name;
            if (prodName != null) productsBySite.get(siteId).add(prodName);

            Decimal ext = p.Extended_Cost__c != null ? p.Extended_Cost__c : 0;
            costBySite.put(siteId, costBySite.get(siteId) + ext);
        }

        // キャパシティデータを部品に付与
        Map<String, Decimal> capByKey = new Map<String, Decimal>();
        List<Supplier_Capacity__c> caps = [
            SELECT Manufacturing_Site__c, Part_Number__c, Monthly_Capacity__c
            FROM Supplier_Capacity__c
            WHERE Manufacturing_Site__c IN :siteIds
              AND (Effective_To__c = null OR Effective_To__c >= TODAY)
              AND Effective_From__c <= TODAY
        ];
        for (Supplier_Capacity__c sc : caps) {
            if (sc.Part_Number__c != null) {
                capByKey.put(sc.Manufacturing_Site__c + '-' + sc.Part_Number__c,
                    sc.Monthly_Capacity__c != null ? sc.Monthly_Capacity__c : 0);
            }
        }
        for (Id sid : partsBySite.keySet()) {
            for (Map<String, Object> d : partsBySite.get(sid)) {
                String pn = (String) d.get('partNumber');
                if (pn != null) {
                    d.put('monthlyCapacity', capByKey.get(sid + '-' + pn));
                }
            }
        }

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Manufacturing_Site__c s : sites) {
            Map<String, Object> site = new Map<String, Object>();
            site.put('id', s.Id);
            site.put('name', s.Name);
            site.put('address', s.Address__c);
            site.put('prefecture', s.Prefecture__c);
            site.put('latitude', s.Latitude__c);
            site.put('longitude', s.Longitude__c);
            site.put('description', s.Description__c);
            site.put('partCount', partsBySite.containsKey(s.Id) ? partsBySite.get(s.Id).size() : 0);
            site.put('productCount', productsBySite.containsKey(s.Id) ? productsBySite.get(s.Id).size() : 0);
            site.put('totalCost', costBySite.containsKey(s.Id) ? costBySite.get(s.Id) : 0);
            site.put('parts', partsBySite.containsKey(s.Id)
                ? partsBySite.get(s.Id) : new List<Map<String, Object>>());
            site.put('products', productsBySite.containsKey(s.Id)
                ? new List<String>(productsBySite.get(s.Id)) : new List<String>());
            result.add(site);
        }
        return result;
    }
}
