/**
 * SRMサプライヤーポータルのSharingSet/外部OWDが期待通り動作するかを検証する。
 * runAs()でPartner Community Userとして実行し、自Accountのレコードのみ見えることを確認する。
 */
@IsTest(SeeAllData=true)
private class SupplierPortalSharingTest {

    @IsTest
    static void portalUserCanSeeOwnSupplierDataOnly() {
        User portalUser = [
            SELECT Id, Username, AccountId
            FROM User
            WHERE Username = 'yoshida1776431632685@greenenergy.demo.sfdc'
            LIMIT 1
        ];
        System.assertNotEquals(null, portalUser.AccountId, 'PortalユーザーにAccountIdが必要');

        Id ownAccountId = portalUser.AccountId;

        // 他社サプライヤー: 吉田のAccount以外
        Id otherSupplierId = [
            SELECT Id FROM Account
            WHERE RecordType.DeveloperName = 'Supplier' AND Id != :ownAccountId
            LIMIT 1
        ].Id;

        Test.startTest();
        System.runAs(portalUser) {
            // Manufacturing_Site__c: 自社のみ見える
            Integer ownSites = [SELECT COUNT() FROM Manufacturing_Site__c WHERE Supplier__c = :ownAccountId];
            Integer otherSites = [SELECT COUNT() FROM Manufacturing_Site__c WHERE Supplier__c = :otherSupplierId];
            System.debug(LoggingLevel.INFO, '[Manufacturing_Site__c] own=' + ownSites + ' other=' + otherSites);
            System.assert(ownSites > 0, '自社のManufacturing_Siteが見えるべき');
            System.assertEquals(0, otherSites, '他社のManufacturing_Siteは見えてはいけない');

            // Supplier_Certification__c: 自社のみ
            Integer ownCerts = [SELECT COUNT() FROM Supplier_Certification__c WHERE Supplier__c = :ownAccountId];
            Integer otherCerts = [SELECT COUNT() FROM Supplier_Certification__c WHERE Supplier__c = :otherSupplierId];
            System.debug(LoggingLevel.INFO, '[Supplier_Certification__c] own=' + ownCerts + ' other=' + otherCerts);
            System.assertEquals(0, otherCerts, '他社のCertificationは見えてはいけない');

            // Corrective_Action__c: 自社のみ
            Integer ownCAs = [SELECT COUNT() FROM Corrective_Action__c WHERE Supplier__c = :ownAccountId];
            Integer otherCAs = [SELECT COUNT() FROM Corrective_Action__c WHERE Supplier__c = :otherSupplierId];
            System.debug(LoggingLevel.INFO, '[Corrective_Action__c] own=' + ownCAs + ' other=' + otherCAs);
            System.assertEquals(0, otherCAs, '他社のCorrectiveActionは見えてはいけない');

            // Supplier_Investigation__c (Corrective_ActionのChild): 自社のみ
            Integer ownSIs = [
                SELECT COUNT() FROM Supplier_Investigation__c
                WHERE Corrective_Action__r.Supplier__c = :ownAccountId
            ];
            Integer otherSIs = [
                SELECT COUNT() FROM Supplier_Investigation__c
                WHERE Corrective_Action__r.Supplier__c = :otherSupplierId
            ];
            System.debug(LoggingLevel.INFO, '[Supplier_Investigation__c] own=' + ownSIs + ' other=' + otherSIs);
            System.assertEquals(0, otherSIs, '他社のInvestigationは見えてはいけない');

            // RFQ__c: Public Read -> 全件見える
            Integer allRfqs = [SELECT COUNT() FROM RFQ__c];
            System.debug(LoggingLevel.INFO, '[RFQ__c] all visible=' + allRfqs);
            System.assert(allRfqs > 0, 'RFQ__cはPublic Readなので全件見えるべき');

            // RFQ_Quote__c (RFQのChild): 自社宛のみ見える（※実際にはChildなのでPublic Read継承だが、RFQが親なのでQuoteも同様に見える）
            Integer ownQuotes = [SELECT COUNT() FROM RFQ_Quote__c WHERE Supplier__c = :ownAccountId];
            System.debug(LoggingLevel.INFO, '[RFQ_Quote__c] own=' + ownQuotes);

            // SupplierPortalController.getDashboard 呼び出し検証
            SupplierPortalController.DashboardDTO dto = SupplierPortalController.getDashboard(ownAccountId);
            System.assertNotEquals(null, dto, 'DashboardDTOが返ってくるべき');
            System.assertNotEquals(null, dto.supplier, 'Supplier情報が返ってくるべき');
            System.debug(LoggingLevel.INFO, '[Dashboard] supplier=' + dto.supplier.name
                + ' recentRfqs=' + (dto.recentRfqs == null ? 0 : dto.recentRfqs.size())
                + ' recentInvestigations=' + (dto.recentInvestigations == null ? 0 : dto.recentInvestigations.size()));
        }
        Test.stopTest();
    }
}
