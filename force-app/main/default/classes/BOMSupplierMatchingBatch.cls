public with sharing class BOMSupplierMatchingBatch implements Database.Batchable<SObject>, Database.AllowsCallouts {

    // Product2を起点にして1回だけexecuteを呼ぶ
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Name FROM Product2 WHERE Name LIKE '%EnerGrid%' LIMIT 1
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Product2> products) {
        if (products.isEmpty()) {
            System.debug('対象製品が見つかりません。');
            return;
        }
        Product2 product = products[0];

        try {
            // 1. Data CloudからBOM全データを取得
            List<BomRawRow> allRows = fetchAllBomRows();
            if (allRows.isEmpty()) {
                System.debug('Data CloudにBOMデータが見つかりません。');
                return;
            }

            // 2. LLM名寄せ用テキスト生成（購買部品のみ）
            String bomPartsList = buildBomPartsText(allRows);
            if (String.isBlank(bomPartsList)) {
                System.debug('購買部品が見つかりません。');
                return;
            }

            // 3. Accountマスタを取得
            String accountMasterList = buildAccountMasterText();

            // 4. LLM名寄せ実行
            String llmResponse = BOMSupplierMatchingAction.callMatchingTemplatePublic(accountMasterList, bomPartsList);
            String summary = BOMSupplierMatchingAction.buildSummaryPublic(llmResponse);
            System.debug('名寄せ完了: ' + summary);

            // 5. LLM結果をパース → サプライヤー名→マッチ情報のマップ
            Map<String, MatchInfo> supplierMap = parseMatchingResult(llmResponse);

            // 6. Supplier_Part__c からデフォルト拠点マップを構築
            Map<String, Id> defaultSiteMap = buildDefaultSiteMap();

            // 7. サプライヤー別の拠点マップ（拠点が1つなら自動選択用）
            Map<Id, List<Manufacturing_Site__c>> sitesBySupplier = buildSitesBySupplier();

            // 8. 拠点名→IDマップ（CSV拠点列の名寄せ用）
            Map<String, Id> siteNameMap = buildSiteNameMap();

            // 9. BOMレコード作成 + 新品番のSupplier_Part__c自動登録
            createBomRecords(product, allRows, supplierMap, defaultSiteMap, sitesBySupplier, siteNameMap);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'BOM名寄せバッチエラー: ' + e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('BOMSupplierMatchingBatch 完了');
    }

    // ======================================================================
    // Data Cloud queryv2
    // ======================================================================

    // 新カラムマッピング（2026-03-21 データストリーム再作成後）:
    //   default_10__c  = 品目コード (PK)
    //   default_1__c   = 品名
    //   default_11__c  = 数量 (Number)
    //   default_0__c   = 単位
    //   default_2__c   = 素材/種別
    //   default_8__c   = 工程
    //   default_9__c   = サプライヤー/調達先
    //   KQ_default_10__c = 製造拠点（新列）
    //   default_3__c   = 内外区分
    //   default_4__c   = 単価
    //   default_6__c   = 備考
    //   default_7__c   = 階層 (Number)

    private List<BomRawRow> fetchAllBomRows() {
        String sql = 'SELECT default_7__c, default_10__c, default_1__c, default_11__c, default_0__c, '
            + 'default_2__c, default_8__c, default_9__c, KQ_default_10__c, default_3__c, default_4__c, default_6__c '
            + 'FROM csv_BOM_S3__dlm LIMIT 200';

        List<Object> data = queryDataCloud(sql);
        if (data == null) return new List<BomRawRow>();

        List<BomRawRow> rows = new List<BomRawRow>();
        for (Object row : data) {
            List<Object> cols = (List<Object>) row;
            BomRawRow r = new BomRawRow();
            r.bomLevel   = safeStr(cols, 0);   // default_7__c
            r.partCode   = safeStr(cols, 1);   // default_10__c
            r.partName   = safeStr(cols, 2);   // default_1__c
            r.quantity   = safeStr(cols, 3);   // default_11__c
            r.unit       = safeStr(cols, 4);   // default_0__c
            r.material   = safeStr(cols, 5);   // default_2__c
            r.process    = safeStr(cols, 6);   // default_8__c
            r.supplier   = safeStr(cols, 7);   // default_9__c
            r.siteName   = safeStr(cols, 8);   // KQ_default_10__c（製造拠点）
            r.makeOrBuy  = safeStr(cols, 9);   // default_3__c
            r.unitPrice  = safeStr(cols, 10);  // default_4__c
            r.remarks    = safeStr(cols, 11);  // default_6__c
            rows.add(r);
        }
        return rows;
    }

    // LLM入力用テキスト生成（購買部品のみ）
    private String buildBomPartsText(List<BomRawRow> allRows) {
        String result = '';
        Integer rowNum = 0;
        for (BomRawRow row : allRows) {
            if (row.makeOrBuy != '購買' || String.isBlank(row.supplier)) continue;
            rowNum++;
            result += rowNum + '. 品目コード: ' + row.partCode + ' / 品名: ' + row.partName + ' / サプライヤー: ' + row.supplier;
            if (String.isNotBlank(row.remarks)) result += ' / 備考: ' + row.remarks;
            result += '\n';
        }
        return String.isBlank(result) ? null : result;
    }

    // ======================================================================
    // LLM名寄せ結果パース
    // ======================================================================

    private Map<String, MatchInfo> parseMatchingResult(String llmResponse) {
        Map<String, MatchInfo> result = new Map<String, MatchInfo>();
        String jsonStr = extractJson(llmResponse);
        if (jsonStr == null) return result;

        List<Object> items = (List<Object>) JSON.deserializeUntyped(jsonStr);
        for (Object item : items) {
            Map<String, Object> m = (Map<String, Object>) item;
            String confidence = (String) m.get('confidence');
            String accountId = (String) m.get('matched_account_id');
            String supplierName = (String) m.get('bom_supplier_name');

            MatchInfo info = new MatchInfo();
            info.confidence = confidence;
            if (confidence == 'High' && String.isNotBlank(accountId)) {
                info.accountId = Id.valueOf(accountId);
            }
            result.put(supplierName, info);
        }
        return result;
    }

    // ======================================================================
    // 拠点解決
    // ======================================================================

    // Supplier_Part__c からデフォルト拠点マップを構築
    // キー: AccountId + '-' + Part_Number__c → 値: Default_Site__c
    private Map<String, Id> buildDefaultSiteMap() {
        Map<String, Id> result = new Map<String, Id>();
        for (Supplier_Part__c sp : [
            SELECT Supplier__c, Part_Number__c, Default_Site__c
            FROM Supplier_Part__c
            WHERE Default_Site__c != null
        ]) {
            result.put(sp.Supplier__c + '-' + sp.Part_Number__c, sp.Default_Site__c);
        }
        return result;
    }

    // サプライヤー別の拠点一覧（拠点が1つなら自動選択）
    private Map<Id, List<Manufacturing_Site__c>> buildSitesBySupplier() {
        Map<Id, List<Manufacturing_Site__c>> result = new Map<Id, List<Manufacturing_Site__c>>();
        for (Manufacturing_Site__c site : [
            SELECT Id, Name, Supplier__c FROM Manufacturing_Site__c WHERE Supplier__c != null
        ]) {
            if (!result.containsKey(site.Supplier__c)) {
                result.put(site.Supplier__c, new List<Manufacturing_Site__c>());
            }
            result.get(site.Supplier__c).add(site);
        }
        return result;
    }

    // Manufacturing_Site__c の名前→IDマップ（CSV拠点列の名寄せ用）
    private Map<String, Id> buildSiteNameMap() {
        Map<String, Id> result = new Map<String, Id>();
        for (Manufacturing_Site__c site : [
            SELECT Id, Name FROM Manufacturing_Site__c
        ]) {
            result.put(site.Name, site.Id);
            // 部分一致用: 「浜松工場」→ フルネームが「富士精密機械 浜松工場」でもマッチするように
            // 短縮名もキーに追加
            if (site.Name.contains(' ')) {
                result.put(site.Name.substringAfter(' '), site.Id);
            }
        }
        return result;
    }

    // 拠点を解決: CSV拠点列 → 名前マッチ、なければ Supplier_Part__c デフォルト
    private Id resolveSite(BomRawRow row, Id supplierId, Map<String, Id> defaultSiteMap, Map<String, Id> siteNameMap) {
        // 1. CSV拠点列に値がある場合 → 名前でManufacturing_Site__cを解決
        if (String.isNotBlank(row.siteName)) {
            if (siteNameMap.containsKey(row.siteName)) {
                return siteNameMap.get(row.siteName);
            }
            // 部分一致を試行
            for (String key : siteNameMap.keySet()) {
                if (key.contains(row.siteName) || row.siteName.contains(key)) {
                    return siteNameMap.get(key);
                }
            }
        }

        // 2. CSV拠点列が空 → Supplier_Part__cのデフォルト拠点
        if (supplierId != null && String.isNotBlank(row.partCode)) {
            String key = supplierId + '-' + row.partCode;
            if (defaultSiteMap.containsKey(key)) {
                return defaultSiteMap.get(key);
            }
        }

        return null;
    }

    // ======================================================================
    // BOMオブジェクト書き込み
    // ======================================================================

    private void createBomRecords(Product2 product, List<BomRawRow> allRows,
            Map<String, MatchInfo> supplierMap, Map<String, Id> defaultSiteMap,
            Map<Id, List<Manufacturing_Site__c>> sitesBySupplier, Map<String, Id> siteNameMap) {

        // 1. BOM_Header__c 作成
        BOM_Header__c header = new BOM_Header__c();
        header.Product__c = product.Id;
        header.BOM_Number__c = 'BOM-EG3000-MFG';
        header.Status__c = '設計中';
        header.Description__c = 'S3 CSV → Data Cloud → LLM名寄せにより自動生成';
        insert header;

        // 2. BOM_Line__c 作成（階層1のAssembly行）
        Map<String, BOM_Line__c> lineMap = new Map<String, BOM_Line__c>();
        Integer lineNum = 0;
        for (BomRawRow row : allRows) {
            if (parseBomLevel(row.bomLevel) == 1 && String.isNotBlank(row.partCode)) {
                lineNum++;
                BOM_Line__c line = new BOM_Line__c();
                line.BOM_Header__c = header.Id;
                line.Line_Number__c = lineNum;
                line.Quantity__c = parseDouble(row.quantity);
                line.Unit_of_Measure__c = row.unit;
                line.Notes__c = row.partName;
                lineMap.put(row.partCode, line);
            }
        }
        if (!lineMap.isEmpty()) {
            insert lineMap.values();
        }

        // 3. BOM_SubComponent__c 作成（Line毎に1件の仮コンポーネント）
        Map<String, BOM_SubComponent__c> subCompMap = new Map<String, BOM_SubComponent__c>();
        for (String linePartCode : lineMap.keySet()) {
            BOM_Line__c line = lineMap.get(linePartCode);
            BOM_SubComponent__c sub = new BOM_SubComponent__c();
            sub.BOM_Line__c = line.Id;
            sub.Component_Name__c = line.Notes__c;
            sub.Quantity__c = 1;
            sub.Sequence__c = 1;
            subCompMap.put(linePartCode, sub);
        }
        if (!subCompMap.isEmpty()) {
            insert subCompMap.values();
        }

        // 4. 購買部品をどのAssembly配下かマッピング
        //    Data Cloud queryv2は行順序を保証しないため、品目コードのプレフィックスで判定
        //    BAT-xxx → EG-ASY-100, PCS-xxx → EG-ASY-200, BEMS-xxx → EG-ASY-300,
        //    ENC-xxx → EG-ASY-400, CBL-xxx → EG-ASY-500
        Map<String, String> prefixToAssembly = new Map<String, String>();
        for (BomRawRow row : allRows) {
            if (parseBomLevel(row.bomLevel) == 1 && String.isNotBlank(row.partCode)) {
                // Assembly行自体は lineMap に入っているはず
            }
        }
        // まずCSV並び順で親子関係を構築するために、階層でソート
        List<BomRawRow> sortedRows = new List<BomRawRow>();
        // 階層0を先頭に、階層1をその次に、階層2をその後に
        for (BomRawRow row : allRows) {
            if (parseBomLevel(row.bomLevel) == 0) sortedRows.add(row);
        }
        for (BomRawRow row : allRows) {
            if (parseBomLevel(row.bomLevel) == 1) sortedRows.add(row);
        }
        for (BomRawRow row : allRows) {
            if (parseBomLevel(row.bomLevel) == 2) sortedRows.add(row);
        }

        // 品目コードプレフィックスから所属Assemblyを推定
        // 各Assemblyの品目コードプレフィックスを収集
        Map<String, String> partToAssembly = new Map<String, String>();
        for (BomRawRow row : allRows) {
            if (parseBomLevel(row.bomLevel) == 2 && String.isNotBlank(row.partCode)) {
                // 全Assemblyに対して、品目コードの先頭3文字で最も近いものを探す
                String bestAssembly = findAssemblyForPart(row.partCode, lineMap.keySet());
                if (bestAssembly != null) {
                    partToAssembly.put(row.partCode, bestAssembly);
                }
            }
        }

        // 5. BOM_Part__c 作成（購買部品のみ）+ Supplier_Part__c 自動登録
        List<BOM_Part__c> parts = new List<BOM_Part__c>();
        List<Supplier_Part__c> newSupplierParts = new List<Supplier_Part__c>();
        Set<String> existingSpKeys = new Set<String>(defaultSiteMap.keySet());

        for (BomRawRow row : allRows) {
            if (row.makeOrBuy != '購買' || String.isBlank(row.partCode)) continue;

            String assemblyCode = partToAssembly.get(row.partCode);
            if (assemblyCode == null || !subCompMap.containsKey(assemblyCode)) continue;

            BOM_Part__c part = new BOM_Part__c();
            part.BOM_SubComponent__c = subCompMap.get(assemblyCode).Id;
            part.Part_Number__c = row.partCode;
            part.Part_Name__c = row.partName;
            part.Quantity__c = parseDouble(row.quantity);
            part.Unit_of_Measure__c = row.unit;
            part.Unit_Cost__c = parseDecimal(row.unitPrice);
            part.Make_or_Buy__c = row.makeOrBuy;
            part.Notes__c = row.remarks;

            // サプライヤー名寄せ結果の紐付け＋信頼度
            Id supplierId = null;
            if (String.isNotBlank(row.supplier) && supplierMap.containsKey(row.supplier)) {
                MatchInfo info = supplierMap.get(row.supplier);
                part.Supplier__c = info.accountId;
                part.Matching_Confidence__c = info.confidence;
                supplierId = info.accountId;
            }

            // 製造拠点の解決
            Id siteId = resolveSite(row, supplierId, defaultSiteMap, siteNameMap);

            // デフォルト拠点が見つからず、サプライヤーが確定している場合
            // → サプライヤーの最初の拠点を仮設定、新品番をSupplier_Part__cに登録
            if (siteId == null && supplierId != null) {
                if (sitesBySupplier.containsKey(supplierId)) {
                    List<Manufacturing_Site__c> sites = sitesBySupplier.get(supplierId);
                    siteId = sites[0].Id; // 最初の拠点を仮設定
                }

                // Supplier_Part__c に未登録なら新規作成
                String spKey = supplierId + '-' + row.partCode;
                if (!existingSpKeys.contains(spKey)) {
                    Supplier_Part__c sp = new Supplier_Part__c();
                    sp.Supplier__c = supplierId;
                    sp.Part_Number__c = row.partCode;
                    sp.Part_Name__c = row.partName;
                    sp.Default_Site__c = siteId;
                    newSupplierParts.add(sp);
                    existingSpKeys.add(spKey);
                }
            }

            part.Manufacturing_Site__c = siteId;
            parts.add(part);
        }

        if (!newSupplierParts.isEmpty()) {
            insert newSupplierParts;
            System.debug('Supplier_Part__c 新規登録: ' + newSupplierParts.size() + '件');
        }

        if (!parts.isEmpty()) {
            insert parts;
        }

        Integer linkedCount = 0;
        Integer siteCount = 0;
        for (BOM_Part__c p : parts) {
            if (p.Supplier__c != null) linkedCount++;
            if (p.Manufacturing_Site__c != null) siteCount++;
        }
        System.debug('BOMレコード作成完了: Header=1, Line=' + lineMap.size()
            + ', SubComponent=' + subCompMap.size()
            + ', Part=' + parts.size()
            + ' (サプライヤー紐付き=' + linkedCount + ', 拠点紐付き=' + siteCount + ')');
    }

    // ======================================================================
    // ユーティリティ
    // ======================================================================

    private List<Object> queryDataCloud(String sql) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(Url.getOrgDomainUrl().toExternalForm() + '/services/data/v62.0/ssot/queryv2');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setHeader('Content-Type', 'application/json');
        req.setBody('{"sql":"' + sql + '"}');

        Http http = new Http();
        HttpResponse res = http.send(req);
        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            System.debug('Data Cloud queryv2 エラー: ' + res.getStatusCode());
            return null;
        }

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> data = (List<Object>) parsed.get('data');
        return (data != null && !data.isEmpty()) ? data : null;
    }

    private String safeStr(List<Object> cols, Integer idx) {
        if (cols == null || idx >= cols.size() || cols[idx] == null) return '';
        return String.valueOf(cols[idx]).trim();
    }

    // 品目コードプレフィックスからAssemblyを推定
    // BAT-xxx → EG-ASY-100（蓄電池）, PCS-xxx → EG-ASY-200（PCS）,
    // BEMS-xxx → EG-ASY-300（BEMS）, ENC-xxx → EG-ASY-400（筐体）, CBL-xxx → EG-ASY-500（配線）
    private static final Map<String, String> PREFIX_ASSEMBLY_MAP = new Map<String, String>{
        'BAT' => 'EG-ASY-100',
        'PCS' => 'EG-ASY-200',
        'BEMS' => 'EG-ASY-300',
        'ENC' => 'EG-ASY-400',
        'CBL' => 'EG-ASY-500'
    };

    private String findAssemblyForPart(String partCode, Set<String> assemblyKeys) {
        // プレフィックスマップから探す
        for (String prefix : PREFIX_ASSEMBLY_MAP.keySet()) {
            if (partCode.startsWith(prefix)) {
                String assy = PREFIX_ASSEMBLY_MAP.get(prefix);
                if (assemblyKeys.contains(assy)) {
                    return assy;
                }
            }
        }
        // マッチしない場合は最初のAssemblyにフォールバック
        for (String key : assemblyKeys) {
            return key;
        }
        return null;
    }

    private Integer parseBomLevel(String val) {
        if (String.isBlank(val)) return -1;
        try { return Integer.valueOf(Decimal.valueOf(val).intValue()); } catch (Exception e) { return -1; }
    }

    private Double parseDouble(String val) {
        if (String.isBlank(val)) return null;
        try { return Double.valueOf(val); } catch (Exception e) { return null; }
    }

    private Decimal parseDecimal(String val) {
        if (String.isBlank(val)) return null;
        try { return Decimal.valueOf(val); } catch (Exception e) { return null; }
    }

    private String extractJson(String response) {
        if (response == null) return null;
        Integer jsonStart = response.indexOf('```json');
        if (jsonStart >= 0) {
            jsonStart = response.indexOf('\n', jsonStart) + 1;
            Integer jsonEnd = response.indexOf('```', jsonStart);
            if (jsonEnd > jsonStart) return response.substring(jsonStart, jsonEnd).trim();
        }
        Integer bracketStart = response.indexOf('[');
        Integer bracketEnd = response.lastIndexOf(']');
        if (bracketStart >= 0 && bracketEnd > bracketStart) {
            return response.substring(bracketStart, bracketEnd + 1);
        }
        return null;
    }

    private String buildAccountMasterText() {
        List<Account> accounts = [SELECT Id, Name FROM Account WHERE Name != null ORDER BY Name];
        String text = '';
        for (Account a : accounts) {
            text += a.Id + ' | ' + a.Name + '\n';
        }
        return text;
    }

    // ======================================================================
    // 内部クラス
    // ======================================================================

    private class MatchInfo {
        Id accountId;
        String confidence;
    }

    private class BomRawRow {
        String bomLevel;
        String partCode;
        String partName;
        String quantity;
        String unit;
        String material;
        String process;
        String supplier;
        String siteName;   // 製造拠点（CSV新列）
        String makeOrBuy;
        String unitPrice;
        String remarks;
    }
}
