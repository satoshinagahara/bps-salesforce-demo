/**
 * IdpSupplierQuoteController
 * IDPサプライヤー見積書取り込みLWC用Apexコントローラ
 *
 * - S3 Presigned URL取得(API Gateway経由)
 * - Lambda抽出キック(API Gateway経由)
 * - Prompt Template経由での相違判定
 * - RFQ_Quote__c レコード管理
 *
 * Remote Site Settings: https://vdydb45kz5.execute-api.ap-northeast-1.amazonaws.com
 */
public with sharing class IdpSupplierQuoteController {

    private static final String API_GATEWAY_BASE = 'https://vdydb45kz5.execute-api.ap-northeast-1.amazonaws.com/prod';
    private static final String PRESIGN_ENDPOINT = API_GATEWAY_BASE + '/idp/presign';
    private static final String EXTRACT_ENDPOINT = API_GATEWAY_BASE + '/idp/extract';

    private static final String PROMPT_TEMPLATE_NAME = 'IDP_Supplier_Quote_Judge';

    // ============================================================
    // 1. Presigned URL取得
    // ============================================================

    @AuraEnabled
    public static Map<String, String> getPresignedUrl(String fileName, String contentType) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(PRESIGN_ENDPOINT);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(30000);
            req.setBody(JSON.serialize(new Map<String, String>{
                'file_name' => fileName,
                'content_type' => contentType
            }));

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                throw new AuraHandledException(
                    'Presigned URL の取得に失敗しました (HTTP ' + res.getStatusCode() + '): ' + res.getBody()
                );
            }

            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            return new Map<String, String>{
                'presignedUrl' => (String) body.get('presigned_url'),
                'bucket' => (String) body.get('bucket'),
                's3Key' => (String) body.get('s3_key')
            };
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Presigned URL取得中にエラー: ' + e.getMessage());
        }
    }

    // ============================================================
    // 2. IDP処理開始準備(DML)
    // ============================================================

    @AuraEnabled
    public static void initializeIdpRecord(String rfqQuoteId, String bucket, String s3Key, String fileName) {
        try {
            // IDP抽出中の派生状態(Document_URLあり+Extracted_Atなし)で表現するためステータスは変更しない
            RFQ_Quote__c q = new RFQ_Quote__c(
                Id = rfqQuoteId,
                IDP_Document_URL__c = 's3://' + bucket + '/' + s3Key,
                IDP_Extracted_At__c = null,
                IDP_Error_Message__c = null
            );
            update q;
        } catch (Exception e) {
            throw new AuraHandledException('IDP初期化に失敗しました: ' + e.getMessage());
        }
    }

    // ============================================================
    // 3. 抽出Lambdaキック(callout)
    // ============================================================

    @AuraEnabled
    public static void startExtraction(String rfqQuoteId, String bucket, String s3Key) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(EXTRACT_ENDPOINT);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(30000);
            req.setBody(JSON.serialize(new Map<String, String>{
                'bucket' => bucket,
                'key' => s3Key,
                'rfq_quote_id' => rfqQuoteId
            }));

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200 && res.getStatusCode() != 202) {
                throw new AuraHandledException(
                    '抽出処理の開始に失敗しました (HTTP ' + res.getStatusCode() + '): ' + res.getBody()
                );
            }
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('抽出処理の開始中にエラー: ' + e.getMessage());
        }
    }

    // ============================================================
    // 4. ステータス取得(ポーリング用)
    // ============================================================

    @AuraEnabled(cacheable=true)
    public static RFQ_Quote__c getIdpStatus(String rfqQuoteId) {
        List<RFQ_Quote__c> records = [
            SELECT Id, IDP_Review_Status__c, IDP_Extracted_At__c, IDP_Judged_At__c, IDP_Confirmed_At__c,
                   IDP_Overall_Discrepancy_Level__c, IDP_Error_Message__c
            FROM RFQ_Quote__c
            WHERE Id = :rfqQuoteId
            LIMIT 1
        ];
        if (records.isEmpty()) {
            throw new AuraHandledException('レコードが見つかりません: ' + rfqQuoteId);
        }
        return records[0];
    }

    /**
     * LWC比較テーブル描画用の全フィールド取得(ルックアップ名含む)
     */
    @AuraEnabled(cacheable=true)
    public static RFQ_Quote__c getFullRecord(String rfqQuoteId) {
        List<RFQ_Quote__c> records = [
            SELECT Id,
                   Supplier__c, Supplier__r.Name,
                   Unit_Price__c, Lead_Time_Days__c, MOQ__c,
                   Manufacturing_Site__c, Manufacturing_Site__r.Name,
                   Valid_Until__c, Response_Date__c,
                   AI_Supplier_Text__c, AI_Supplier_Confidence__c,
                   AI_Unit_Price__c, AI_Unit_Price_Confidence__c,
                   AI_Lead_Time_Days__c, AI_Lead_Time_Days_Confidence__c,
                   AI_MOQ__c, AI_MOQ_Confidence__c,
                   AI_Manufacturing_Site__c, AI_Manufacturing_Site_Confidence__c,
                   AI_Valid_Until__c, AI_Valid_Until_Confidence__c,
                   AI_Response_Date__c, AI_Response_Date_Confidence__c,
                   Supplier_Discrepancy_Level__c, Supplier_Discrepancy_Reason__c,
                   Unit_Price_Discrepancy_Level__c, Unit_Price_Discrepancy_Reason__c,
                   Lead_Time_Days_Discrepancy_Level__c, Lead_Time_Days_Discrepancy_Reason__c,
                   MOQ_Discrepancy_Level__c, MOQ_Discrepancy_Reason__c,
                   Manufacturing_Site_Discrepancy_Level__c, Manufacturing_Site_Discrepancy_Reason__c,
                   Valid_Until_Discrepancy_Level__c, Valid_Until_Discrepancy_Reason__c,
                   Response_Date_Discrepancy_Level__c, Response_Date_Discrepancy_Reason__c,
                   IDP_Document_URL__c, IDP_Review_Status__c,
                   IDP_Extracted_At__c, IDP_Judged_At__c, IDP_Confirmed_At__c,
                   IDP_Overall_Discrepancy_Level__c, IDP_Judgment_Summary__c,
                   IDP_Review_Note__c, IDP_Error_Message__c
            FROM RFQ_Quote__c
            WHERE Id = :rfqQuoteId
            LIMIT 1
        ];
        if (records.isEmpty()) {
            throw new AuraHandledException('レコードが見つかりません: ' + rfqQuoteId);
        }
        return records[0];
    }

    // ============================================================
    // 5. 相違判定(Prompt Template呼び出し + DML更新)
    // ============================================================

    @AuraEnabled
    public static void startJudgment(String rfqQuoteId) {
        // 判定中はLWC側のローカルスピナーで表現、ステータスはAI判定待ちのまま
        update new RFQ_Quote__c(Id = rfqQuoteId, IDP_Error_Message__c = null);

        try {
            // レコード取得(人間値+AI値+ルックアップName)
            RFQ_Quote__c q = queryForJudgment(rfqQuoteId);

            // Prompt Template向けの比較JSON構築
            String analysisJson = buildAnalysisJson(q);

            // Prompt Template呼び出し
            String response = callPromptTemplate(analysisJson);

            // JSONパース
            Map<String, Object> judged = (Map<String, Object>) JSON.deserializeUntyped(stripCodeFences(response));

            // 結果をレコードに書き戻し
            applyJudgmentResult(rfqQuoteId, judged);

        } catch (Exception e) {
            // エラー時: ステータスは変更せずエラーメッセージのみ記録(LWC側でバナー表示)
            update new RFQ_Quote__c(
                Id = rfqQuoteId,
                IDP_Error_Message__c = ('判定エラー: ' + e.getMessage()).left(255)
            );
            throw new AuraHandledException('相違判定に失敗しました: ' + e.getMessage());
        }
    }

    private static RFQ_Quote__c queryForJudgment(String rfqQuoteId) {
        List<RFQ_Quote__c> records = [
            SELECT Id,
                   Supplier__c, Supplier__r.Name,
                   Unit_Price__c, Lead_Time_Days__c, MOQ__c,
                   Manufacturing_Site__c, Manufacturing_Site__r.Name,
                   Valid_Until__c, Response_Date__c,
                   AI_Supplier_Text__c, AI_Unit_Price__c, AI_Lead_Time_Days__c,
                   AI_MOQ__c, AI_Manufacturing_Site__c, AI_Valid_Until__c, AI_Response_Date__c
            FROM RFQ_Quote__c
            WHERE Id = :rfqQuoteId
            LIMIT 1
        ];
        if (records.isEmpty()) {
            throw new AuraHandledException('レコードが見つかりません: ' + rfqQuoteId);
        }
        return records[0];
    }

    private static String buildAnalysisJson(RFQ_Quote__c q) {
        List<Map<String, Object>> fields = new List<Map<String, Object>>();
        fields.add(buildFieldPair('supplier_name', 'サプライヤー名',
            q.Supplier__c != null ? q.Supplier__r.Name : null, q.AI_Supplier_Text__c));
        fields.add(buildFieldPair('unit_price', '単価', q.Unit_Price__c, q.AI_Unit_Price__c));
        fields.add(buildFieldPair('lead_time_days', '納期日数', q.Lead_Time_Days__c, q.AI_Lead_Time_Days__c));
        fields.add(buildFieldPair('moq', 'MOQ', q.MOQ__c, q.AI_MOQ__c));
        fields.add(buildFieldPair('manufacturing_site', '製造拠点',
            q.Manufacturing_Site__c != null ? q.Manufacturing_Site__r.Name : null, q.AI_Manufacturing_Site__c));
        fields.add(buildFieldPair('valid_until', '有効期限',
            q.Valid_Until__c != null ? String.valueOf(q.Valid_Until__c) : null,
            q.AI_Valid_Until__c != null ? String.valueOf(q.AI_Valid_Until__c) : null));
        fields.add(buildFieldPair('response_date', '回答日',
            q.Response_Date__c != null ? String.valueOf(q.Response_Date__c) : null,
            q.AI_Response_Date__c != null ? String.valueOf(q.AI_Response_Date__c) : null));

        return JSON.serialize(new Map<String, Object>{ 'fields' => fields });
    }

    private static Map<String, Object> buildFieldPair(String field, String label, Object humanVal, Object aiVal) {
        return new Map<String, Object>{
            'field' => field,
            'label' => label,
            'human' => humanVal,
            'ai' => aiVal
        };
    }

    private static String callPromptTemplate(String analysisJson) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput input =
            new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;
        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptBuilderPreview';
        input.additionalConfig.numGenerations = 1;
        input.additionalConfig.temperature = 0;

        ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
        wv.value = analysisJson;
        Map<String, ConnectApi.WrappedValue> inputParams =
            new Map<String, ConnectApi.WrappedValue>{ 'Input:analysisData' => wv };
        input.inputParams = inputParams;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation result =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(PROMPT_TEMPLATE_NAME, input);

        if (result == null || result.generations == null || result.generations.isEmpty()) {
            throw new AuraHandledException(
                'Prompt Templateから応答が得られませんでした。Prompt Builderで Activate 済みか確認してください。'
            );
        }
        return result.generations[0].text;
    }

    private static String stripCodeFences(String s) {
        if (s == null) return '';
        String t = s.trim();
        if (t.startsWith('```')) {
            Integer nl = t.indexOf('\n');
            if (nl > 0) t = t.substring(nl + 1);
            if (t.endsWith('```')) t = t.substring(0, t.length() - 3);
        }
        return t.trim();
    }

    private static void applyJudgmentResult(String rfqQuoteId, Map<String, Object> judged) {
        List<Object> judgments = (List<Object>) judged.get('judgments');
        String overall = (String) judged.get('overall_level');
        String summary = (String) judged.get('summary');

        Map<String, Map<String, String>> byField = new Map<String, Map<String, String>>();
        if (judgments != null) {
            for (Object j : judgments) {
                Map<String, Object> m = (Map<String, Object>) j;
                String field = (String) m.get('field');
                byField.put(field, new Map<String, String>{
                    'level' => (String) m.get('level'),
                    'reason' => (String) m.get('reason')
                });
            }
        }

        RFQ_Quote__c q = new RFQ_Quote__c(Id = rfqQuoteId);
        setDiscrepancy(q, 'supplier_name', 'Supplier', byField);
        setDiscrepancy(q, 'unit_price', 'Unit_Price', byField);
        setDiscrepancy(q, 'lead_time_days', 'Lead_Time_Days', byField);
        setDiscrepancy(q, 'moq', 'MOQ', byField);
        setDiscrepancy(q, 'manufacturing_site', 'Manufacturing_Site', byField);
        setDiscrepancy(q, 'valid_until', 'Valid_Until', byField);
        setDiscrepancy(q, 'response_date', 'Response_Date', byField);

        q.IDP_Overall_Discrepancy_Level__c = overall;
        q.IDP_Judgment_Summary__c = summary;
        q.IDP_Judged_At__c = Datetime.now();
        q.IDP_Review_Status__c = '担当者確認中';
        q.IDP_Error_Message__c = null;
        update q;
    }

    private static void setDiscrepancy(RFQ_Quote__c q, String key, String fieldPrefix, Map<String, Map<String, String>> byField) {
        Map<String, String> m = byField.get(key);
        if (m == null) return;
        String level = m.get('level');
        String reason = m.get('reason');
        if (reason != null && reason.length() > 255) reason = reason.left(255);
        q.put(fieldPrefix + '_Discrepancy_Level__c', level);
        q.put(fieldPrefix + '_Discrepancy_Reason__c', reason);
    }

    // ============================================================
    // 6. 確認完了(人間による最終承認)
    // ============================================================

    @AuraEnabled
    public static void markAsConfirmed(String rfqQuoteId, String reviewNote) {
        try {
            update new RFQ_Quote__c(
                Id = rfqQuoteId,
                IDP_Review_Note__c = reviewNote,
                IDP_Confirmed_At__c = Datetime.now(),
                IDP_Review_Status__c = '担当者確認済'
            );
        } catch (Exception e) {
            throw new AuraHandledException('確認完了処理に失敗しました: ' + e.getMessage());
        }
    }

    // ============================================================
    // 7. やり直し(AI影フィールド + 判定結果 全クリア)
    // ============================================================

    @AuraEnabled
    public static void clearIdpResult(String rfqQuoteId) {
        try {
            update new RFQ_Quote__c(
                Id = rfqQuoteId,
                AI_Supplier_Text__c = null, AI_Supplier_Confidence__c = null,
                AI_Unit_Price__c = null, AI_Unit_Price_Confidence__c = null,
                AI_Lead_Time_Days__c = null, AI_Lead_Time_Days_Confidence__c = null,
                AI_MOQ__c = null, AI_MOQ_Confidence__c = null,
                AI_Manufacturing_Site__c = null, AI_Manufacturing_Site_Confidence__c = null,
                AI_Valid_Until__c = null, AI_Valid_Until_Confidence__c = null,
                AI_Response_Date__c = null, AI_Response_Date_Confidence__c = null,
                Supplier_Discrepancy_Level__c = null, Supplier_Discrepancy_Reason__c = null,
                Unit_Price_Discrepancy_Level__c = null, Unit_Price_Discrepancy_Reason__c = null,
                Lead_Time_Days_Discrepancy_Level__c = null, Lead_Time_Days_Discrepancy_Reason__c = null,
                MOQ_Discrepancy_Level__c = null, MOQ_Discrepancy_Reason__c = null,
                Manufacturing_Site_Discrepancy_Level__c = null, Manufacturing_Site_Discrepancy_Reason__c = null,
                Valid_Until_Discrepancy_Level__c = null, Valid_Until_Discrepancy_Reason__c = null,
                Response_Date_Discrepancy_Level__c = null, Response_Date_Discrepancy_Reason__c = null,
                IDP_Document_URL__c = null,
                IDP_Extracted_At__c = null, IDP_Judged_At__c = null, IDP_Confirmed_At__c = null,
                IDP_Overall_Discrepancy_Level__c = null,
                IDP_Judgment_Summary__c = null, IDP_Review_Note__c = null,
                IDP_Error_Message__c = null,
                IDP_Review_Status__c = '担当者入力完了'
            );
        } catch (Exception e) {
            throw new AuraHandledException('リセットに失敗しました: ' + e.getMessage());
        }
    }
}
