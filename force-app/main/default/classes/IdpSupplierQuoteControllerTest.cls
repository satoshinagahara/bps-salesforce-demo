@isTest
private class IdpSupplierQuoteControllerTest {

    // Mock for /idp/presign and /idp/extract endpoints
    private class IdpHttpMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            if (req.getEndpoint().contains('/idp/presign')) {
                res.setStatusCode(200);
                res.setBody(JSON.serialize(new Map<String, String>{
                    'presigned_url' => 'https://example.s3.amazonaws.com/fake',
                    'bucket' => 'bps-demo-proposals-938145531465',
                    's3_key' => 'idp-supplier-quote/abc-test.pdf'
                }));
            } else if (req.getEndpoint().contains('/idp/extract')) {
                res.setStatusCode(202);
                res.setBody('{"message":"IDP抽出処理を開始しました"}');
            } else {
                res.setStatusCode(404);
                res.setBody('{"error":"unknown"}');
            }
            return res;
        }
    }

    private static RFQ_Quote__c setupQuote() {
        Account supplier = new Account(Name = 'テスト取引先株式会社');
        insert supplier;

        RFQ__c rfq = new RFQ__c(
            Title__c = 'UT用RFQ',
            Part_Number__c = 'UT-001',
            Status__c = '発行済',
            Required_Quantity__c = 100
        );
        insert rfq;

        RFQ_Quote__c q = new RFQ_Quote__c(
            RFQ__c = rfq.Id,
            Supplier__c = supplier.Id,
            Status__c = '回答済',
            Unit_Price__c = 1000,
            Lead_Time_Days__c = 30,
            MOQ__c = 100,
            IDP_Review_Status__c = '担当者入力完了'
        );
        insert q;
        return q;
    }

    @isTest
    static void testGetPresignedUrl() {
        Test.setMock(HttpCalloutMock.class, new IdpHttpMock());
        Test.startTest();
        Map<String, String> result = IdpSupplierQuoteController.getPresignedUrl('test.pdf', 'application/pdf');
        Test.stopTest();
        System.assertEquals('bps-demo-proposals-938145531465', result.get('bucket'));
        System.assert(result.get('s3Key').startsWith('idp-supplier-quote/'));
    }

    @isTest
    static void testInitializeIdpRecord() {
        RFQ_Quote__c q = setupQuote();
        Test.startTest();
        IdpSupplierQuoteController.initializeIdpRecord(
            q.Id, 'bps-demo-proposals-938145531465', 'idp-supplier-quote/abc-test.pdf', 'test.pdf'
        );
        Test.stopTest();
        RFQ_Quote__c reloaded = [SELECT IDP_Review_Status__c, IDP_Document_URL__c, IDP_Extracted_At__c FROM RFQ_Quote__c WHERE Id = :q.Id];
        // ステータスは変更しない(担当者入力完了のまま)。IDP抽出中は Document_URL + Extracted_At=null から派生
        System.assertEquals('担当者入力完了', reloaded.IDP_Review_Status__c);
        System.assert(reloaded.IDP_Document_URL__c.startsWith('s3://'));
        System.assertEquals(null, reloaded.IDP_Extracted_At__c);
    }

    @isTest
    static void testStartExtraction() {
        RFQ_Quote__c q = setupQuote();
        Test.setMock(HttpCalloutMock.class, new IdpHttpMock());
        Test.startTest();
        IdpSupplierQuoteController.startExtraction(q.Id, 'bps-demo-proposals-938145531465', 'idp-supplier-quote/abc-test.pdf');
        Test.stopTest();
        // No exception = success
    }

    @isTest
    static void testGetIdpStatus() {
        RFQ_Quote__c q = setupQuote();
        Test.startTest();
        RFQ_Quote__c result = IdpSupplierQuoteController.getIdpStatus(q.Id);
        Test.stopTest();
        System.assertEquals('担当者入力完了', result.IDP_Review_Status__c);
    }

    @isTest
    static void testMarkAsConfirmed() {
        RFQ_Quote__c q = setupQuote();
        Test.startTest();
        IdpSupplierQuoteController.markAsConfirmed(q.Id, '確認メモ: テスト');
        Test.stopTest();
        RFQ_Quote__c reloaded = [SELECT IDP_Review_Status__c, IDP_Review_Note__c, IDP_Confirmed_At__c FROM RFQ_Quote__c WHERE Id = :q.Id];
        System.assertEquals('担当者確認済', reloaded.IDP_Review_Status__c);
        System.assertEquals('確認メモ: テスト', reloaded.IDP_Review_Note__c);
        System.assertNotEquals(null, reloaded.IDP_Confirmed_At__c);
    }

    @isTest
    static void testClearIdpResult() {
        RFQ_Quote__c q = setupQuote();
        q.AI_Unit_Price__c = 999;
        q.AI_Supplier_Text__c = 'AI抽出値';
        q.AI_Notes__c = 'AI抽出備考';
        q.IDP_Review_Status__c = '担当者確認中';
        update q;

        Test.startTest();
        IdpSupplierQuoteController.clearIdpResult(q.Id);
        Test.stopTest();

        RFQ_Quote__c reloaded = [SELECT IDP_Review_Status__c, AI_Unit_Price__c, AI_Supplier_Text__c, AI_Notes__c FROM RFQ_Quote__c WHERE Id = :q.Id];
        System.assertEquals('担当者入力完了', reloaded.IDP_Review_Status__c);
        System.assertEquals(null, reloaded.AI_Unit_Price__c);
        System.assertEquals(null, reloaded.AI_Supplier_Text__c);
        System.assertEquals(null, reloaded.AI_Notes__c);
    }
}
