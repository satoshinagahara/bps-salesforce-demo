public with sharing class BOMSupplierMatchingAction {

    @InvocableMethod(label='BOMサプライヤー名寄せ' description='BOM CSVのサプライヤー名をAccountマスタとLLMで名寄せする')
    public static List<MatchingResult> matchSuppliers(List<MatchingInput> inputs) {
        List<MatchingResult> results = new List<MatchingResult>();
        for (MatchingInput input : inputs) {
            results.add(processMatching(input.bomCsvData));
        }
        return results;
    }

    public class MatchingInput {
        @InvocableVariable(label='BOM CSVデータ' description='CSV形式のBOMデータ（ヘッダー付き）')
        public String bomCsvData;
    }

    public class MatchingResult {
        @InvocableVariable(label='結果メッセージ')
        public String resultMessage;
        @InvocableVariable(label='マッチング結果JSON')
        public String matchingResultJson;
        @InvocableVariable(label='サマリー')
        public String summary;
        @InvocableVariable(label='エラー')
        public String errorMessage;
    }

    // AuraEnabled for LWC or Anonymous Apex testing
    @AuraEnabled
    public static MatchingResult runMatchingFromCsv(String bomCsvData) {
        return processMatching(bomCsvData);
    }

    // Anonymous Apex用: サンプルBOMで実行
    public static MatchingResult runSampleMatching() {
        String bomCsv = buildSampleBomData();
        return processMatching(bomCsv);
    }

    private static MatchingResult processMatching(String bomCsvData) {
        MatchingResult result = new MatchingResult();

        try {
            // 1. Accountマスタを取得
            String accountMasterList = buildAccountMasterText();

            // 2. BOM CSVから購買部品行を抽出・整形
            String bomPartsList = parseBomCsvToPartsText(bomCsvData);

            if (String.isBlank(bomPartsList)) {
                result.resultMessage = '購買部品が見つかりませんでした。';
                return result;
            }

            // 3. Prompt Template呼び出し（LLM名寄せ）
            String llmResponse = callMatchingTemplate(accountMasterList, bomPartsList);

            // 4. 結果を整形
            result.matchingResultJson = llmResponse;
            result.summary = buildSummary(llmResponse);
            result.resultMessage = '名寄せ完了。' + result.summary;

        } catch (Exception e) {
            result.errorMessage = e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString();
        }
        return result;
    }

    // === Accountマスタをテキスト化 ===
    private static String buildAccountMasterText() {
        List<Account> accounts = [
            SELECT Id, Name, Type
            FROM Account
            WHERE Name != null
            ORDER BY Name
        ];

        String text = '';
        for (Account a : accounts) {
            text += a.Id + ' | ' + a.Name + '\n';
        }
        return text;
    }

    // === BOM CSVを購買部品リストに変換 ===
    private static String parseBomCsvToPartsText(String csvData) {
        List<String> lines = csvData.split('\n');
        if (lines.isEmpty()) return null;

        String result = '';
        Integer rowNum = 0;

        for (Integer i = 1; i < lines.size(); i++) {
            String line = lines[i].trim();
            if (String.isBlank(line)) continue;

            List<String> cols = parseCsvLine(line);
            if (cols.size() < 9) continue;

            String internalExternal = cols.size() > 8 ? cols[8].trim() : '';
            String supplierName = cols.size() > 7 ? cols[7].trim() : '';
            String partName = cols.size() > 2 ? cols[2].trim() : '';
            String partCode = cols.size() > 1 ? cols[1].trim() : '';
            String remarks = cols.size() > 10 ? cols[10].trim() : '';

            // 購買品のみ抽出（内製・工程費等は除外）
            if (internalExternal != '購買' || String.isBlank(supplierName)) continue;

            rowNum++;
            result += rowNum + '. 品目コード: ' + partCode
                + ' / 品名: ' + partName
                + ' / サプライヤー: ' + supplierName;
            if (String.isNotBlank(remarks)) {
                result += ' / 備考: ' + remarks;
            }
            result += '\n';
        }
        return String.isBlank(result) ? null : result;
    }

    // === CSV行のパース（カンマ区切り、簡易版） ===
    private static List<String> parseCsvLine(String line) {
        List<String> fields = new List<String>();
        String current = '';
        Boolean inQuotes = false;

        for (Integer i = 0; i < line.length(); i++) {
            String ch = line.substring(i, i + 1);
            if (ch == '"') {
                inQuotes = !inQuotes;
            } else if (ch == ',' && !inQuotes) {
                fields.add(current);
                current = '';
            } else {
                current += ch;
            }
        }
        fields.add(current);
        return fields;
    }

    // === Prompt Template呼び出し（Batch等の外部クラスからも利用可能） ===
    public static String callMatchingTemplatePublic(String accountMasterList, String bomPartsList) {
        return callMatchingTemplate(accountMasterList, bomPartsList);
    }

    // === 結果サマリー生成（外部クラスからも利用可能） ===
    public static String buildSummaryPublic(String llmResponse) {
        return buildSummary(llmResponse);
    }

    private static String callMatchingTemplate(String accountMasterList, String bomPartsList) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;

        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();

        ConnectApi.WrappedValue wvAccounts = new ConnectApi.WrappedValue();
        wvAccounts.value = accountMasterList;
        inputParams.put('Input:accountMasterList', wvAccounts);

        ConnectApi.WrappedValue wvBom = new ConnectApi.WrappedValue();
        wvBom.value = bomPartsList;
        inputParams.put('Input:bomPartsList', wvBom);

        input.inputParams = inputParams;

        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptBuilderPreview';
        input.additionalConfig.temperature = 0.1;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                'BOMSupplierMatching', input
            );

        if (response.generations == null || response.generations.isEmpty()) {
            throw new BOMMatchingException('Prompt Templateからの応答が空です。');
        }

        return ((ConnectApi.EinsteinLLMGenerationItemOutput) response.generations[0]).text;
    }

    // === 結果サマリー生成 ===
    private static String buildSummary(String llmResponse) {
        try {
            String jsonStr = extractJsonFromResponse(llmResponse);
            if (jsonStr == null) return 'JSONパース失敗';

            List<Object> items = (List<Object>) JSON.deserializeUntyped(jsonStr);
            Integer high = 0, mid = 0, low = 0;

            for (Object item : items) {
                Map<String, Object> m = (Map<String, Object>) item;
                String conf = (String) m.get('confidence');
                if (conf == 'High') high++;
                else if (conf == 'Mid') mid++;
                else low++;
            }

            return '合計' + items.size() + '件: High=' + high + ', Mid=' + mid + ', Low=' + low;
        } catch (Exception e) {
            return 'サマリー生成エラー: ' + e.getMessage();
        }
    }

    private static String extractJsonFromResponse(String response) {
        if (response == null) return null;
        Integer jsonStart = response.indexOf('```json');
        if (jsonStart >= 0) {
            jsonStart = response.indexOf('\n', jsonStart) + 1;
            Integer jsonEnd = response.indexOf('```', jsonStart);
            if (jsonEnd > jsonStart) {
                return response.substring(jsonStart, jsonEnd).trim();
            }
        }
        Integer bracketStart = response.indexOf('[');
        Integer bracketEnd = response.lastIndexOf(']');
        if (bracketStart >= 0 && bracketEnd > bracketStart) {
            return response.substring(bracketStart, bracketEnd + 1);
        }
        return null;
    }

    // === サンプルBOMデータ（Anonymous Apex用） ===
    private static String buildSampleBomData() {
        return '階層,品目コード,品名,数量,単位,素材/種別,工程,サプライヤー/調達先,内外区分,単価,備考\n'
            + '2,BAT-CELL-01,角形リチウムイオンセル 3.7V 50Ah,96,個,電子部品,セル実装,㈱グリーンエナジーセル,購買,4500,NCM811タイプ。代替: CATLセル\n'
            + '2,BAT-BMS-01,バッテリーマネジメントシステム基板,1,個,電子部品,実装,東亜電子,購買,85000,16セル対応BMS。受注後10週\n'
            + '2,BAT-BUS-01,銅バスバー（セル接続用）,48,個,銅,加工,日本マテリアル,購買,350,公差±0.1mm。ニッケルメッキ\n'
            + '2,BAT-HSK-01,アルミ放熱プレート,4,個,アルミ,切削加工,日本マテリアルズ,購買,8500,A5052 t3.0 熱伝導シート貼付済\n'
            + '2,BAT-THS-01,サーミスタ温度センサー NTC 10K,16,個,電子部品,,テクノコネクト㈱,購買,120,精度±1%\n'
            + '2,BAT-FAN-01,DCファン 80mm 24V,4,個,電子部品,,富士精密,購買,980,PWM制御対応。IP54\n'
            + '2,PCS-INV-01,3相インバーターモジュール 50kW,1,個,電子部品,実装,東亜電子工業株式会社,購買,320000,SiC MOSFET採用。効率98.5%\n'
            + '2,PCS-TRF-01,絶縁トランス 50kVA,1,個,金属,組立,アライドパワー（株）,購買,145000,R相・S相・T相。騒音40dB以下\n'
            + '2,PCS-FLT-01,ACフィルター基板,1,個,電子部品,実装,テクノコネクト,購買,28000,THD 3%以下\n'
            + '2,PCS-GRD-01,系統連系保護リレー,1,個,電子部品,,toa-denshi,購買,65000,FRT対応。JET認証取得品（備考：東亜電子さんに発注）\n'
            + '2,PCS-DSP-01,DSP制御基板 (TMS320F28379D),1,個,電子部品,実装,東亜電子工業,購買,42000,MPPT + 系統連系制御\n'
            + '2,PCS-CT-01,CT（電流センサー）200A,3,個,電子部品,,テクノコネクト,購買,3800,\n'
            + '2,PCS-FAN-01,軸流ファン 120mm,2,個,,冷却,Fuji Seimitsu Co.,購買,2200,60dB以下\n'
            + '2,PCS-HSK-02,ヒートシンク（PCS用）,2,個,アルミ,切削,Nihon Materials,購買,12000,フィン高さ40mm\n'
            + '2,BEMS-GW-01,IoTゲートウェイ (ARM Cortex-A53),1,個,電子部品,実装,テクノコネクト,購買,35000,Ethernet + Wi-Fi + RS-485\n'
            + '2,BEMS-LCD-01,7インチタッチパネルLCD,1,個,電子部品,,サンライズ・ディスプレイ,購買,18000,IPS液晶 解像度1024x600\n'
            + '2,BEMS-ANT-01,4G/LTEアンテナモジュール,1,個,電子部品,,テクノコネクト,購買,4500,\n'
            + '2,BEMS-SIM-01,通信SIMカード (IoT用),1,個,,,通信キャリア直接契約,購買,0,月額費用は別途。BOMには含めない考え方もある\n'
            + '2,BEMS-SD-01,産業用SDカード 32GB,1,個,電子部品,,アキバ電子パーツ,購買,2800,SLC NAND。-40〜+85℃対応\n'
            + '2,ENC-FRM-01,19インチサーバーラック 42U,1,個,鉄鋼,板金,Allied Power,購買,125000,W600×D1000×H2000。粉体塗装\n'
            + '2,ENC-DOR-01,前面ドアパネル（メッシュ）,1,個,鉄鋼,板金加工,アライドパワー,購買,18000,通気率65%\n'
            + '2,ENC-DOR-02,背面ドアパネル（メッシュ）,1,個,鉄鋼,板金,アライド・パワー株式会社,購買,18000,\n'
            + '2,ENC-ACU-01,精密空調ユニット 3.5kW,1,個,,冷却,空調メーカーA,購買,280000,インバーター制御。R32冷媒（サプライヤー未定、暫定でA社見積）\n'
            + '2,ENC-PDU-01,インテリジェントPDU 32A,2,個,電子部品,,テクノコネクト,購買,45000,遠隔電源制御・電力モニタリング\n'
            + '2,ENC-SPD-01,SPD（サージ保護デバイス）,1,個,電子部品,,Green Energy Cell,購買,8500,クラスII T2\n'
            + '2,ENC-GND-01,接地バー・接地端子台,1,式,銅,,日本マテリアルズ,購買,3500,\n'
            + '2,CBL-CTL-01,制御ケーブル VCTF 1.25sq×4C,30,m,,配線,アライドパワー株式会社,購買,380,\n'
            + '2,CBL-CON-01,圧着端子・コネクタセット,1,式,,圧着,FUJI SEIMITSU,購買,8500,丸端子・Y端子・フェルール各種\n'
            + '2,CBL-TRC-01,ケーブルトレー・ダクト,1,式,鉄鋼,,日本マテリアルズ,購買,12000,\n';
    }

    public class BOMMatchingException extends Exception {}
}
