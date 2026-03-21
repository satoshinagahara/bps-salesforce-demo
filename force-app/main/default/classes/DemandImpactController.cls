public with sharing class DemandImpactController {
    @AuraEnabled(cacheable=true)
    public static ImpactAnalysis getImpactData(Id agreementId) {
        ImpactAnalysis result = new ImpactAnalysis();
        result.products = new List<ProductImpact>();

        // Get schedules with variance
        List<Sales_Agreement_Product__c> saps = [
            SELECT Product__c, Product__r.Name, Unit_Price__c, BOM_Header__c,
                (SELECT Schedule_Month__c, Plan_Quantity__c, Actual_Quantity__c,
                        Plan_Amount__c, Actual_Amount__c
                 FROM Schedules__r
                 WHERE Actual_Quantity__c != null AND Actual_Quantity__c > 0
                 ORDER BY Schedule_Month__c)
            FROM Sales_Agreement_Product__c
            WHERE Sales_Agreement__c = :agreementId
        ];

        Set<Id> productIds = new Set<Id>();
        Map<Id, ProductImpact> productMap = new Map<Id, ProductImpact>();
        // BOM_Header__c指定がある場合はそのIDで展開、なければProduct__cで展開（後方互換）
        Map<Id, Set<Id>> bomIdsByProduct = new Map<Id, Set<Id>>();

        for (Sales_Agreement_Product__c sap : saps) {
            ProductImpact pi = new ProductImpact();
            pi.productName = sap.Product__r.Name;
            pi.productId = sap.Product__c;
            pi.months = new List<MonthVariance>();
            pi.suppliers = new List<SupplierImpact>();

            Decimal totalPlan = 0, totalActual = 0;
            for (Sales_Agreement_Schedule__c s : sap.Schedules__r) {
                Decimal plan = s.Plan_Quantity__c != null ? s.Plan_Quantity__c : 0;
                Decimal actual = s.Actual_Quantity__c != null ? s.Actual_Quantity__c : 0;
                totalPlan += plan;
                totalActual += actual;
                if (plan > 0) {
                    Decimal variancePct = ((actual - plan) / plan * 100).setScale(1);
                    if (Math.abs(variancePct) >= 5) {
                        MonthVariance mv = new MonthVariance();
                        mv.month = s.Schedule_Month__c;
                        mv.planQty = plan;
                        mv.actualQty = actual;
                        mv.varianceQty = actual - plan;
                        mv.variancePct = variancePct;
                        pi.months.add(mv);
                    }
                }
            }
            pi.totalVarianceQty = totalActual - totalPlan;
            pi.totalVariancePct = totalPlan > 0 ? ((totalActual - totalPlan) / totalPlan * 100).setScale(1) : 0;
            productIds.add(sap.Product__c);
            productMap.put(sap.Product__c, pi);
            result.products.add(pi);

            // BOM指定を記録
            if (sap.BOM_Header__c != null) {
                if (!bomIdsByProduct.containsKey(sap.Product__c)) {
                    bomIdsByProduct.put(sap.Product__c, new Set<Id>());
                }
                bomIdsByProduct.get(sap.Product__c).add(sap.BOM_Header__c);
            }
        }

        if (productIds.isEmpty()) return result;

        // BOM expansion - use plan quantities as demand
        Map<Id, Decimal> planQtyByProduct = new Map<Id, Decimal>();
        Integer maxMonths = 1;
        for (Sales_Agreement_Product__c sap : saps) {
            Decimal totalPlan = 0;
            Integer cnt = 0;
            for (Sales_Agreement_Schedule__c s : sap.Schedules__r) {
                totalPlan += s.Plan_Quantity__c != null ? s.Plan_Quantity__c : 0;
                cnt++;
            }
            planQtyByProduct.put(sap.Product__c, totalPlan);
            maxMonths = Math.max(maxMonths, cnt);
        }
        expandBOM(productIds, productMap, planQtyByProduct, maxMonths, bomIdsByProduct);

        return result;
    }

    // What-If Simulation
    @AuraEnabled
    public static WhatIfResult simulateWhatIf(Id agreementId, String scenarioJson) {
        List<ScenarioInput> scenarios = (List<ScenarioInput>) JSON.deserialize(
            scenarioJson, List<ScenarioInput>.class);
        Map<Id, Decimal> changePctMap = new Map<Id, Decimal>();
        for (ScenarioInput si : scenarios) {
            changePctMap.put(si.productId, si.changePct);
        }

        List<Sales_Agreement_Product__c> saps = [
            SELECT Product__c, Product__r.Name, Unit_Price__c, BOM_Header__c,
                (SELECT Schedule_Month__c, Plan_Quantity__c, Actual_Quantity__c
                 FROM Schedules__r
                 ORDER BY Schedule_Month__c)
            FROM Sales_Agreement_Product__c
            WHERE Sales_Agreement__c = :agreementId
        ];

        WhatIfResult result = new WhatIfResult();
        result.products = new List<WhatIfProduct>();
        Set<Id> productIds = new Set<Id>();
        Map<Id, ProductImpact> impactMap = new Map<Id, ProductImpact>();
        Map<Id, Decimal> totalSimQtyByProduct = new Map<Id, Decimal>();
        Map<Id, Set<Id>> bomIdsByProduct = new Map<Id, Set<Id>>();
        Integer maxMonthCount = 1;

        for (Sales_Agreement_Product__c sap : saps) {
            Decimal changePct = changePctMap.containsKey(sap.Product__c)
                ? changePctMap.get(sap.Product__c) : 0;
            if (changePct == 0) continue;

            WhatIfProduct wp = new WhatIfProduct();
            wp.productName = sap.Product__r.Name;
            wp.productId = sap.Product__c;
            wp.changePct = changePct;
            wp.months = new List<WhatIfMonth>();
            wp.suppliers = new List<SupplierImpact>();

            Decimal totalPlan = 0, totalSimulated = 0;
            Integer scheduleMonthCount = 0;
            for (Sales_Agreement_Schedule__c s : sap.Schedules__r) {
                Decimal plan = s.Plan_Quantity__c != null ? s.Plan_Quantity__c : 0;
                Decimal actual = s.Actual_Quantity__c;
                Decimal simulated = (plan * (1 + changePct / 100)).setScale(0, System.RoundingMode.HALF_UP);

                WhatIfMonth wm = new WhatIfMonth();
                wm.month = s.Schedule_Month__c;
                wm.planQty = plan;
                wm.actualQty = actual;
                wm.simulatedQty = simulated;
                wp.months.add(wm);

                totalPlan += plan;
                totalSimulated += simulated;
                scheduleMonthCount++;
            }
            wp.totalPlanQty = totalPlan;
            wp.totalSimulatedQty = totalSimulated;
            wp.totalDeltaQty = totalSimulated - totalPlan;
            productIds.add(sap.Product__c);
            totalSimQtyByProduct.put(sap.Product__c, totalSimulated);
            maxMonthCount = Math.max(maxMonthCount, scheduleMonthCount);

            // BOM指定を記録
            if (sap.BOM_Header__c != null) {
                if (!bomIdsByProduct.containsKey(sap.Product__c)) {
                    bomIdsByProduct.put(sap.Product__c, new Set<Id>());
                }
                bomIdsByProduct.get(sap.Product__c).add(sap.BOM_Header__c);
            }

            // SupplierImpact用の仮ProductImpact
            ProductImpact pi = new ProductImpact();
            pi.productName = wp.productName;
            pi.productId = wp.productId;
            pi.totalVarianceQty = wp.totalDeltaQty;
            pi.suppliers = wp.suppliers;
            impactMap.put(sap.Product__c, pi);

            result.products.add(wp);
        }

        if (!productIds.isEmpty()) {
            expandBOM(productIds, impactMap, totalSimQtyByProduct, maxMonthCount, bomIdsByProduct);
            // WhatIfProductのsuppliersにコピー
            for (WhatIfProduct wp : result.products) {
                ProductImpact pi = impactMap.get(wp.productId);
                if (pi != null) wp.suppliers = pi.suppliers;
            }
        }

        // 品質データ取得（影響サプライヤー）
        Set<Id> supplierIds = new Set<Id>();
        for (WhatIfProduct wp : result.products) {
            for (SupplierImpact si : wp.suppliers) {
                supplierIds.add(si.supplierId);
            }
        }
        List<CAInfo> caList = new List<CAInfo>();
        if (!supplierIds.isEmpty()) {
            List<Corrective_Action__c> cas = [
                SELECT Name, Title__c, Severity__c, Category__c, Phase__c,
                       Supplier__r.Name, Product__r.Name, CreatedDate
                FROM Corrective_Action__c
                WHERE Supplier__c IN :supplierIds
                  AND Product__c IN :productIds
                ORDER BY CreatedDate DESC
                LIMIT 30
            ];
            for (Corrective_Action__c ca : cas) {
                CAInfo ci = new CAInfo();
                ci.name = ca.Name;
                ci.title = ca.Title__c;
                ci.severity = ca.Severity__c;
                ci.category = ca.Category__c;
                ci.phase = ca.Phase__c;
                ci.supplierName = ca.Supplier__r.Name;
                ci.productName = ca.Product__r.Name;
                caList.add(ci);
            }
        }

        // キャパシティアラート収集
        List<Map<String, Object>> capacityAlerts = new List<Map<String, Object>>();
        for (WhatIfProduct wp : result.products) {
            for (SupplierImpact si : wp.suppliers) {
                if (si.capacities != null) {
                    for (CapacityInfo ci : si.capacities) {
                        if (ci.utilizationPct > 100) {
                            Map<String, Object> alert = new Map<String, Object>();
                            alert.put('partNumber', ci.partNumber);
                            alert.put('partName', ci.partName);
                            alert.put('supplier', si.supplierName);
                            alert.put('site', ci.siteName);
                            alert.put('monthlyCapacity', ci.monthlyCapacity);
                            alert.put('simulatedDemand', ci.simulatedDemandQty);
                            alert.put('utilizationPct', ci.utilizationPct);
                            if (ci.alternatives != null && !ci.alternatives.isEmpty()) {
                                List<Map<String, Object>> altList = new List<Map<String, Object>>();
                                for (AlternativeSite alt : ci.alternatives) {
                                    Map<String, Object> altMap = new Map<String, Object>();
                                    altMap.put('siteName', alt.siteName);
                                    altMap.put('spareCapacity', alt.spareCapacity);
                                    altList.add(altMap);
                                }
                                alert.put('alternativeSites', altList);
                            }
                            capacityAlerts.add(alert);
                        }
                    }
                }
            }
        }

        // AI分析用データ構築 → Prompt Template呼出し
        result.aiAnalysis = callWhatIfPrompt(result, caList, capacityAlerts);

        return result;
    }

    // BOM Expansion (共通) - 後方互換: BOM指定なし
    private static void expandBOM(Set<Id> productIds, Map<Id, ProductImpact> productMap, Map<Id, Decimal> totalSimQtyByProduct) {
        expandBOM(productIds, productMap, totalSimQtyByProduct, 1, new Map<Id, Set<Id>>());
    }

    private static void expandBOM(Set<Id> productIds, Map<Id, ProductImpact> productMap, Map<Id, Decimal> totalSimQtyByProduct, Integer monthCount) {
        expandBOM(productIds, productMap, totalSimQtyByProduct, monthCount, new Map<Id, Set<Id>>());
    }

    private static void expandBOM(Set<Id> productIds, Map<Id, ProductImpact> productMap, Map<Id, Decimal> totalSimQtyByProduct, Integer monthCount, Map<Id, Set<Id>> bomIdsByProduct) {
        // BOM_Header__c指定があればそのBOMのみ、なければProduct__cの承認済みBOM全て
        Set<Id> specifiedBomIds = new Set<Id>();
        Set<Id> unspecifiedProductIds = new Set<Id>();
        for (Id prodId : productIds) {
            if (bomIdsByProduct.containsKey(prodId) && !bomIdsByProduct.get(prodId).isEmpty()) {
                specifiedBomIds.addAll(bomIdsByProduct.get(prodId));
            } else {
                unspecifiedProductIds.add(prodId);
            }
        }

        List<BOM_Part__c> parts = new List<BOM_Part__c>();

        // 指定BOMがある場合: そのBOM IDで直接検索
        if (!specifiedBomIds.isEmpty()) {
            parts.addAll([
                SELECT Part_Name__c, Part_Number__c, Quantity__c, Supplier__c, Supplier__r.Name,
                       Manufacturing_Site__c, Manufacturing_Site__r.Name,
                       BOM_SubComponent__r.BOM_Line__r.Quantity__c,
                       BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c,
                       BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name
                FROM BOM_Part__c
                WHERE BOM_SubComponent__r.BOM_Line__r.BOM_Header__c IN :specifiedBomIds
                  AND Supplier__c != null
            ]);
        }

        // BOM未指定の製品: 従来通りProduct__c + 承認済みで検索（後方互換）
        if (!unspecifiedProductIds.isEmpty()) {
            parts.addAll([
                SELECT Part_Name__c, Part_Number__c, Quantity__c, Supplier__c, Supplier__r.Name,
                       Manufacturing_Site__c, Manufacturing_Site__r.Name,
                       BOM_SubComponent__r.BOM_Line__r.Quantity__c,
                       BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c,
                       BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name
                FROM BOM_Part__c
                WHERE BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c IN :unspecifiedProductIds
                  AND BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Status__c = '承認済'
                  AND Supplier__c != null
            ]);
        }

        // 1. サプライヤー影響を構築
        Map<String, SupplierImpact> supplierMap = new Map<String, SupplierImpact>();
        Set<String> allPartNumbers = new Set<String>();
        Set<Id> allSiteIds = new Set<Id>();

        for (BOM_Part__c p : parts) {
            Id prodId = p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c;
            ProductImpact pi = productMap.get(prodId);
            if (pi == null) continue;

            String key = prodId + '-' + p.Supplier__c;
            SupplierImpact si = supplierMap.get(key);
            if (si == null) {
                si = new SupplierImpact();
                si.supplierId = p.Supplier__c;
                si.supplierName = p.Supplier__r.Name;
                si.parts = new List<PartInfo>();
                si.totalImpactQty = 0;
                si.capacities = new List<CapacityInfo>();
                supplierMap.put(key, si);
                pi.suppliers.add(si);
            }
            PartInfo pInfo = new PartInfo();
            pInfo.partName = p.Part_Name__c;
            pInfo.partNumber = p.Part_Number__c;
            pInfo.qtyPerUnit = p.Quantity__c != null ? p.Quantity__c : 0;
            pInfo.impactQty = pInfo.qtyPerUnit * pi.totalVarianceQty;
            si.parts.add(pInfo);
            si.totalImpactQty += pInfo.impactQty;

            if (p.Part_Number__c != null) allPartNumbers.add(p.Part_Number__c);
            if (p.Manufacturing_Site__c != null) allSiteIds.add(p.Manufacturing_Site__c);
        }

        // 2. キャパシティデータ取得
        if (allPartNumbers.isEmpty() || allSiteIds.isEmpty()) return;

        List<Supplier_Capacity__c> capacities = [
            SELECT Part_Number__c, Part_Name__c, Monthly_Capacity__c,
                   Manufacturing_Site__c, Manufacturing_Site__r.Name,
                   Manufacturing_Site__r.Supplier__c
            FROM Supplier_Capacity__c
            WHERE Part_Number__c IN :allPartNumbers
              AND Manufacturing_Site__c IN :allSiteIds
              AND (Effective_To__c = null OR Effective_To__c >= TODAY)
              AND Effective_From__c <= TODAY
        ];

        // キャパシティをサイト+部品番号でマップ化
        Map<String, Supplier_Capacity__c> capMap = new Map<String, Supplier_Capacity__c>();
        for (Supplier_Capacity__c sc : capacities) {
            String capKey = sc.Manufacturing_Site__c + '-' + sc.Part_Number__c;
            capMap.put(capKey, sc);
        }

        // 代替サイト検索用: 同一サプライヤーの全キャパシティ（被災地域外含む）
        Set<Id> supplierIdsForAlt = new Set<Id>();
        for (Supplier_Capacity__c sc : capacities) {
            if (sc.Manufacturing_Site__r.Supplier__c != null) {
                supplierIdsForAlt.add(sc.Manufacturing_Site__r.Supplier__c);
            }
        }
        List<Supplier_Capacity__c> allSupplierCaps = new List<Supplier_Capacity__c>();
        if (!supplierIdsForAlt.isEmpty()) {
            allSupplierCaps = [
                SELECT Part_Number__c, Part_Name__c, Monthly_Capacity__c,
                       Manufacturing_Site__c, Manufacturing_Site__r.Name,
                       Manufacturing_Site__r.Supplier__c
                FROM Supplier_Capacity__c
                WHERE Part_Number__c IN :allPartNumbers
                  AND Manufacturing_Site__r.Supplier__c IN :supplierIdsForAlt
                  AND (Effective_To__c = null OR Effective_To__c >= TODAY)
                  AND Effective_From__c <= TODAY
            ];
        }

        // 代替サイトをサプライヤー+部品番号でグループ化
        Map<String, List<Supplier_Capacity__c>> altCapsBySupplierPart = new Map<String, List<Supplier_Capacity__c>>();
        for (Supplier_Capacity__c sc : allSupplierCaps) {
            String altKey = sc.Manufacturing_Site__r.Supplier__c + '-' + sc.Part_Number__c;
            if (!altCapsBySupplierPart.containsKey(altKey)) {
                altCapsBySupplierPart.put(altKey, new List<Supplier_Capacity__c>());
            }
            altCapsBySupplierPart.get(altKey).add(sc);
        }

        // 3. 各サプライヤー影響にキャパシティ情報を付与
        for (BOM_Part__c p : parts) {
            Id prodId = p.BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c;
            ProductImpact pi = productMap.get(prodId);
            if (pi == null || p.Part_Number__c == null || p.Manufacturing_Site__c == null) continue;

            String capKey = p.Manufacturing_Site__c + '-' + p.Part_Number__c;
            Supplier_Capacity__c cap = capMap.get(capKey);
            if (cap == null) continue;

            String siKey = prodId + '-' + p.Supplier__c;
            SupplierImpact si = supplierMap.get(siKey);
            if (si == null) continue;

            // 需要量計算（月平均ベース — キャパは月産上限なので月単位で比較）
            Decimal qtyPerUnit = p.Quantity__c != null ? p.Quantity__c : 0;
            Decimal monthlyDemandQty = 0;
            Decimal monthlySimDemandQty = 0;
            Integer months = monthCount > 0 ? monthCount : 1;

            if (totalSimQtyByProduct != null && totalSimQtyByProduct.containsKey(prodId)) {
                // シミュレーション時: 全月合計 → 月平均
                monthlySimDemandQty = qtyPerUnit * (totalSimQtyByProduct.get(prodId) / months);
                monthlyDemandQty = monthlySimDemandQty;
            } else {
                monthlyDemandQty = qtyPerUnit * (Math.abs(pi.totalVarianceQty) / months);
            }

            CapacityInfo ci = new CapacityInfo();
            ci.partNumber = p.Part_Number__c;
            ci.partName = cap.Part_Name__c != null ? cap.Part_Name__c : p.Part_Name__c;
            ci.monthlyCapacity = cap.Monthly_Capacity__c != null ? cap.Monthly_Capacity__c : 0;
            ci.totalDemandQty = monthlyDemandQty;
            ci.simulatedDemandQty = monthlySimDemandQty;
            ci.siteId = String.valueOf(p.Manufacturing_Site__c);
            ci.siteName = p.Manufacturing_Site__r.Name;
            ci.utilizationPct = ci.monthlyCapacity > 0
                ? (Math.max(ci.totalDemandQty, ci.simulatedDemandQty) / ci.monthlyCapacity * 100).setScale(1) : 0;
            ci.alternatives = new List<AlternativeSite>();

            // 4. 稼働率100%超の場合、代替サイトを検索
            if (ci.utilizationPct > 100) {
                String altKey = p.Supplier__c + '-' + p.Part_Number__c;
                List<Supplier_Capacity__c> altCaps = altCapsBySupplierPart.get(altKey);
                if (altCaps != null) {
                    for (Supplier_Capacity__c altCap : altCaps) {
                        // 同一サイトはスキップ
                        if (altCap.Manufacturing_Site__c == p.Manufacturing_Site__c) continue;

                        Decimal altCapacity = altCap.Monthly_Capacity__c != null ? altCap.Monthly_Capacity__c : 0;
                        // 簡易的に代替サイトの現在需要を0と仮定（精密計算は別途必要）
                        AlternativeSite alt = new AlternativeSite();
                        alt.siteId = String.valueOf(altCap.Manufacturing_Site__c);
                        alt.siteName = altCap.Manufacturing_Site__r.Name;
                        alt.monthlyCapacity = altCapacity;
                        alt.currentDemand = 0;
                        alt.spareCapacity = altCapacity;
                        ci.alternatives.add(alt);
                    }
                }
            }

            si.capacities.add(ci);
        }
    }

    // Prompt Template呼出し
    private static String callWhatIfPrompt(WhatIfResult result, List<CAInfo> caList, List<Map<String, Object>> capacityAlerts) {
        Map<String, Object> data = new Map<String, Object>();

        // シナリオ概要
        List<Map<String, Object>> scenarioList = new List<Map<String, Object>>();
        for (WhatIfProduct wp : result.products) {
            Map<String, Object> s = new Map<String, Object>();
            s.put('product', wp.productName);
            s.put('changePct', wp.changePct);
            s.put('totalPlanQty', wp.totalPlanQty);
            s.put('totalSimulatedQty', wp.totalSimulatedQty);
            s.put('deltaQty', wp.totalDeltaQty);

            // 月別トレンド
            List<Map<String, Object>> monthList = new List<Map<String, Object>>();
            for (WhatIfMonth wm : wp.months) {
                Map<String, Object> mm = new Map<String, Object>();
                mm.put('month', String.valueOf(wm.month));
                mm.put('plan', wm.planQty);
                mm.put('actual', wm.actualQty);
                mm.put('simulated', wm.simulatedQty);
                monthList.add(mm);
            }
            s.put('months', monthList);

            // サプライヤー影響
            List<Map<String, Object>> supList = new List<Map<String, Object>>();
            for (SupplierImpact si : wp.suppliers) {
                Map<String, Object> sm = new Map<String, Object>();
                sm.put('supplier', si.supplierName);
                sm.put('totalImpactQty', si.totalImpactQty);
                sm.put('partCount', si.parts.size());
                supList.add(sm);
            }
            s.put('suppliers', supList);
            scenarioList.add(s);
        }
        data.put('scenarios', scenarioList);

        // 品質履歴
        List<Map<String, Object>> caMapList = new List<Map<String, Object>>();
        for (CAInfo ci : caList) {
            Map<String, Object> cm = new Map<String, Object>();
            cm.put('name', ci.name);
            cm.put('title', ci.title);
            cm.put('severity', ci.severity);
            cm.put('category', ci.category);
            cm.put('phase', ci.phase);
            cm.put('supplier', ci.supplierName);
            cm.put('product', ci.productName);
            caMapList.add(cm);
        }
        data.put('qualityIssues', caMapList);

        // キャパシティアラート
        if (capacityAlerts != null && !capacityAlerts.isEmpty()) {
            data.put('capacityAlerts', capacityAlerts);
        }

        data.put('todayDate', String.valueOf(Date.today()));

        String jsonData = JSON.serialize(data);

        try {
            ConnectApi.EinsteinPromptTemplateGenerationsInput input =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            input.isPreview = false;
            input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            input.additionalConfig.applicationName = 'PromptBuilderPreview';
            input.additionalConfig.numGenerations = 1;
            input.additionalConfig.temperature = 0.2;

            Map<String, ConnectApi.WrappedValue> inputParams =
                new Map<String, ConnectApi.WrappedValue>();
            ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
            wv.value = jsonData;
            inputParams.put('Input:simulationData', wv);
            input.inputParams = inputParams;

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation genResult =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                    'DemandWhatIfAnalysis', input);

            if (genResult.generations != null && !genResult.generations.isEmpty()) {
                return genResult.generations[0].text;
            }
            return 'AI分析の生成に失敗しました。';
        } catch (Exception e) {
            return 'AI分析エラー: ' + e.getMessage();
        }
    }

    // Inner Classes (既存)
    public class ImpactAnalysis {
        @AuraEnabled public List<ProductImpact> products;
    }
    public class ProductImpact {
        @AuraEnabled public String productName;
        @AuraEnabled public Id productId;
        @AuraEnabled public List<MonthVariance> months;
        @AuraEnabled public Decimal totalVarianceQty;
        @AuraEnabled public Decimal totalVariancePct;
        @AuraEnabled public List<SupplierImpact> suppliers;
    }
    public class MonthVariance {
        @AuraEnabled public Date month;
        @AuraEnabled public Decimal planQty;
        @AuraEnabled public Decimal actualQty;
        @AuraEnabled public Decimal varianceQty;
        @AuraEnabled public Decimal variancePct;
    }
    public class SupplierImpact {
        @AuraEnabled public Id supplierId;
        @AuraEnabled public String supplierName;
        @AuraEnabled public List<PartInfo> parts;
        @AuraEnabled public Decimal totalImpactQty;
        @AuraEnabled public List<CapacityInfo> capacities;
    }
    public class CapacityInfo {
        @AuraEnabled public String partNumber;
        @AuraEnabled public String partName;
        @AuraEnabled public Decimal monthlyCapacity;
        @AuraEnabled public Decimal totalDemandQty;
        @AuraEnabled public Decimal simulatedDemandQty;
        @AuraEnabled public Decimal utilizationPct;
        @AuraEnabled public String siteId;
        @AuraEnabled public String siteName;
        @AuraEnabled public List<AlternativeSite> alternatives;
    }
    public class AlternativeSite {
        @AuraEnabled public String siteId;
        @AuraEnabled public String siteName;
        @AuraEnabled public Decimal monthlyCapacity;
        @AuraEnabled public Decimal currentDemand;
        @AuraEnabled public Decimal spareCapacity;
    }
    public class PartInfo {
        @AuraEnabled public String partName;
        @AuraEnabled public String partNumber;
        @AuraEnabled public Decimal qtyPerUnit;
        @AuraEnabled public Decimal impactQty;
    }

    // Inner Classes (What-If)
    public class ScenarioInput {
        public Id productId;
        public Decimal changePct;
    }
    public class WhatIfResult {
        @AuraEnabled public List<WhatIfProduct> products;
        @AuraEnabled public String aiAnalysis;
    }
    public class WhatIfProduct {
        @AuraEnabled public String productName;
        @AuraEnabled public Id productId;
        @AuraEnabled public Decimal changePct;
        @AuraEnabled public Decimal totalPlanQty;
        @AuraEnabled public Decimal totalSimulatedQty;
        @AuraEnabled public Decimal totalDeltaQty;
        @AuraEnabled public List<WhatIfMonth> months;
        @AuraEnabled public List<SupplierImpact> suppliers;
    }
    public class WhatIfMonth {
        @AuraEnabled public Date month;
        @AuraEnabled public Decimal planQty;
        @AuraEnabled public Decimal actualQty;
        @AuraEnabled public Decimal simulatedQty;
    }
    public class CAInfo {
        public String name;
        public String title;
        public String severity;
        public String category;
        public String phase;
        public String supplierName;
        public String productName;
    }
}
