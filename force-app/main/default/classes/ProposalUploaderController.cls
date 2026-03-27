/**
 * ProposalUploaderController
 * 提案書アップロードLWC用Apexコントローラ
 * - S3 Presigned URL取得（API Gateway経由）
 * - Lambda抽出処理キック（API Gateway経由）
 * - Proposal_Context__cレコード管理
 *
 * Remote Site Settings に以下の登録が必要:
 *   URL: https://PLACEHOLDER.execute-api.ap-northeast-1.amazonaws.com
 */
public with sharing class ProposalUploaderController {

    // API Gateway エンドポイント（本番環境ではカスタムメタデータ等で管理推奨）
    private static final String API_GATEWAY_BASE = 'https://vdydb45kz5.execute-api.ap-northeast-1.amazonaws.com/prod';
    private static final String PRESIGN_ENDPOINT = API_GATEWAY_BASE + '/presign';
    private static final String EXTRACT_ENDPOINT = API_GATEWAY_BASE + '/extract';

    /**
     * S3 Presigned URL を取得する
     * @param fileName アップロードファイル名
     * @param contentType MIMEタイプ
     * @return presignedUrl, bucket, s3Key を含むMap
     */
    @AuraEnabled
    public static Map<String, String> getPresignedUrl(String fileName, String contentType) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(PRESIGN_ENDPOINT);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(30000);

            Map<String, String> requestBody = new Map<String, String>{
                'file_name' => fileName,
                'content_type' => contentType
            };
            req.setBody(JSON.serialize(requestBody));

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() != 200) {
                throw new AuraHandledException(
                    'Presigned URL の取得に失敗しました (HTTP ' + res.getStatusCode() + '): ' + res.getBody()
                );
            }

            Map<String, Object> responseMap = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Map<String, String> result = new Map<String, String>{
                'presignedUrl' => (String) responseMap.get('presigned_url'),
                'bucket' => (String) responseMap.get('bucket'),
                's3Key' => (String) responseMap.get('s3_key')
            };
            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Presigned URL 取得中にエラーが発生しました: ' + e.getMessage());
        }
    }

    /**
     * Proposal_Context__c レコードを作成する（DMLのみ、calloutなし）
     * @param opportunityId 商談ID
     * @param bucket S3バケット名
     * @param s3Key S3オブジェクトキー
     * @param fileName ファイル名
     * @return 作成された Proposal_Context__c レコードID
     */
    @AuraEnabled
    public static String createProposalContext(String opportunityId, String bucket, String s3Key, String fileName) {
        try {
            Proposal_Context__c pc = new Proposal_Context__c(
                Opportunity__c = opportunityId,
                File_Name__c = fileName,
                File_URL__c = 's3://' + bucket + '/' + s3Key,
                Extraction_Status__c = '処理中'
            );
            insert pc;
            return pc.Id;
        } catch (Exception e) {
            throw new AuraHandledException('レコード作成に失敗しました: ' + e.getMessage());
        }
    }

    /**
     * テキスト抽出処理を非同期でキックする（calloutのみ、DMLなし）
     * @param proposalContextId Proposal_Context__c レコードID
     * @param bucket S3バケット名
     * @param s3Key S3オブジェクトキー
     * @param opportunityId 商談ID
     */
    @AuraEnabled
    public static void startExtraction(String proposalContextId, String bucket, String s3Key, String opportunityId) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(EXTRACT_ENDPOINT);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(30000);

            Map<String, String> requestBody = new Map<String, String>{
                'bucket' => bucket,
                'key' => s3Key,
                'proposal_context_id' => proposalContextId,
                'opportunity_id' => opportunityId
            };
            req.setBody(JSON.serialize(requestBody));

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() != 200 && res.getStatusCode() != 202) {
                throw new AuraHandledException(
                    '抽出処理の開始に失敗しました (HTTP ' + res.getStatusCode() + '): ' + res.getBody()
                );
            }
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('抽出処理の開始中にエラーが発生しました: ' + e.getMessage());
        }
    }

    /**
     * 商談に紐づく Proposal_Context__c レコード一覧を取得する
     * @param opportunityId 商談ID
     * @return Proposal_Context__c のリスト
     */
    @AuraEnabled(cacheable=true)
    public static List<Proposal_Context__c> getProposalContexts(String opportunityId) {
        return [
            SELECT Id, File_Name__c, Extraction_Status__c, Extracted_At__c, File_URL__c
            FROM Proposal_Context__c
            WHERE Opportunity__c = :opportunityId
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];
    }

    /**
     * 単一の Proposal_Context__c レコードのステータスを取得する（ポーリング用）
     * @param proposalContextId レコードID
     * @return Proposal_Context__c レコード
     */
    @AuraEnabled
    public static Proposal_Context__c getExtractionStatus(String proposalContextId) {
        List<Proposal_Context__c> records = [
            SELECT Id, Extraction_Status__c, Extracted_At__c
            FROM Proposal_Context__c
            WHERE Id = :proposalContextId
            LIMIT 1
        ];
        if (records.isEmpty()) {
            throw new AuraHandledException('指定されたレコードが見つかりません: ' + proposalContextId);
        }
        return records[0];
    }

    /**
     * Proposal_Context__c レコードを削除する
     * @param proposalContextId 削除対象のレコードID
     */
    @AuraEnabled
    public static void deleteProposalContext(String proposalContextId) {
        try {
            Proposal_Context__c pc = [
                SELECT Id FROM Proposal_Context__c WHERE Id = :proposalContextId LIMIT 1
            ];
            delete pc;
        } catch (QueryException e) {
            throw new AuraHandledException('指定されたレコードが見つかりません: ' + proposalContextId);
        } catch (Exception e) {
            throw new AuraHandledException('削除に失敗しました: ' + e.getMessage());
        }
    }
}
