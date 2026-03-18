public with sharing class HorizontalDeploymentAction {

    public class Request {
        @InvocableVariable(label='是正措置の番号' description='是正措置のCA番号（例: CA-0000、CA-0001）を指定します。Salesforce IDでも可。' required=true)
        public String correctiveActionId;
    }

    public class Result {
        @InvocableVariable(label='水平展開分析レポート')
        public String deploymentReport;
    }

    @InvocableMethod(label='水平展開分析' description='是正措置を起点に、同一サプライヤー・同一部品・同一カテゴリの影響範囲を横断分析し、水平展開先を特定します')
    public static List<Result> analyze(List<Request> requests) {
        String inputId = requests[0].correctiveActionId;

        // CA名（CA-XXXX）でもSalesforce ID（18桁）でも受付可能にする
        Id caId;
        if (inputId != null && inputId.startsWith('CA-')) {
            List<Corrective_Action__c> found = [
                SELECT Id FROM Corrective_Action__c WHERE Name = :inputId LIMIT 1
            ];
            if (found.isEmpty()) {
                Result res = new Result();
                res.deploymentReport = '是正措置「' + inputId + '」が見つかりません。CA番号またはSalesforce IDを確認してください。';
                return new List<Result>{ res };
            }
            caId = found[0].Id;
        } else {
            try {
                caId = Id.valueOf(inputId);
            } catch (Exception e) {
                Result res = new Result();
                res.deploymentReport = '入力値「' + inputId + '」は有効な是正措置IDまたはCA番号ではありません。CA-XXXXの形式またはSalesforce IDで指定してください。';
                return new List<Result>{ res };
            }
        }

        // 1. 起点となる是正措置を取得
        Corrective_Action__c ca = [
            SELECT Id, Name, Title__c, Phase__c, Severity__c, Category__c,
                   Product__c, Product__r.Name, Product__r.ProductCode,
                   Supplier__c, Supplier__r.Name,
                   BOM_Part__c, BOM_Part__r.Part_Name__c, BOM_Part__r.Part_Number__c,
                   D4_Root_Cause__c, D5_Permanent_Action__c, D7_Prevention__c,
                   Impact_Scope__c, Horizontal_Deployment__c,
                   Case__c, Case__r.CaseNumber, Case__r.Account.Name
            FROM Corrective_Action__c
            WHERE Id = :caId
            LIMIT 1
        ];

        Map<String, Object> data = new Map<String, Object>();

        // 起点CA情報
        Map<String, Object> sourceCA = new Map<String, Object>();
        sourceCA.put('name', ca.Name);
        sourceCA.put('title', ca.Title__c);
        sourceCA.put('phase', ca.Phase__c);
        sourceCA.put('severity', ca.Severity__c);
        sourceCA.put('category', ca.Category__c);
        sourceCA.put('productName', ca.Product__r?.Name);
        sourceCA.put('productCode', ca.Product__r?.ProductCode);
        sourceCA.put('supplierName', ca.Supplier__r?.Name);
        sourceCA.put('partName', ca.BOM_Part__r?.Part_Name__c);
        sourceCA.put('partNumber', ca.BOM_Part__r?.Part_Number__c);
        sourceCA.put('rootCause', ca.D4_Root_Cause__c);
        sourceCA.put('permanentAction', ca.D5_Permanent_Action__c);
        sourceCA.put('prevention', ca.D7_Prevention__c);
        sourceCA.put('impactScope', ca.Impact_Scope__c);
        sourceCA.put('customerName', ca.Case__r?.Account?.Name);
        sourceCA.put('caseNumber', ca.Case__r?.CaseNumber);
        data.put('sourceCA', sourceCA);

        // 2. ルーティング: Category__cに基づく展開方向
        String category = ca.Category__c;
        String routeKey = getRouteKey(category);
        data.put('routeType', getRouteLabel(routeKey));

        // 3. ルート別の影響分析データ収集
        Set<Id> affectedProductIds = new Set<Id>();
        if (ca.Product__c != null) affectedProductIds.add(ca.Product__c);

        if (routeKey == 'supplier') {
            // サプライヤー系: 同一部品番号が使われている他のBOM/製品を検索
            collectSupplierRouteData(ca, data, affectedProductIds);
        } else if (routeKey == 'design') {
            // 設計起因: 同一製品ファミリー・ベース製品の設計プロジェクトを重点検索
            collectDesignRouteData(ca, data, affectedProductIds);
        } else if (routeKey == 'manufacturing') {
            // 製造工程: 同一製造拠点の製品を検索
            collectManufacturingRouteData(ca, data, affectedProductIds);
        }

        // 4. 関連する過去の是正措置（ルートに応じたフィルタ）
        collectRelatedCAs(ca, caId, routeKey, data);

        // 5. 影響を受ける設計プロジェクト（全ルート共通、affectedProductIds基準）
        collectDesignProjects(affectedProductIds, data);

        // 6. 影響を受ける商談（影響製品に関連するオープン商談のみ）
        collectOpportunities(affectedProductIds, data);

        data.put('analysisDate', String.valueOf(Date.today()));

        // 7. Prompt Template呼び出し
        String jsonData = JSON.serialize(data);
        String report = callPromptTemplate(jsonData);

        // 8. 結果を Horizontal_Deployment__c に保存
        try {
            update new Corrective_Action__c(
                Id = caId,
                Horizontal_Deployment__c = report.length() > 10000 ? report.substring(0, 10000) : report
            );
        } catch (Exception e) {
            report += '\n\n※ 項目への保存に失敗しました: ' + e.getMessage();
        }

        Result res = new Result();
        res.deploymentReport = report;
        return new List<Result>{ res };
    }

    // ====== サプライヤールート ======
    // 同一部品番号が使われている他のBOM/製品を検索
    private static void collectSupplierRouteData(
        Corrective_Action__c ca, Map<String, Object> data, Set<Id> affectedProductIds
    ) {
        String partNumber = ca.BOM_Part__r?.Part_Number__c;
        if (partNumber == null) return;

        // 同一部品番号の部品が使われている他のBOM（＝他の製品）
        List<BOM_Part__c> sameParts = [
            SELECT Id, Part_Name__c, Part_Number__c, Supplier__r.Name,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Name,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__c,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.Name,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Product__r.ProductCode,
                   BOM_SubComponent__r.BOM_Line__r.BOM_Header__r.Status__c
            FROM BOM_Part__c
            WHERE Part_Number__c = :partNumber
            AND Id != :ca.BOM_Part__c
            ORDER BY Part_Name__c
            LIMIT 50
        ];
        List<Map<String, Object>> spList = new List<Map<String, Object>>();
        Set<String> affectedProductNames = new Set<String>();
        for (BOM_Part__c p : sameParts) {
            Map<String, Object> sp = new Map<String, Object>();
            sp.put('partName', p.Part_Name__c);
            sp.put('partNumber', p.Part_Number__c);
            sp.put('supplierName', p.Supplier__r?.Name);
            Id prodId = p.BOM_SubComponent__r?.BOM_Line__r?.BOM_Header__r?.Product__c;
            String prodName = p.BOM_SubComponent__r?.BOM_Line__r?.BOM_Header__r?.Product__r?.Name;
            String prodCode = p.BOM_SubComponent__r?.BOM_Line__r?.BOM_Header__r?.Product__r?.ProductCode;
            String bomStatus = p.BOM_SubComponent__r?.BOM_Line__r?.BOM_Header__r?.Status__c;
            sp.put('productName', prodName);
            sp.put('productCode', prodCode);
            sp.put('bomStatus', bomStatus);
            spList.add(sp);
            if (prodName != null) affectedProductNames.add(prodName);
            if (prodId != null) affectedProductIds.add(prodId);
        }
        data.put('samePartInOtherProducts', spList);
        data.put('samePartCount', spList.size());
        data.put('affectedProductNames', new List<String>(affectedProductNames));
    }

    // ====== 設計ルート ======
    // 同一製品・同一ProductFamilyの製品を検索
    private static void collectDesignRouteData(
        Corrective_Action__c ca, Map<String, Object> data, Set<Id> affectedProductIds
    ) {
        if (ca.Product__c == null) return;

        // 起点製品のFamilyを取得
        Product2 srcProduct = [
            SELECT Id, Family FROM Product2 WHERE Id = :ca.Product__c LIMIT 1
        ];

        // 同一Familyの他製品
        if (srcProduct.Family != null) {
            List<Product2> familyProducts = [
                SELECT Id, Name, ProductCode, Family, IsActive
                FROM Product2
                WHERE Family = :srcProduct.Family
                AND Id != :ca.Product__c
                AND IsActive = true
                ORDER BY Name
                LIMIT 20
            ];
            List<Map<String, Object>> fpList = new List<Map<String, Object>>();
            for (Product2 p : familyProducts) {
                Map<String, Object> fp = new Map<String, Object>();
                fp.put('productName', p.Name);
                fp.put('productCode', p.ProductCode);
                fp.put('family', p.Family);
                fpList.add(fp);
                affectedProductIds.add(p.Id);
            }
            data.put('sameFamilyProducts', fpList);
        }
    }

    // ====== 製造ルート ======
    // 同一製造拠点の他製品を検索
    private static void collectManufacturingRouteData(
        Corrective_Action__c ca, Map<String, Object> data, Set<Id> affectedProductIds
    ) {
        if (ca.Product__c == null) return;

        // 起点製品のBOMヘッダーから製造拠点を取得
        List<BOM_Header__c> srcBoms = [
            SELECT Assembly_Site__c, Assembly_Site__r.Name
            FROM BOM_Header__c
            WHERE Product__c = :ca.Product__c
            AND Assembly_Site__c != null
            LIMIT 1
        ];
        if (srcBoms.isEmpty()) return;

        Id siteId = srcBoms[0].Assembly_Site__c;
        String siteName = srcBoms[0].Assembly_Site__r.Name;
        data.put('manufacturingSite', siteName);

        // 同一拠点で製造される他製品
        List<BOM_Header__c> sameSiteBoms = [
            SELECT Product__c, Product__r.Name, Product__r.ProductCode, Name, Status__c
            FROM BOM_Header__c
            WHERE Assembly_Site__c = :siteId
            AND Product__c != :ca.Product__c
            AND Product__c != null
            ORDER BY Product__r.Name
            LIMIT 20
        ];
        List<Map<String, Object>> ssList = new List<Map<String, Object>>();
        for (BOM_Header__c bh : sameSiteBoms) {
            Map<String, Object> ss = new Map<String, Object>();
            ss.put('productName', bh.Product__r.Name);
            ss.put('productCode', bh.Product__r.ProductCode);
            ss.put('bomName', bh.Name);
            ss.put('bomStatus', bh.Status__c);
            ssList.add(ss);
            affectedProductIds.add(bh.Product__c);
        }
        data.put('sameSiteProducts', ssList);
    }

    // ====== 関連CA ======
    private static void collectRelatedCAs(
        Corrective_Action__c ca, Id caId, String routeKey, Map<String, Object> data
    ) {
        String q = 'SELECT Name, Title__c, Phase__c, Severity__c, Category__c, '
            + 'Product__r.Name, Supplier__r.Name, CreatedDate, Target_Close_Date__c '
            + 'FROM Corrective_Action__c WHERE Id != :caId';

        Id supplierId = ca.Supplier__c;
        String category = ca.Category__c;

        if (routeKey == 'supplier' && supplierId != null) {
            q += ' AND Supplier__c = :supplierId';
        } else if (routeKey == 'design' || routeKey == 'manufacturing') {
            q += ' AND Category__c = :category';
        } else {
            q += ' AND (Category__c = :category OR Supplier__c = :supplierId)';
        }
        q += ' ORDER BY CreatedDate DESC LIMIT 20';

        List<Corrective_Action__c> relatedCAs = Database.query(q);
        List<Map<String, Object>> rcList = new List<Map<String, Object>>();
        for (Corrective_Action__c rc : relatedCAs) {
            Map<String, Object> rcMap = new Map<String, Object>();
            rcMap.put('name', rc.Name);
            rcMap.put('title', rc.Title__c);
            rcMap.put('phase', rc.Phase__c);
            rcMap.put('severity', rc.Severity__c);
            rcMap.put('category', rc.Category__c);
            rcMap.put('productName', rc.Product__r?.Name);
            rcMap.put('supplierName', rc.Supplier__r?.Name);
            rcMap.put('createdDate', String.valueOf(rc.CreatedDate));
            rcList.add(rcMap);
        }
        data.put('relatedCAs', rcList);
    }

    // ====== 設計プロジェクト ======
    private static void collectDesignProjects(Set<Id> affectedProductIds, Map<String, Object> data) {
        if (affectedProductIds.isEmpty()) return;

        List<Design_Project__c> projects = [
            SELECT Name, Project_Name__c, Status__c,
                   Product__r.Name, Product__r.ProductCode,
                   Base_Product__r.Name, Base_Product__r.ProductCode,
                   Project_Manager__r.Name,
                   Planned_Start__c, Planned_End__c
            FROM Design_Project__c
            WHERE (Base_Product__c IN :affectedProductIds OR Product__c IN :affectedProductIds)
            AND Status__c != '中止'
            ORDER BY CreatedDate DESC
            LIMIT 10
        ];
        List<Map<String, Object>> projList = new List<Map<String, Object>>();
        for (Design_Project__c dp : projects) {
            Map<String, Object> pm = new Map<String, Object>();
            pm.put('name', dp.Name);
            pm.put('projectName', dp.Project_Name__c);
            pm.put('status', dp.Status__c);
            pm.put('newProduct', dp.Product__r?.Name);
            pm.put('newProductCode', dp.Product__r?.ProductCode);
            pm.put('baseProduct', dp.Base_Product__r?.Name);
            pm.put('baseProductCode', dp.Base_Product__r?.ProductCode);
            pm.put('projectManager', dp.Project_Manager__r?.Name);
            pm.put('plannedEnd', String.valueOf(dp.Planned_End__c));
            projList.add(pm);
        }
        data.put('designProjects', projList);
    }

    // ====== 商談 ======
    private static void collectOpportunities(Set<Id> affectedProductIds, Map<String, Object> data) {
        if (affectedProductIds.isEmpty()) return;

        List<OpportunityLineItem> olis = [
            SELECT OpportunityId
            FROM OpportunityLineItem
            WHERE Product2Id IN :affectedProductIds
            AND Opportunity.IsClosed = false
        ];
        Set<Id> oppIds = new Set<Id>();
        for (OpportunityLineItem oli : olis) {
            oppIds.add(oli.OpportunityId);
        }
        if (oppIds.isEmpty()) return;

        List<Opportunity> opps = [
            SELECT Name, StageName, Amount, CloseDate, Account.Name
            FROM Opportunity
            WHERE Id IN :oppIds
            ORDER BY CloseDate ASC
            LIMIT 10
        ];
        List<Map<String, Object>> oppList = new List<Map<String, Object>>();
        for (Opportunity o : opps) {
            Map<String, Object> om = new Map<String, Object>();
            om.put('name', o.Name);
            om.put('stage', o.StageName);
            om.put('amount', o.Amount);
            om.put('closeDate', String.valueOf(o.CloseDate));
            om.put('accountName', o.Account.Name);
            oppList.add(om);
        }
        data.put('openOpportunities', oppList);
    }

    private static String getRouteKey(String category) {
        if (category == null) return 'other';
        if (category == '材料起因' || category == '部品不良' || category == '外注加工') {
            return 'supplier';
        } else if (category == '設計起因') {
            return 'design';
        } else if (category == '製造工程') {
            return 'manufacturing';
        }
        return 'other';
    }

    private static String getRouteLabel(String routeKey) {
        if (routeKey == 'supplier') return 'サプライヤールート';
        if (routeKey == 'design') return '設計ルート';
        if (routeKey == 'manufacturing') return '製造ルート';
        return 'その他';
    }

    private static String callPromptTemplate(String jsonData) {
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsInput input =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            input.isPreview = false;
            input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            input.additionalConfig.applicationName = 'PromptBuilderPreview';
            input.additionalConfig.temperature = 0.2;

            Map<String, ConnectApi.WrappedValue> inputParams =
                new Map<String, ConnectApi.WrappedValue>();
            ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
            wv.value = jsonData;
            inputParams.put('Input:analysisData', wv);
            input.inputParams = inputParams;

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation result =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                    'HorizontalDeploymentReport', input);

            return result.generations[0].text;
        } catch (Exception e) {
            return '【水平展開分析の自動生成中にエラーが発生しました】\n'
                 + 'エラー: ' + e.getMessage() + '\n\n'
                 + '--- 収集した生データ ---\n' + jsonData;
        }
    }
}
