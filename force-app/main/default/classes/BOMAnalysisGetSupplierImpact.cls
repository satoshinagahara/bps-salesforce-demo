public class BOMAnalysisGetSupplierImpact {

    public class Request {
        @InvocableVariable(label='サプライヤー' description='分析対象のサプライヤーのID。レコードページのコンテキストから自動取得されます。' required=true)
        public String supplierId;
    }

    public class Result {
        @InvocableVariable(label='サプライヤーインパクト分析レポート')
        public String analysisReport;
    }

    @InvocableMethod(label='サプライヤーインパクト分析' description='指定サプライヤーが供給する全部品、影響を受ける商品、関連する商談パイプラインへの影響を分析し、レポートを生成します')
    public static List<Result> analyze(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            String jsonData = buildAnalysisData(req.supplierId);
            res.analysisReport = generateReport(jsonData);
            results.add(res);
        }
        return results;
    }

    private static String buildAnalysisData(String supplierId) {
        Map<String, Object> fullData = new Map<String, Object>();

        // 1. Supplier basic info
        List<Account> suppliers = [
            SELECT Id, Name, Type, Phone, BillingCity, BillingState, Website, Description
            FROM Account WHERE Id = :supplierId LIMIT 1
        ];
        if (suppliers.isEmpty()) {
            return '{"error":"サプライヤーが見つかりません"}';
        }
        Account sup = suppliers[0];
        Map<String, Object> supInfo = new Map<String, Object>();
        supInfo.put('name', sup.Name);
        supInfo.put('type', sup.Type);
        supInfo.put('phone', sup.Phone);
        supInfo.put('location', (sup.BillingCity != null ? sup.BillingCity : '') +
                    (sup.BillingState != null ? ' ' + sup.BillingState : ''));
        fullData.put('supplier', supInfo);

        // 2. All parts supplied by this supplier
        List<BOM_Part__c> parts = [
            SELECT Id, Part_Name__c, Part_Number__c, Quantity__c, Unit_Cost__c, Extended_Cost__c,
                   Lead_Time_Days__c, Make_or_Buy__c,
                   BOM_SubComponent__c, BOM_SubComponent__r.Component_Name__c,
                   BOM_SubComponent__r.BOM_Line__c,
                   BOM_SubComponent__r.BOM_Line__r.Name,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__c,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.ProductCode
            FROM BOM_Part__c
            WHERE Supplier__c = :supplierId
            ORDER BY Part_Number__c
        ];

        if (parts.isEmpty()) {
            fullData.put('suppliedParts', new List<Object>());
            fullData.put('summary', 'このサプライヤーから供給されている部品はありません');
            return JSON.serialize(fullData);
        }

        // 3. Build parts list and collect affected products
        List<Map<String, Object>> partList = new List<Map<String, Object>>();
        Map<Id, Map<String, Object>> affectedProducts = new Map<Id, Map<String, Object>>();
        Set<Id> productIds = new Set<Id>();
        Decimal totalPartsCost = 0;

        for (BOM_Part__c pt : parts) {
            Map<String, Object> partMap = new Map<String, Object>();
            partMap.put('partName', pt.Part_Name__c);
            partMap.put('partNumber', pt.Part_Number__c);
            partMap.put('quantity', pt.Quantity__c);
            partMap.put('unitCost', pt.Unit_Cost__c);
            partMap.put('extendedCost', pt.Extended_Cost__c);
            partMap.put('leadTimeDays', pt.Lead_Time_Days__c);

            String productName = pt.BOM_SubComponent__r?.BOM_Line__r?.BOM_Header__r?.Product__r?.Name;
            String productCode = pt.BOM_SubComponent__r?.BOM_Line__r?.BOM_Header__r?.Product__r?.ProductCode;
            Id productId = pt.BOM_SubComponent__r?.BOM_Line__r?.BOM_Header__r?.Product__c;
            partMap.put('productName', productName);
            partMap.put('productCode', productCode);
            partMap.put('subComponent', pt.BOM_SubComponent__r?.Component_Name__c);
            partList.add(partMap);

            if (pt.Extended_Cost__c != null) totalPartsCost += pt.Extended_Cost__c;

            if (productId != null) {
                productIds.add(productId);
                if (!affectedProducts.containsKey(productId)) {
                    Map<String, Object> pm = new Map<String, Object>();
                    pm.put('productId', productId);
                    pm.put('productName', productName);
                    pm.put('productCode', productCode);
                    pm.put('partCount', 0);
                    pm.put('supplierCostInProduct', (Decimal)0);
                    affectedProducts.put(productId, pm);
                }
                Map<String, Object> pm = affectedProducts.get(productId);
                pm.put('partCount', (Integer)pm.get('partCount') + 1);
                Decimal cost = pt.Extended_Cost__c != null ? pt.Extended_Cost__c : 0;
                pm.put('supplierCostInProduct', (Decimal)pm.get('supplierCostInProduct') + cost);
            }
        }
        fullData.put('suppliedParts', partList);
        fullData.put('totalPartsCost', totalPartsCost);

        // 4. Unique parts (by Part_Number) for cross-product impact
        Map<String, List<String>> partToProducts = new Map<String, List<String>>();
        for (BOM_Part__c pt : parts) {
            String pn = pt.Part_Number__c;
            String prodName = pt.BOM_SubComponent__r?.BOM_Line__r?.BOM_Header__r?.Product__r?.Name;
            if (pn != null && prodName != null) {
                if (!partToProducts.containsKey(pn))
                    partToProducts.put(pn, new List<String>());
                if (!partToProducts.get(pn).contains(prodName))
                    partToProducts.get(pn).add(prodName);
            }
        }
        List<Map<String, Object>> sharedParts = new List<Map<String, Object>>();
        for (String pn : partToProducts.keySet()) {
            List<String> prods = partToProducts.get(pn);
            if (prods.size() > 1) {
                Map<String, Object> sp = new Map<String, Object>();
                sp.put('partNumber', pn);
                sp.put('affectedProducts', prods);
                sp.put('productCount', prods.size());
                sharedParts.add(sp);
            }
        }
        fullData.put('crossProductParts', sharedParts);

        // 5. Affected products with BOM total cost for dependency ratio
        if (!productIds.isEmpty()) {
            List<BOM_Header__c> headers = [
                SELECT Product__c, Total_Cost__c
                FROM BOM_Header__c WHERE Product__c IN :productIds
            ];
            Map<Id, Decimal> bomTotalByProduct = new Map<Id, Decimal>();
            for (BOM_Header__c bh : headers) {
                bomTotalByProduct.put(bh.Product__c, bh.Total_Cost__c);
            }
            for (Id pid : affectedProducts.keySet()) {
                Map<String, Object> pm = affectedProducts.get(pid);
                Decimal bomTotal = bomTotalByProduct.get(pid);
                pm.put('bomTotalCost', bomTotal);
                Decimal supplierCost = (Decimal)pm.get('supplierCostInProduct');
                if (bomTotal != null && bomTotal > 0) {
                    pm.put('supplierDependencyPct', (supplierCost / bomTotal * 100).setScale(1));
                }
            }
        }
        fullData.put('affectedProducts', affectedProducts.values());

        // 6. Pipeline impact - opportunities containing affected products
        if (!productIds.isEmpty()) {
            List<OpportunityLineItem> olis = [
                SELECT Opportunity.Id, Opportunity.Name, Opportunity.StageName,
                       Opportunity.Amount, Opportunity.CloseDate, Opportunity.Owner.Name,
                       Product2.Name, Quantity, TotalPrice
                FROM OpportunityLineItem
                WHERE Product2Id IN :productIds AND Opportunity.IsClosed = false
                ORDER BY Opportunity.CloseDate ASC LIMIT 50
            ];
            Map<Id, Map<String, Object>> oppMap = new Map<Id, Map<String, Object>>();
            Decimal pipelineTotal = 0;
            for (OpportunityLineItem oli : olis) {
                Id oppId = oli.Opportunity.Id;
                if (!oppMap.containsKey(oppId)) {
                    Map<String, Object> om = new Map<String, Object>();
                    om.put('name', oli.Opportunity.Name);
                    om.put('stage', oli.Opportunity.StageName);
                    om.put('amount', oli.Opportunity.Amount);
                    om.put('closeDate', String.valueOf(oli.Opportunity.CloseDate));
                    om.put('owner', oli.Opportunity.Owner.Name);
                    om.put('affectedProducts', new List<String>());
                    oppMap.put(oppId, om);
                    if (oli.Opportunity.Amount != null) pipelineTotal += oli.Opportunity.Amount;
                }
                ((List<String>)oppMap.get(oppId).get('affectedProducts')).add(oli.Product2.Name);
            }
            Map<String, Object> pipeline = new Map<String, Object>();
            pipeline.put('opportunities', oppMap.values());
            pipeline.put('totalPipelineAmount', pipelineTotal);
            pipeline.put('opportunityCount', oppMap.size());
            fullData.put('pipelineImpact', pipeline);
        }

        // 7. Summary stats
        Map<String, Object> summary = new Map<String, Object>();
        summary.put('totalPartsSupplied', parts.size());
        summary.put('uniquePartTypes', partToProducts.keySet().size());
        summary.put('affectedProductCount', affectedProducts.size());
        summary.put('crossProductPartCount', sharedParts.size());
        fullData.put('impactSummary', summary);

        fullData.put('analysisDate', String.valueOf(Date.today()));
        return JSON.serialize(fullData);
    }

    private static String generateReport(String jsonData) {
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsInput input =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            input.isPreview = false;
            input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            input.additionalConfig.numGenerations = 1;
            input.additionalConfig.temperature = 0.2;

            Map<String, ConnectApi.WrappedValue> inputParams =
                new Map<String, ConnectApi.WrappedValue>();
            ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
            wv.value = jsonData;
            inputParams.put('Input:analysisData', wv);
            input.inputParams = inputParams;

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation result =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                    'BOMSupplierImpactAnalysis', input);

            return result.generations[0].text;
        } catch (Exception e) {
            return 'レポート生成中にエラーが発生しました: ' + e.getMessage() +
                   '\n\n--- 生データ（JSON） ---\n' + jsonData;
        }
    }
}
