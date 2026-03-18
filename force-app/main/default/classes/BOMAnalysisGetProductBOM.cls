public class BOMAnalysisGetProductBOM {

    public class Request {
        @InvocableVariable(label='商品ID' description='Product2のSalesforce ID' required=true)
        public String productId;
    }

    public class Result {
        @InvocableVariable(label='BOM分析レポート')
        public String analysisReport;
    }

    @InvocableMethod(label='製品BOM構成分析' description='指定された商品のBOM全階層（Header→Line→SubComponent→Part）、サプライヤー依存度、関連商談パイプラインを分析し、レポートを生成します')
    public static List<Result> analyze(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            String jsonData = buildAnalysisData(req.productId);
            res.analysisReport = generateReport(jsonData);
            results.add(res);
        }
        return results;
    }

    private static String buildAnalysisData(String productId) {
        Map<String, Object> fullData = new Map<String, Object>();

        // 1. Product basic info
        List<Product2> products = [
            SELECT Id, Name, ProductCode, Family, Description, IsActive
            FROM Product2 WHERE Id = :productId LIMIT 1
        ];
        if (products.isEmpty()) {
            return '{"error":"商品が見つかりません"}';
        }
        Product2 p = products[0];
        Map<String, Object> prodInfo = new Map<String, Object>();
        prodInfo.put('name', p.Name);
        prodInfo.put('productCode', p.ProductCode);
        prodInfo.put('family', p.Family);
        prodInfo.put('description', p.Description);
        fullData.put('product', prodInfo);

        // 2. BOM Header
        List<BOM_Header__c> headers = [
            SELECT Id, Name, BOM_Number__c, BOM_Type__c, Status__c, Revision__c,
                   Total_Cost__c, Effective_From__c, Effective_To__c
            FROM BOM_Header__c WHERE Product__c = :productId LIMIT 1
        ];
        if (headers.isEmpty()) {
            fullData.put('bomHeader', null);
            fullData.put('error', 'この商品にBOMデータが存在しません');
            return JSON.serialize(fullData);
        }
        BOM_Header__c h = headers[0];
        Map<String, Object> headerInfo = new Map<String, Object>();
        headerInfo.put('bomNumber', h.BOM_Number__c);
        headerInfo.put('bomType', h.BOM_Type__c);
        headerInfo.put('status', h.Status__c);
        headerInfo.put('revision', h.Revision__c);
        headerInfo.put('totalCost', h.Total_Cost__c);
        fullData.put('bomHeader', headerInfo);

        // 3. BOM Lines -> SubComponents -> Parts (full hierarchy)
        List<BOM_Line__c> lines = [
            SELECT Id, Name, Line_Number__c, Component_Type__c, Quantity__c,
                   Unit_Cost__c, Extended_Cost__c, Sub_Total_Cost__c, Lead_Time_Days__c, Notes__c
            FROM BOM_Line__c WHERE BOM_Header__c = :h.Id ORDER BY Line_Number__c
        ];
        Set<Id> lineIds = new Set<Id>();
        for (BOM_Line__c l : lines) lineIds.add(l.Id);

        List<BOM_SubComponent__c> subs = [
            SELECT Id, Name, Component_Name__c, BOM_Line__c, Sequence__c,
                   Process_Type__c, Material_Type__c, Quantity__c, Unit_Cost__c,
                   Extended_Cost__c, Part_Total_Cost__c
            FROM BOM_SubComponent__c WHERE BOM_Line__c IN :lineIds ORDER BY Sequence__c
        ];
        Set<Id> subIds = new Set<Id>();
        Map<Id, List<BOM_SubComponent__c>> subsByLine = new Map<Id, List<BOM_SubComponent__c>>();
        for (BOM_SubComponent__c s : subs) {
            subIds.add(s.Id);
            if (!subsByLine.containsKey(s.BOM_Line__c))
                subsByLine.put(s.BOM_Line__c, new List<BOM_SubComponent__c>());
            subsByLine.get(s.BOM_Line__c).add(s);
        }

        List<BOM_Part__c> parts = [
            SELECT Id, Name, Part_Name__c, Part_Number__c, BOM_SubComponent__c,
                   Quantity__c, Unit_Cost__c, Extended_Cost__c,
                   Lead_Time_Days__c, Make_or_Buy__c, Manufacturer__c,
                   Supplier__c, Supplier__r.Name
            FROM BOM_Part__c WHERE BOM_SubComponent__c IN :subIds ORDER BY Name
        ];
        Map<Id, List<BOM_Part__c>> partsBySub = new Map<Id, List<BOM_Part__c>>();
        for (BOM_Part__c pt : parts) {
            if (!partsBySub.containsKey(pt.BOM_SubComponent__c))
                partsBySub.put(pt.BOM_SubComponent__c, new List<BOM_Part__c>());
            partsBySub.get(pt.BOM_SubComponent__c).add(pt);
        }

        // Build hierarchy JSON
        List<Map<String, Object>> lineList = new List<Map<String, Object>>();
        for (BOM_Line__c l : lines) {
            Map<String, Object> lineMap = new Map<String, Object>();
            lineMap.put('name', l.Name);
            lineMap.put('lineNumber', l.Line_Number__c);
            lineMap.put('componentType', l.Component_Type__c);
            lineMap.put('quantity', l.Quantity__c);
            lineMap.put('unitCost', l.Unit_Cost__c);
            lineMap.put('extendedCost', l.Extended_Cost__c);
            lineMap.put('subTotalCost', l.Sub_Total_Cost__c);

            List<Map<String, Object>> subList = new List<Map<String, Object>>();
            if (subsByLine.containsKey(l.Id)) {
                for (BOM_SubComponent__c s : subsByLine.get(l.Id)) {
                    Map<String, Object> subMap = new Map<String, Object>();
                    subMap.put('name', s.Component_Name__c);
                    subMap.put('processType', s.Process_Type__c);
                    subMap.put('materialType', s.Material_Type__c);
                    subMap.put('quantity', s.Quantity__c);
                    subMap.put('unitCost', s.Unit_Cost__c);
                    subMap.put('partTotalCost', s.Part_Total_Cost__c);

                    List<Map<String, Object>> partList = new List<Map<String, Object>>();
                    if (partsBySub.containsKey(s.Id)) {
                        for (BOM_Part__c pt : partsBySub.get(s.Id)) {
                            Map<String, Object> partMap = new Map<String, Object>();
                            partMap.put('partName', pt.Part_Name__c);
                            partMap.put('partNumber', pt.Part_Number__c);
                            partMap.put('quantity', pt.Quantity__c);
                            partMap.put('unitCost', pt.Unit_Cost__c);
                            partMap.put('extendedCost', pt.Extended_Cost__c);
                            partMap.put('leadTimeDays', pt.Lead_Time_Days__c);
                            partMap.put('makeOrBuy', pt.Make_or_Buy__c);
                            partMap.put('supplier', pt.Supplier__r != null ? pt.Supplier__r.Name : null);
                            partList.add(partMap);
                        }
                    }
                    subMap.put('parts', partList);
                    subList.add(subMap);
                }
            }
            lineMap.put('subComponents', subList);
            lineList.add(lineMap);
        }
        fullData.put('bomLines', lineList);

        // 4. Supplier dependency summary
        Map<String, Map<String, Object>> supplierMap = new Map<String, Map<String, Object>>();
        for (BOM_Part__c pt : parts) {
            String supName = pt.Supplier__r != null ? pt.Supplier__r.Name : '未割当';
            if (!supplierMap.containsKey(supName)) {
                Map<String, Object> sm = new Map<String, Object>();
                sm.put('name', supName);
                sm.put('partCount', 0);
                sm.put('totalCost', (Decimal)0);
                supplierMap.put(supName, sm);
            }
            Map<String, Object> sm = supplierMap.get(supName);
            sm.put('partCount', (Integer)sm.get('partCount') + 1);
            Decimal cost = pt.Extended_Cost__c != null ? pt.Extended_Cost__c : 0;
            sm.put('totalCost', (Decimal)sm.get('totalCost') + cost);
        }
        fullData.put('supplierDependency', supplierMap.values());

        // 5. Related opportunities (products linked via OpportunityLineItem)
        List<OpportunityLineItem> olis = [
            SELECT Opportunity.Name, Opportunity.StageName, Opportunity.Amount,
                   Opportunity.CloseDate, Opportunity.IsClosed, Opportunity.IsWon,
                   Quantity, TotalPrice
            FROM OpportunityLineItem
            WHERE Product2Id = :productId AND Opportunity.IsClosed = false
            ORDER BY Opportunity.CloseDate ASC LIMIT 30
        ];
        List<Map<String, Object>> oppList = new List<Map<String, Object>>();
        Decimal pipelineTotal = 0;
        for (OpportunityLineItem oli : olis) {
            Map<String, Object> oppMap = new Map<String, Object>();
            oppMap.put('name', oli.Opportunity.Name);
            oppMap.put('stage', oli.Opportunity.StageName);
            oppMap.put('amount', oli.Opportunity.Amount);
            oppMap.put('closeDate', String.valueOf(oli.Opportunity.CloseDate));
            oppMap.put('lineQuantity', oli.Quantity);
            oppMap.put('lineTotal', oli.TotalPrice);
            oppList.add(oppMap);
            if (oli.Opportunity.Amount != null) pipelineTotal += oli.Opportunity.Amount;
        }
        Map<String, Object> pipeline = new Map<String, Object>();
        pipeline.put('openOpportunities', oppList);
        pipeline.put('totalPipelineAmount', pipelineTotal);
        pipeline.put('opportunityCount', oppList.size());
        fullData.put('pipeline', pipeline);

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
                    'BOMProductAnalysis', input);

            return result.generations[0].text;
        } catch (Exception e) {
            return 'レポート生成中にエラーが発生しました: ' + e.getMessage() +
                   '\n\n--- 生データ（JSON） ---\n' + jsonData;
        }
    }
}
