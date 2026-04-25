/**
 * サプライヤーポータル（Experience Cloud）向けのデータ取得コントローラー。
 *
 * 設計書: docs/in-progress/supplier-portal-design.md
 *
 * デモ用途で accountId をパラメータとして受け取れる構造にしている。
 * 本番想定では UserInfo.getUserId() 経由で User.AccountId を解決する。
 */
public with sharing class SupplierPortalController {

    // キャパシティ未更新と見なすしきい値（日数）
    private static final Integer CAPACITY_STALE_THRESHOLD_DAYS = 90;
    // 認証の期限切れ警告しきい値（日数）
    private static final Integer CERT_EXPIRY_WARNING_DAYS = 90;

    /**
     * ダッシュボードに必要な全ブロックを1回で返す。
     */
    @AuraEnabled(cacheable=true)
    public static DashboardDTO getDashboard(Id accountId) {
        Id supplierId = resolveSupplierId(accountId);
        if (supplierId == null) {
            throw new AuraHandledException('サプライヤーAccountが特定できません。');
        }

        DashboardDTO dto = new DashboardDTO();
        dto.supplier = buildSupplierHeader(supplierId);
        dto.actionKpis = buildActionKpis(supplierId);
        dto.rfqStatusBreakdown = buildRfqStatusBreakdown(supplierId);
        dto.investigationStatusBreakdown = buildInvestigationStatusBreakdown(supplierId);
        dto.capacitySummary = buildCapacitySummary(supplierId);
        dto.certifications = buildCertifications(supplierId);
        dto.recentRfqs = buildRecentRfqs(supplierId);
        dto.recentInvestigations = buildRecentInvestigations(supplierId);
        return dto;
    }

    // =========================================================================
    // 共通処理
    // =========================================================================

    private static Id resolveSupplierId(Id accountId) {
        if (accountId != null) {
            return accountId;
        }
        // Experience Cloudユーザーが自社Accountに紐づいている想定
        User u = [SELECT AccountId FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        return u.AccountId;
    }

    /**
     * 実行ユーザーが指定されたsupplierのレコードを編集できるか検証。
     * Experience Cloudユーザーは自社Accountのレコードのみ編集可。
     * 内部ユーザー（System Admin等）はAccountIdが無いためスキップ。
     */
    private static void enforceQuoteOwnership(Id recordSupplierId) {
        User u = [SELECT AccountId FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1];
        if (u.AccountId == null) {
            return; // 内部ユーザーはチェック対象外
        }
        if (recordSupplierId != u.AccountId) {
            throw new AuraHandledException('このレコードを編集する権限がありません。');
        }
    }

    /**
     * RFQ__c は 外部OWD=Public Read のため、ControlledByParent の RFQ_Quote__c は
     * 外部ユーザーからは Read のみで Edit できない。
     * ownership 検証済みの上で without sharing で update するための内部ヘルパー。
     */
    private without sharing class ElevatedOps {
        void updateQuote(RFQ_Quote__c q) {
            update q;
        }
        void updateInvestigation(Supplier_Investigation__c si) {
            update si;
        }
    }

    // =========================================================================
    // サプライヤー情報ヘッダ
    // =========================================================================

    private static SupplierHeaderDTO buildSupplierHeader(Id supplierId) {
        Account a = [
            SELECT Id, Name, Website
            FROM Account
            WHERE Id = :supplierId
            LIMIT 1
        ];
        SupplierHeaderDTO h = new SupplierHeaderDTO();
        h.id = a.Id;
        h.name = a.Name;
        h.website = a.Website;
        return h;
    }

    // =========================================================================
    // アクションKPI（4種）
    // =========================================================================

    private static ActionKpisDTO buildActionKpis(Id supplierId) {
        ActionKpisDTO k = new ActionKpisDTO();

        // 未回答RFQ（RFQ_Quote.Status = '依頼中'）
        List<AggregateResult> rfqAgg = [
            SELECT COUNT(Id) cnt, MIN(RFQ__r.Due_Date__c) earliestDue
            FROM RFQ_Quote__c
            WHERE Supplier__c = :supplierId
              AND Status__c = '依頼中'
        ];
        if (!rfqAgg.isEmpty()) {
            k.unansweredRfqCount = (Integer) rfqAgg[0].get('cnt');
            k.unansweredRfqNearestDue = (Date) rfqAgg[0].get('earliestDue');
        }

        // 対応中の調査（完了・回答済以外）
        List<AggregateResult> invAgg = [
            SELECT COUNT(Id) cnt, MIN(Response_Due_Date__c) earliestDue
            FROM Supplier_Investigation__c
            WHERE Supplier__c = :supplierId
              AND Status__c IN ('依頼中', '調査中', '対策実施中')
        ];
        if (!invAgg.isEmpty()) {
            k.ongoingInvestigationCount = (Integer) invAgg[0].get('cnt');
            k.investigationNearestDue = (Date) invAgg[0].get('earliestDue');
        }

        // 期限切れ間近認証（90日以内 + 更新中 も含む）
        Date today = Date.today();
        Date threshold = today.addDays(CERT_EXPIRY_WARNING_DAYS);
        List<Supplier_Certification__c> certs = [
            SELECT Expiry_Date__c
            FROM Supplier_Certification__c
            WHERE Supplier__c = :supplierId
              AND Status__c IN ('有効', '更新中')
              AND Expiry_Date__c != null
              AND Expiry_Date__c <= :threshold
            ORDER BY Expiry_Date__c ASC
        ];
        k.expiringCertificationCount = certs.size();
        if (!certs.isEmpty()) {
            k.certNearestExpiryDays = today.daysBetween(certs[0].Expiry_Date__c);
        }

        // キャパシティ未更新拠点（90日以上最終更新なし）
        // 拠点ごとに最新のSupplier_Capacity.LastModifiedDate を取得
        Datetime staleLimit = Datetime.now().addDays(-CAPACITY_STALE_THRESHOLD_DAYS);
        List<Manufacturing_Site__c> sites = [
            SELECT Id, Name,
                (SELECT LastModifiedDate FROM Supplier_Capacities__r ORDER BY LastModifiedDate DESC LIMIT 1)
            FROM Manufacturing_Site__c
            WHERE Supplier__c = :supplierId
        ];
        Integer outdated = 0;
        Date oldestUpdate = null;
        for (Manufacturing_Site__c s : sites) {
            if (s.Supplier_Capacities__r.isEmpty()) {
                outdated++;
                continue;
            }
            Datetime lm = s.Supplier_Capacities__r[0].LastModifiedDate;
            if (lm < staleLimit) {
                outdated++;
                Date d = lm.date();
                if (oldestUpdate == null || d < oldestUpdate) {
                    oldestUpdate = d;
                }
            }
        }
        k.outdatedCapacitySiteCount = outdated;
        k.capacityOldestUpdateDate = oldestUpdate;

        return k;
    }

    // =========================================================================
    // RFQ進行状況（自社分）
    // =========================================================================

    private static List<StatusBreakdownDTO> buildRfqStatusBreakdown(Id supplierId) {
        List<AggregateResult> rows = [
            SELECT Status__c status, COUNT(Id) cnt
            FROM RFQ_Quote__c
            WHERE Supplier__c = :supplierId
            GROUP BY Status__c
        ];
        List<StatusBreakdownDTO> out = new List<StatusBreakdownDTO>();
        for (AggregateResult r : rows) {
            StatusBreakdownDTO s = new StatusBreakdownDTO();
            s.status = (String) r.get('status');
            s.count = (Integer) r.get('cnt');
            out.add(s);
        }
        return out;
    }

    // =========================================================================
    // 調査対応状況
    // =========================================================================

    private static List<StatusBreakdownDTO> buildInvestigationStatusBreakdown(Id supplierId) {
        List<AggregateResult> rows = [
            SELECT Status__c status, COUNT(Id) cnt
            FROM Supplier_Investigation__c
            WHERE Supplier__c = :supplierId
            GROUP BY Status__c
        ];
        List<StatusBreakdownDTO> out = new List<StatusBreakdownDTO>();
        for (AggregateResult r : rows) {
            StatusBreakdownDTO s = new StatusBreakdownDTO();
            s.status = (String) r.get('status');
            s.count = (Integer) r.get('cnt');
            out.add(s);
        }
        return out;
    }

    // =========================================================================
    // キャパシティサマリー（拠点別）
    // =========================================================================

    private static List<CapacitySummaryDTO> buildCapacitySummary(Id supplierId) {
        List<Manufacturing_Site__c> sites = [
            SELECT Id, Name, Prefecture__c,
                (SELECT Id, Monthly_Capacity__c, Effective_To__c
                 FROM Supplier_Capacities__r)
            FROM Manufacturing_Site__c
            WHERE Supplier__c = :supplierId
            ORDER BY Name ASC
        ];
        Date today = Date.today();
        Date soon = today.addDays(30);
        List<CapacitySummaryDTO> out = new List<CapacitySummaryDTO>();
        for (Manufacturing_Site__c s : sites) {
            CapacitySummaryDTO d = new CapacitySummaryDTO();
            d.siteId = s.Id;
            d.siteName = s.Name;
            d.prefecture = s.Prefecture__c;
            d.capacityEntryCount = s.Supplier_Capacities__r.size();
            Decimal total = 0;
            Date earliestEnd = null;
            for (Supplier_Capacity__c c : s.Supplier_Capacities__r) {
                if (c.Monthly_Capacity__c != null) {
                    total += c.Monthly_Capacity__c;
                }
                if (c.Effective_To__c != null &&
                    (earliestEnd == null || c.Effective_To__c < earliestEnd)) {
                    earliestEnd = c.Effective_To__c;
                }
            }
            d.totalMonthlyCapacity = total;
            d.earliestExpiryDate = earliestEnd;
            d.isExpiringSoon = (earliestEnd != null && earliestEnd <= soon);
            out.add(d);
        }
        return out;
    }

    // =========================================================================
    // 保有認証
    // =========================================================================

    private static List<CertificationDTO> buildCertifications(Id supplierId) {
        List<Supplier_Certification__c> certs = [
            SELECT Id, Certification_Type__c, Certification_Number__c,
                   Status__c, Expiry_Date__c, Issuing_Body__c, Certificate_URL__c
            FROM Supplier_Certification__c
            WHERE Supplier__c = :supplierId
            ORDER BY Expiry_Date__c ASC NULLS LAST
        ];
        Date today = Date.today();
        List<CertificationDTO> out = new List<CertificationDTO>();
        for (Supplier_Certification__c c : certs) {
            CertificationDTO d = new CertificationDTO();
            d.id = c.Id;
            d.type = c.Certification_Type__c;
            d.certNumber = c.Certification_Number__c;
            d.status = c.Status__c;
            d.expiryDate = c.Expiry_Date__c;
            d.issuingBody = c.Issuing_Body__c;
            d.certificateUrl = c.Certificate_URL__c;
            if (c.Expiry_Date__c != null) {
                d.daysToExpiry = today.daysBetween(c.Expiry_Date__c);
            }
            out.add(d);
        }
        return out;
    }

    // =========================================================================
    // 最新RFQ（自社宛Quote経由）
    // =========================================================================

    private static List<InvestigationListItemDTO> buildRecentInvestigations(Id supplierId) {
        List<Supplier_Investigation__c> invs = [
            SELECT Id, Name, Status__c, Severity__c, Response_Due_Date__c,
                   Request_Detail__c
            FROM Supplier_Investigation__c
            WHERE Supplier__c = :supplierId
              AND Status__c IN ('依頼中', '調査中', '対策実施中')
            ORDER BY Response_Due_Date__c ASC NULLS LAST, CreatedDate DESC
            LIMIT 10
        ];
        Date today = Date.today();
        List<InvestigationListItemDTO> out = new List<InvestigationListItemDTO>();
        for (Supplier_Investigation__c i : invs) {
            InvestigationListItemDTO d = new InvestigationListItemDTO();
            d.investigationId = i.Id;
            d.name = i.Name;
            String sub = i.Request_Detail__c == null ? '' : i.Request_Detail__c;
            d.subject = sub.length() > 80 ? sub.substring(0, 80) + '…' : sub;
            d.status = i.Status__c;
            d.severity = i.Severity__c;
            d.responseDueDate = i.Response_Due_Date__c;
            if (i.Response_Due_Date__c != null) {
                d.daysToDue = today.daysBetween(i.Response_Due_Date__c);
            }
            out.add(d);
        }
        return out;
    }

    private static List<RfqListItemDTO> buildRecentRfqs(Id supplierId) {
        List<RFQ_Quote__c> quotes = [
            SELECT Id, Status__c, Unit_Price__c,
                   RFQ__c, RFQ__r.Name, RFQ__r.Title__c, RFQ__r.Part_Number__c,
                   RFQ__r.Required_Quantity__c, RFQ__r.Due_Date__c,
                   RFQ__r.Category__c, RFQ__r.Status__c
            FROM RFQ_Quote__c
            WHERE Supplier__c = :supplierId
            ORDER BY RFQ__r.Due_Date__c ASC NULLS LAST, CreatedDate DESC
            LIMIT 10
        ];
        Date today = Date.today();
        List<RfqListItemDTO> out = new List<RfqListItemDTO>();
        for (RFQ_Quote__c q : quotes) {
            RfqListItemDTO d = new RfqListItemDTO();
            d.quoteId = q.Id;
            d.quoteStatus = q.Status__c;
            d.unitPrice = q.Unit_Price__c;
            d.rfqId = q.RFQ__c;
            d.rfqName = q.RFQ__r.Name;
            d.rfqTitle = q.RFQ__r.Title__c;
            d.partNumber = q.RFQ__r.Part_Number__c;
            d.requiredQuantity = q.RFQ__r.Required_Quantity__c;
            d.dueDate = q.RFQ__r.Due_Date__c;
            d.category = q.RFQ__r.Category__c;
            d.rfqStatus = q.RFQ__r.Status__c;
            if (q.RFQ__r.Due_Date__c != null) {
                d.daysToDue = today.daysBetween(q.RFQ__r.Due_Date__c);
            }
            out.add(d);
        }
        return out;
    }

    // =========================================================================
    // RFQ見積回答画面用
    // =========================================================================

    /**
     * 指定RFQと、該当サプライヤーの見積Quote・製造拠点候補を返す。
     */
    @AuraEnabled(cacheable=true)
    public static RfqQuoteDetailDTO getRfqQuote(Id rfqId, Id accountId) {
        Id supplierId = resolveSupplierId(accountId);
        if (supplierId == null || rfqId == null) {
            throw new AuraHandledException('RFQ または サプライヤーが特定できません。');
        }

        RfqQuoteDetailDTO dto = new RfqQuoteDetailDTO();

        // RFQ本体
        List<RFQ__c> rfqs = [
            SELECT Id, Name, Title__c, Category__c, Status__c,
                   Part_Number__c, Part_Spec__c, Required_Quantity__c,
                   Target_Unit_Price__c, Due_Date__c, Notes__c,
                   BOM_Part__r.Name, BOM_Part__r.Part_Name__c
            FROM RFQ__c
            WHERE Id = :rfqId
            LIMIT 1
        ];
        if (rfqs.isEmpty()) {
            throw new AuraHandledException('指定されたRFQが見つかりません。');
        }
        RFQ__c r = rfqs[0];
        dto.rfqId = r.Id;
        dto.rfqName = r.Name;
        dto.title = r.Title__c;
        dto.category = r.Category__c;
        dto.rfqStatus = r.Status__c;
        dto.partNumber = r.Part_Number__c;
        dto.partSpec = r.Part_Spec__c;
        dto.requiredQuantity = r.Required_Quantity__c;
        dto.targetUnitPrice = r.Target_Unit_Price__c;
        dto.dueDate = r.Due_Date__c;
        dto.notes = r.Notes__c;
        if (r.Due_Date__c != null) {
            dto.daysToDue = Date.today().daysBetween(r.Due_Date__c);
        }
        // BOM情報は品名まで
        if (r.BOM_Part__c != null) {
            dto.bomPartName = r.BOM_Part__r.Part_Name__c;
        }

        // 既存Quote（このサプライヤーのもの）
        List<RFQ_Quote__c> quotes = [
            SELECT Id, Status__c, Unit_Price__c, MOQ__c, Lead_Time_Days__c,
                   Valid_Until__c, Manufacturing_Site__c, Manufacturing_Site__r.Name,
                   Response_Date__c, Notes__c, CreatedDate, LastModifiedDate
            FROM RFQ_Quote__c
            WHERE RFQ__c = :rfqId AND Supplier__c = :supplierId
            LIMIT 1
        ];
        if (!quotes.isEmpty()) {
            RFQ_Quote__c q = quotes[0];
            dto.quoteId = q.Id;
            dto.quoteStatus = q.Status__c;
            dto.quoteUnitPrice = q.Unit_Price__c;
            dto.quoteMoq = q.MOQ__c;
            dto.quoteLeadTimeDays = q.Lead_Time_Days__c;
            dto.quoteValidUntil = q.Valid_Until__c;
            dto.quoteManufacturingSiteId = q.Manufacturing_Site__c;
            dto.quoteManufacturingSiteName = q.Manufacturing_Site__r != null ? q.Manufacturing_Site__r.Name : null;
            dto.quoteResponseDate = q.Response_Date__c;
            dto.quoteNotes = q.Notes__c;
        }

        // 製造拠点候補
        for (Manufacturing_Site__c s : [
            SELECT Id, Name, Prefecture__c
            FROM Manufacturing_Site__c
            WHERE Supplier__c = :supplierId
            ORDER BY Name ASC
        ]) {
            SiteOptionDTO o = new SiteOptionDTO();
            o.siteId = s.Id;
            o.siteName = s.Name + (s.Prefecture__c != null ? ' (' + s.Prefecture__c + ')' : '');
            dto.siteOptions.add(o);
        }

        // 編集可否判定
        dto.isEditable = (dto.quoteStatus == '依頼中' || dto.quoteStatus == '回答済');
        return dto;
    }

    /**
     * 見積を提出（Status='回答済'）。
     */
    @AuraEnabled
    public static Id submitQuote(
        Id quoteId,
        Decimal unitPrice,
        Decimal moq,
        Decimal leadTimeDays,
        Date validUntil,
        Id siteId,
        String notes,
        String idpDataJson
    ) {
        if (quoteId == null) {
            throw new AuraHandledException('Quote IDが指定されていません。');
        }
        RFQ_Quote__c q = [SELECT Id, Status__c, Supplier__c FROM RFQ_Quote__c WHERE Id = :quoteId LIMIT 1];
        enforceQuoteOwnership(q.Supplier__c);
        if (q.Status__c == '採用' || q.Status__c == '不採用') {
            throw new AuraHandledException('このQuoteは既に確定しており編集できません。');
        }
        q.Unit_Price__c = unitPrice;
        q.MOQ__c = moq;
        q.Lead_Time_Days__c = leadTimeDays;
        q.Valid_Until__c = validUntil;
        q.Manufacturing_Site__c = siteId;
        q.Notes__c = notes;
        q.Status__c = '回答済';
        q.Response_Date__c = Date.today();  // IDPデータがあれば下記で上書き

        // IDPアップロード由来のデータを併せて保存(任意)
        // Response_Date__c は IDP抽出値があればそれで上書き(=見積書発行日)
        if (String.isNotBlank(idpDataJson)) {
            applyIdpDataToQuote(q, idpDataJson);
        }

        new ElevatedOps().updateQuote(q);
        return q.Id;
    }

    /**
     * IDP抽出JSON(extractPdfSync の戻り値)から RFQ_Quote__c のAI影フィールドを設定する。
     * idpData = { extraction: {supplier_name: {value, confidence}, ...}, bucket, s3_key, ... }
     */
    private static void applyIdpDataToQuote(RFQ_Quote__c q, String idpDataJson) {
        Map<String, Object> idpData = (Map<String, Object>) JSON.deserializeUntyped(idpDataJson);
        Map<String, Object> extraction = (Map<String, Object>) idpData.get('extraction');
        String bucket = (String) idpData.get('bucket');
        String s3Key = (String) idpData.get('s3_key');

        if (extraction != null) {
            q.AI_Supplier_Text__c = strVal(extraction, 'supplier_name');
            q.AI_Supplier_Confidence__c = confPct(extraction, 'supplier_name');
            q.AI_Unit_Price__c = decVal(extraction, 'unit_price');
            q.AI_Unit_Price_Confidence__c = confPct(extraction, 'unit_price');
            q.AI_Lead_Time_Days__c = decVal(extraction, 'lead_time_days');
            q.AI_Lead_Time_Days_Confidence__c = confPct(extraction, 'lead_time_days');
            q.AI_MOQ__c = decVal(extraction, 'moq');
            q.AI_MOQ_Confidence__c = confPct(extraction, 'moq');
            q.AI_Manufacturing_Site__c = strVal(extraction, 'manufacturing_site');
            q.AI_Manufacturing_Site_Confidence__c = confPct(extraction, 'manufacturing_site');
            q.AI_Valid_Until__c = dateVal(extraction, 'valid_until');
            q.AI_Valid_Until_Confidence__c = confPct(extraction, 'valid_until');
            q.AI_Response_Date__c = dateVal(extraction, 'response_date');
            q.AI_Response_Date_Confidence__c = confPct(extraction, 'response_date');
            q.AI_Notes__c = strVal(extraction, 'notes');
            q.AI_Notes_Confidence__c = confPct(extraction, 'notes');
            q.IDP_Extracted_At__c = Datetime.now();
            // Response_Date__c のセマンティック修正:
            // submitQuote で Date.today() がセット済だが、IDPで見積書発行日が抽出できた場合はそれで上書き
            // (担当者値=PDF発行日、AI値=PDF発行日 となり判定が"一致"になる)
            Date extractedResponseDate = dateVal(extraction, 'response_date');
            if (extractedResponseDate != null) {
                q.Response_Date__c = extractedResponseDate;
            }
        }

        if (String.isNotBlank(bucket) && String.isNotBlank(s3Key)) {
            q.IDP_Document_URL__c = 's3://' + bucket + '/' + s3Key;
        }
    }

    private static String strVal(Map<String, Object> ext, String key) {
        Map<String, Object> field = (Map<String, Object>) ext.get(key);
        if (field == null) return null;
        Object v = field.get('value');
        return v == null ? null : String.valueOf(v);
    }
    private static Decimal decVal(Map<String, Object> ext, String key) {
        Map<String, Object> field = (Map<String, Object>) ext.get(key);
        if (field == null) return null;
        Object v = field.get('value');
        if (v == null) return null;
        if (v instanceof Decimal) return (Decimal) v;
        if (v instanceof Integer) return (Decimal) v;
        if (v instanceof Long) return Decimal.valueOf((Long) v);
        if (v instanceof Double) return Decimal.valueOf((Double) v);
        try { return Decimal.valueOf(String.valueOf(v)); } catch (Exception e) { return null; }
    }
    private static Date dateVal(Map<String, Object> ext, String key) {
        Map<String, Object> field = (Map<String, Object>) ext.get(key);
        if (field == null) return null;
        Object v = field.get('value');
        if (v == null) return null;
        try { return Date.valueOf(String.valueOf(v)); } catch (Exception e) { return null; }
    }
    private static Decimal confPct(Map<String, Object> ext, String key) {
        Map<String, Object> field = (Map<String, Object>) ext.get(key);
        if (field == null) return null;
        Object c = field.get('confidence');
        if (c == null) return 0;
        Decimal d;
        if (c instanceof Decimal) d = (Decimal) c;
        else if (c instanceof Double) d = Decimal.valueOf((Double) c);
        else { try { d = Decimal.valueOf(String.valueOf(c)); } catch (Exception e) { return 0; } }
        return (d * 100).setScale(0, RoundingMode.HALF_UP);
    }

    /**
     * 見積を辞退（Status='辞退'）。
     */
    @AuraEnabled
    public static Id declineQuote(Id quoteId, String notes) {
        if (quoteId == null) {
            throw new AuraHandledException('Quote IDが指定されていません。');
        }
        RFQ_Quote__c q = [SELECT Id, Status__c, Supplier__c FROM RFQ_Quote__c WHERE Id = :quoteId LIMIT 1];
        enforceQuoteOwnership(q.Supplier__c);
        if (q.Status__c == '採用' || q.Status__c == '不採用') {
            throw new AuraHandledException('このQuoteは既に確定しており編集できません。');
        }
        q.Status__c = '辞退';
        q.Notes__c = notes;
        q.Response_Date__c = Date.today();
        new ElevatedOps().updateQuote(q);
        return q.Id;
    }

    // =========================================================================
    // キャパシティ管理画面用
    // =========================================================================

    /**
     * サプライヤーの全拠点とそれに紐づくキャパシティ一覧を返す。
     */
    @AuraEnabled(cacheable=true)
    public static List<CapacitySiteDTO> getCapacities(Id accountId) {
        Id supplierId = resolveSupplierId(accountId);
        if (supplierId == null) {
            throw new AuraHandledException('サプライヤーが特定できません。');
        }

        Date today = Date.today();
        Date soon = today.addDays(30);

        List<Manufacturing_Site__c> sites = [
            SELECT Id, Name, Prefecture__c, Is_Own_Site__c,
                (SELECT Id, Part_Number__c, Part_Name__c, Monthly_Capacity__c,
                        Effective_From__c, Effective_To__c, Notes__c, LastModifiedDate
                 FROM Supplier_Capacities__r
                 ORDER BY Part_Number__c ASC)
            FROM Manufacturing_Site__c
            WHERE Supplier__c = :supplierId
            ORDER BY Name ASC
        ];

        List<CapacitySiteDTO> out = new List<CapacitySiteDTO>();
        for (Manufacturing_Site__c s : sites) {
            CapacitySiteDTO site = new CapacitySiteDTO();
            site.siteId = s.Id;
            site.siteName = s.Name;
            site.prefecture = s.Prefecture__c;
            site.isOwnSite = s.Is_Own_Site__c;
            Decimal total = 0;
            Integer expiringCount = 0;
            for (Supplier_Capacity__c c : s.Supplier_Capacities__r) {
                CapacityItemDTO item = new CapacityItemDTO();
                item.id = c.Id;
                item.siteId = s.Id;
                item.partNumber = c.Part_Number__c;
                item.partName = c.Part_Name__c;
                item.monthlyCapacity = c.Monthly_Capacity__c;
                item.effectiveFrom = c.Effective_From__c;
                item.effectiveTo = c.Effective_To__c;
                item.notes = c.Notes__c;
                item.lastModified = c.LastModifiedDate;
                if (c.Effective_To__c != null && c.Effective_To__c <= soon) {
                    item.isExpiringSoon = true;
                    expiringCount++;
                }
                if (c.Monthly_Capacity__c != null) {
                    total += c.Monthly_Capacity__c;
                }
                site.items.add(item);
            }
            site.totalMonthlyCapacity = total;
            site.itemCount = s.Supplier_Capacities__r.size();
            site.expiringCount = expiringCount;
            out.add(site);
        }
        return out;
    }

    /**
     * キャパシティレコードを保存（新規/更新両対応）。
     */
    @AuraEnabled
    public static Id saveCapacity(
        Id id,
        Id siteId,
        String partNumber,
        String partName,
        Decimal monthlyCapacity,
        Date effectiveFrom,
        Date effectiveTo,
        String notes
    ) {
        Supplier_Capacity__c c;
        if (id == null) {
            if (siteId == null) {
                throw new AuraHandledException('製造拠点が指定されていません。');
            }
            c = new Supplier_Capacity__c(Manufacturing_Site__c = siteId);
        } else {
            c = [SELECT Id FROM Supplier_Capacity__c WHERE Id = :id LIMIT 1];
        }
        c.Part_Number__c = partNumber;
        c.Part_Name__c = partName;
        c.Monthly_Capacity__c = monthlyCapacity;
        c.Effective_From__c = effectiveFrom;
        c.Effective_To__c = effectiveTo;
        c.Notes__c = notes;
        upsert c;
        return c.Id;
    }

    /**
     * キャパシティレコードを削除。
     */
    @AuraEnabled
    public static void deleteCapacity(Id id) {
        if (id == null) return;
        delete [SELECT Id FROM Supplier_Capacity__c WHERE Id = :id LIMIT 1];
    }

    // =========================================================================
    // RFQ一覧（supplierRfqList LWC用）
    // =========================================================================

    /**
     * 該当サプライヤーに届いたRFQ Quote 全件を返す。
     * フィルタ: 'all' | 'pending'(依頼中) | 'answered'(回答済/採用/不採用/辞退) | 'closed'
     */
    @AuraEnabled(cacheable=true)
    public static RfqListDTO getRfqList(Id accountId, String filter) {
        Id supplierId = resolveSupplierId(accountId);
        if (supplierId == null) {
            throw new AuraHandledException('サプライヤーAccountが特定できません。');
        }
        String f = String.isBlank(filter) ? 'all' : filter;

        List<RFQ_Quote__c> quotes = [
            SELECT Id, Status__c, Unit_Price__c,
                   RFQ__c, RFQ__r.Name, RFQ__r.Title__c, RFQ__r.Part_Number__c,
                   RFQ__r.Required_Quantity__c, RFQ__r.Due_Date__c,
                   RFQ__r.Category__c, RFQ__r.Status__c
            FROM RFQ_Quote__c
            WHERE Supplier__c = :supplierId
            ORDER BY RFQ__r.Due_Date__c ASC NULLS LAST, CreatedDate DESC
            LIMIT 200
        ];

        RfqListDTO dto = new RfqListDTO();
        Date today = Date.today();
        Integer pending = 0, answered = 0, closed = 0;

        for (RFQ_Quote__c q : quotes) {
            RfqListItemDTO d = new RfqListItemDTO();
            d.quoteId = q.Id;
            d.quoteStatus = q.Status__c;
            d.unitPrice = q.Unit_Price__c;
            d.rfqId = q.RFQ__c;
            d.rfqName = q.RFQ__r.Name;
            d.rfqTitle = q.RFQ__r.Title__c;
            d.partNumber = q.RFQ__r.Part_Number__c;
            d.requiredQuantity = q.RFQ__r.Required_Quantity__c;
            d.dueDate = q.RFQ__r.Due_Date__c;
            d.category = q.RFQ__r.Category__c;
            d.rfqStatus = q.RFQ__r.Status__c;
            if (q.RFQ__r.Due_Date__c != null) {
                d.daysToDue = today.daysBetween(q.RFQ__r.Due_Date__c);
            }

            // カウント
            if (q.Status__c == '依頼中') {
                pending++;
            } else if (q.Status__c == '回答済') {
                answered++;
            } else {
                closed++;
            }

            // フィルタ適用
            Boolean include = false;
            if (f == 'all') include = true;
            else if (f == 'pending' && q.Status__c == '依頼中') include = true;
            else if (f == 'answered' && q.Status__c == '回答済') include = true;
            else if (f == 'closed' && (q.Status__c == '採用' || q.Status__c == '不採用' || q.Status__c == '辞退')) include = true;

            if (include) dto.items.add(d);
        }
        dto.totalCount = quotes.size();
        dto.pendingCount = pending;
        dto.answeredCount = answered;
        dto.closedCount = closed;
        return dto;
    }

    // =========================================================================
    // 品質調査一覧（supplierInvestigationList LWC用）
    // =========================================================================

    /**
     * 該当サプライヤーの調査レコード全件を返す。
     * フィルタ: 'all' | 'ongoing'(依頼中/調査中/対策実施中) | 'responded'(回答済) | 'completed'(完了)
     */
    @AuraEnabled(cacheable=true)
    public static InvestigationListDTO getInvestigationList(Id accountId, String filter) {
        Id supplierId = resolveSupplierId(accountId);
        if (supplierId == null) {
            throw new AuraHandledException('サプライヤーAccountが特定できません。');
        }
        String f = String.isBlank(filter) ? 'all' : filter;

        List<Supplier_Investigation__c> invs = [
            SELECT Id, Name, Status__c, Severity__c, Request_Detail__c,
                   Request_Date__c, Response_Due_Date__c, Response_Date__c,
                   BOM_Part__r.Part_Number__c, BOM_Part__r.Part_Name__c
            FROM Supplier_Investigation__c
            WHERE Supplier__c = :supplierId
            ORDER BY Response_Due_Date__c ASC NULLS LAST, CreatedDate DESC
            LIMIT 200
        ];

        InvestigationListDTO dto = new InvestigationListDTO();
        Date today = Date.today();
        Integer ongoing = 0, responded = 0, completed = 0;

        for (Supplier_Investigation__c i : invs) {
            InvestigationListItemDTO d = new InvestigationListItemDTO();
            d.investigationId = i.Id;
            d.name = i.Name;
            String sub = i.Request_Detail__c == null ? '' : i.Request_Detail__c;
            d.subject = sub.length() > 80 ? sub.substring(0, 80) + '…' : sub;
            d.status = i.Status__c;
            d.severity = i.Severity__c;
            d.responseDueDate = i.Response_Due_Date__c;
            if (i.Response_Due_Date__c != null) {
                d.daysToDue = today.daysBetween(i.Response_Due_Date__c);
            }

            // カウント
            if (i.Status__c == '完了') {
                completed++;
            } else if (i.Status__c == '回答済') {
                responded++;
            } else {
                ongoing++;
            }

            // フィルタ適用
            Boolean include = false;
            if (f == 'all') include = true;
            else if (f == 'ongoing' && (i.Status__c == '依頼中' || i.Status__c == '調査中' || i.Status__c == '対策実施中')) include = true;
            else if (f == 'responded' && i.Status__c == '回答済') include = true;
            else if (f == 'completed' && i.Status__c == '完了') include = true;

            if (include) dto.items.add(d);
        }
        dto.totalCount = invs.size();
        dto.ongoingCount = ongoing;
        dto.respondedCount = responded;
        dto.completedCount = completed;
        return dto;
    }

    // =========================================================================
    // DTO 定義
    // =========================================================================

    public class DashboardDTO {
        @AuraEnabled public SupplierHeaderDTO supplier;
        @AuraEnabled public ActionKpisDTO actionKpis;
        @AuraEnabled public List<StatusBreakdownDTO> rfqStatusBreakdown;
        @AuraEnabled public List<StatusBreakdownDTO> investigationStatusBreakdown;
        @AuraEnabled public List<CapacitySummaryDTO> capacitySummary;
        @AuraEnabled public List<CertificationDTO> certifications;
        @AuraEnabled public List<RfqListItemDTO> recentRfqs;
        @AuraEnabled public List<InvestigationListItemDTO> recentInvestigations;
    }

    public class RfqListDTO {
        @AuraEnabled public List<RfqListItemDTO> items = new List<RfqListItemDTO>();
        @AuraEnabled public Integer totalCount = 0;
        @AuraEnabled public Integer pendingCount = 0;
        @AuraEnabled public Integer answeredCount = 0;
        @AuraEnabled public Integer closedCount = 0;
    }

    public class InvestigationListDTO {
        @AuraEnabled public List<InvestigationListItemDTO> items = new List<InvestigationListItemDTO>();
        @AuraEnabled public Integer totalCount = 0;
        @AuraEnabled public Integer ongoingCount = 0;
        @AuraEnabled public Integer respondedCount = 0;
        @AuraEnabled public Integer completedCount = 0;
    }

    public class InvestigationListItemDTO {
        @AuraEnabled public Id investigationId;
        @AuraEnabled public String name;
        @AuraEnabled public String subject;
        @AuraEnabled public String status;
        @AuraEnabled public Date responseDueDate;
        @AuraEnabled public Integer daysToDue;
        @AuraEnabled public String severity;
    }

    public class SupplierHeaderDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String website;
    }

    public class ActionKpisDTO {
        @AuraEnabled public Integer unansweredRfqCount = 0;
        @AuraEnabled public Date unansweredRfqNearestDue;
        @AuraEnabled public Integer ongoingInvestigationCount = 0;
        @AuraEnabled public Date investigationNearestDue;
        @AuraEnabled public Integer expiringCertificationCount = 0;
        @AuraEnabled public Integer certNearestExpiryDays;
        @AuraEnabled public Integer outdatedCapacitySiteCount = 0;
        @AuraEnabled public Date capacityOldestUpdateDate;
    }

    public class StatusBreakdownDTO {
        @AuraEnabled public String status;
        @AuraEnabled public Integer count;
    }

    public class CapacitySummaryDTO {
        @AuraEnabled public Id siteId;
        @AuraEnabled public String siteName;
        @AuraEnabled public String prefecture;
        @AuraEnabled public Integer capacityEntryCount;
        @AuraEnabled public Decimal totalMonthlyCapacity;
        @AuraEnabled public Date earliestExpiryDate;
        @AuraEnabled public Boolean isExpiringSoon = false;
    }

    public class CertificationDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String type;
        @AuraEnabled public String certNumber;
        @AuraEnabled public String status;
        @AuraEnabled public Date expiryDate;
        @AuraEnabled public Integer daysToExpiry;
        @AuraEnabled public String issuingBody;
        @AuraEnabled public String certificateUrl;
    }

    public class RfqQuoteDetailDTO {
        // RFQ側
        @AuraEnabled public Id rfqId;
        @AuraEnabled public String rfqName;
        @AuraEnabled public String title;
        @AuraEnabled public String category;
        @AuraEnabled public String rfqStatus;
        @AuraEnabled public String partNumber;
        @AuraEnabled public String partSpec;
        @AuraEnabled public Decimal requiredQuantity;
        @AuraEnabled public Decimal targetUnitPrice;
        @AuraEnabled public Date dueDate;
        @AuraEnabled public Integer daysToDue;
        @AuraEnabled public String notes;
        @AuraEnabled public String bomPartName;
        // Quote側
        @AuraEnabled public Id quoteId;
        @AuraEnabled public String quoteStatus;
        @AuraEnabled public Decimal quoteUnitPrice;
        @AuraEnabled public Decimal quoteMoq;
        @AuraEnabled public Decimal quoteLeadTimeDays;
        @AuraEnabled public Date quoteValidUntil;
        @AuraEnabled public Id quoteManufacturingSiteId;
        @AuraEnabled public String quoteManufacturingSiteName;
        @AuraEnabled public Date quoteResponseDate;
        @AuraEnabled public String quoteNotes;
        // 補助
        @AuraEnabled public List<SiteOptionDTO> siteOptions = new List<SiteOptionDTO>();
        @AuraEnabled public Boolean isEditable = false;
    }

    public class CapacitySiteDTO {
        @AuraEnabled public Id siteId;
        @AuraEnabled public String siteName;
        @AuraEnabled public String prefecture;
        @AuraEnabled public Boolean isOwnSite;
        @AuraEnabled public Decimal totalMonthlyCapacity = 0;
        @AuraEnabled public Integer itemCount = 0;
        @AuraEnabled public Integer expiringCount = 0;
        @AuraEnabled public List<CapacityItemDTO> items = new List<CapacityItemDTO>();
    }

    public class CapacityItemDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public Id siteId;
        @AuraEnabled public String partNumber;
        @AuraEnabled public String partName;
        @AuraEnabled public Decimal monthlyCapacity;
        @AuraEnabled public Date effectiveFrom;
        @AuraEnabled public Date effectiveTo;
        @AuraEnabled public String notes;
        @AuraEnabled public Datetime lastModified;
        @AuraEnabled public Boolean isExpiringSoon = false;
    }

    public class SiteOptionDTO {
        @AuraEnabled public Id siteId;
        @AuraEnabled public String siteName;
    }

    public class RfqListItemDTO {
        @AuraEnabled public Id rfqId;
        @AuraEnabled public String rfqName;
        @AuraEnabled public String rfqTitle;
        @AuraEnabled public String rfqStatus;
        @AuraEnabled public String category;
        @AuraEnabled public String partNumber;
        @AuraEnabled public Decimal requiredQuantity;
        @AuraEnabled public Date dueDate;
        @AuraEnabled public Integer daysToDue;
        @AuraEnabled public Id quoteId;
        @AuraEnabled public String quoteStatus;
        @AuraEnabled public Decimal unitPrice;
    }

    // =========================================================================
    // サプライヤー調査回答（supplierInvestigationResponse LWC用）
    // =========================================================================

    /**
     * 単一のサプライヤー調査レコードを取得（読み取り領域+編集領域に分割）
     */
    @AuraEnabled(cacheable=true)
    public static InvestigationDTO getInvestigation(Id investigationId, Id accountId) {
        if (investigationId == null) {
            throw new AuraHandledException('調査IDが指定されていません。');
        }
        Id supplierId = resolveSupplierId(accountId);

        List<Supplier_Investigation__c> list1 = [
            SELECT Id, Name, Status__c, Severity__c,
                   Request_Date__c, Response_Due_Date__c, Response_Date__c,
                   Supplier_Contact__c, Request_Detail__c, Impact_Range__c,
                   Cause_Category__c, Root_Cause_by_Supplier__c, Action_Taken__c,
                   Recurrence_Prevention__c, Response_Detail__c, Evidence_Attachments__c,
                   Verification_Date__c, Verification_Result__c,
                   Supplier__c, Supplier__r.Name,
                   BOM_Part__c, BOM_Part__r.Part_Number__c, BOM_Part__r.Part_Name__c,
                   CreatedDate, LastModifiedDate
            FROM Supplier_Investigation__c
            WHERE Id = :investigationId
            LIMIT 1
        ];
        if (list1.isEmpty()) {
            throw new AuraHandledException('調査レコードが見つかりません。');
        }
        Supplier_Investigation__c si = list1[0];

        // デモ用: accountIdが指定された場合のみ所属サプライヤー整合性をチェック
        if (supplierId != null && si.Supplier__c != supplierId) {
            throw new AuraHandledException('このサプライヤーからアクセス可能な調査ではありません。');
        }

        InvestigationDTO dto = new InvestigationDTO();
        dto.id = si.Id;
        dto.name = si.Name;
        dto.status = si.Status__c;
        dto.severity = si.Severity__c;
        dto.requestDate = si.Request_Date__c;
        dto.responseDueDate = si.Response_Due_Date__c;
        dto.responseDate = si.Response_Date__c;
        dto.supplierContact = si.Supplier_Contact__c;
        dto.requestDetail = si.Request_Detail__c;
        dto.impactRange = si.Impact_Range__c;
        dto.causeCategory = si.Cause_Category__c;
        dto.rootCause = si.Root_Cause_by_Supplier__c;
        dto.actionTaken = si.Action_Taken__c;
        dto.recurrencePrevention = si.Recurrence_Prevention__c;
        dto.responseDetail = si.Response_Detail__c;
        dto.evidenceAttachments = si.Evidence_Attachments__c;
        dto.verificationDate = si.Verification_Date__c;
        dto.verificationResult = si.Verification_Result__c;
        dto.supplierName = si.Supplier__r != null ? si.Supplier__r.Name : null;
        if (si.BOM_Part__r != null) {
            dto.partNumber = si.BOM_Part__r.Part_Number__c;
            dto.partName = si.BOM_Part__r.Part_Name__c;
        }
        dto.createdDate = si.CreatedDate;
        dto.lastModifiedDate = si.LastModifiedDate;

        // 期限日数（回答期限 - 今日）
        if (si.Response_Due_Date__c != null) {
            dto.daysToDue = Date.today().daysBetween(si.Response_Due_Date__c);
        }

        // 編集可能判定: ステータスが「依頼中」「調査中」のときのみ編集可
        dto.editable = (si.Status__c == '依頼中' || si.Status__c == '調査中');
        // 完了/対策実施中/回答済は「回答ロック」
        dto.submitted = (si.Status__c == '回答済' || si.Status__c == '対策実施中' || si.Status__c == '完了');

        return dto;
    }

    /**
     * サプライヤー回答を下書き保存（ステータス維持）
     */
    @AuraEnabled
    public static void saveInvestigationDraft(
        Id investigationId,
        String causeCategory,
        String rootCause,
        String actionTaken,
        String recurrencePrevention,
        String responseDetail,
        String evidenceAttachments
    ) {
        if (investigationId == null) {
            throw new AuraHandledException('調査IDが指定されていません。');
        }
        Supplier_Investigation__c si = [
            SELECT Id, Status__c, Supplier__c
            FROM Supplier_Investigation__c
            WHERE Id = :investigationId
            LIMIT 1
        ];
        enforceQuoteOwnership(si.Supplier__c);
        if (si.Status__c != '依頼中' && si.Status__c != '調査中') {
            throw new AuraHandledException('このステータスでは編集できません。');
        }
        si.Cause_Category__c = causeCategory;
        si.Root_Cause_by_Supplier__c = rootCause;
        si.Action_Taken__c = actionTaken;
        si.Recurrence_Prevention__c = recurrencePrevention;
        si.Response_Detail__c = responseDetail;
        si.Evidence_Attachments__c = evidenceAttachments;
        // 依頼中→調査中に自動遷移
        if (si.Status__c == '依頼中') {
            si.Status__c = '調査中';
        }
        new ElevatedOps().updateInvestigation(si);
    }

    /**
     * サプライヤー回答を確定提出（ステータス=回答済、回答日=TODAY）
     */
    @AuraEnabled
    public static void submitInvestigation(
        Id investigationId,
        String causeCategory,
        String rootCause,
        String actionTaken,
        String recurrencePrevention,
        String responseDetail,
        String evidenceAttachments
    ) {
        if (investigationId == null) {
            throw new AuraHandledException('調査IDが指定されていません。');
        }
        // 必須項目バリデーション
        if (String.isBlank(causeCategory)) {
            throw new AuraHandledException('原因区分は必須です。');
        }
        if (String.isBlank(rootCause)) {
            throw new AuraHandledException('根本原因の記述は必須です。');
        }
        if (String.isBlank(actionTaken)) {
            throw new AuraHandledException('対策内容の記述は必須です。');
        }
        if (String.isBlank(recurrencePrevention)) {
            throw new AuraHandledException('再発防止策の記述は必須です。');
        }

        Supplier_Investigation__c si = [
            SELECT Id, Status__c, Supplier__c
            FROM Supplier_Investigation__c
            WHERE Id = :investigationId
            LIMIT 1
        ];
        enforceQuoteOwnership(si.Supplier__c);
        if (si.Status__c != '依頼中' && si.Status__c != '調査中') {
            throw new AuraHandledException('このステータスでは回答を提出できません。');
        }
        si.Cause_Category__c = causeCategory;
        si.Root_Cause_by_Supplier__c = rootCause;
        si.Action_Taken__c = actionTaken;
        si.Recurrence_Prevention__c = recurrencePrevention;
        si.Response_Detail__c = responseDetail;
        si.Evidence_Attachments__c = evidenceAttachments;
        si.Status__c = '回答済';
        si.Response_Date__c = Date.today();
        new ElevatedOps().updateInvestigation(si);
    }

    // =========================================================================
    // 製造拠点管理（manufacturingSiteManager LWC用）
    // =========================================================================

    @AuraEnabled(cacheable=true)
    public static SiteListDTO getManufacturingSites(Id accountId) {
        Id supplierId = resolveSupplierId(accountId);
        if (supplierId == null) {
            throw new AuraHandledException('サプライヤーAccountが特定できません。');
        }

        // 関連するキャパシティ件数を拠点別に集計（別クエリ）
        Map<Id, Integer> capacityCountBySite = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT Manufacturing_Site__c siteId, COUNT(Id) cnt
            FROM Supplier_Capacity__c
            WHERE Manufacturing_Site__r.Supplier__c = :supplierId
            GROUP BY Manufacturing_Site__c
        ]) {
            Id sid = (Id) ar.get('siteId');
            if (sid != null) {
                capacityCountBySite.put(sid, (Integer) ar.get('cnt'));
            }
        }

        List<Manufacturing_Site__c> sites = [
            SELECT Id, Name, Is_Own_Site__c, Prefecture__c, Address__c,
                   Latitude__c, Longitude__c, Description__c, LastModifiedDate
            FROM Manufacturing_Site__c
            WHERE Supplier__c = :supplierId
            ORDER BY Is_Own_Site__c DESC, Name ASC
        ];

        SiteListDTO result = new SiteListDTO();
        for (Manufacturing_Site__c s : sites) {
            SiteDTO d = new SiteDTO();
            d.id = s.Id;
            d.name = s.Name;
            d.isOwnSite = s.Is_Own_Site__c;
            d.prefecture = s.Prefecture__c;
            d.address = s.Address__c;
            d.latitude = s.Latitude__c;
            d.longitude = s.Longitude__c;
            d.description = s.Description__c;
            d.lastModified = s.LastModifiedDate;
            d.capacityItemCount = capacityCountBySite.containsKey(s.Id) ? capacityCountBySite.get(s.Id) : 0;
            result.items.add(d);
            result.totalCount++;
            if (s.Is_Own_Site__c) result.ownCount++;
            else result.subcontractorCount++;
        }
        return result;
    }

    @AuraEnabled
    public static Id saveManufacturingSite(
        Id id,
        Id accountId,
        String name,
        Boolean isOwnSite,
        String prefecture,
        String address,
        Decimal latitude,
        Decimal longitude,
        String description
    ) {
        if (String.isBlank(name)) {
            throw new AuraHandledException('拠点名は必須です。');
        }

        Manufacturing_Site__c s;
        if (id != null) {
            s = [SELECT Id, Supplier__c FROM Manufacturing_Site__c WHERE Id = :id LIMIT 1];
        } else {
            Id supplierId = resolveSupplierId(accountId);
            if (supplierId == null) {
                throw new AuraHandledException('サプライヤーAccountが特定できません。');
            }
            s = new Manufacturing_Site__c(Supplier__c = supplierId);
        }
        s.Name = name;
        s.Is_Own_Site__c = isOwnSite == null ? false : isOwnSite;
        s.Prefecture__c = prefecture;
        s.Address__c = address;
        s.Latitude__c = latitude;
        s.Longitude__c = longitude;
        s.Description__c = description;
        upsert s;
        return s.Id;
    }

    @AuraEnabled
    public static void deleteManufacturingSite(Id id) {
        if (id == null) {
            throw new AuraHandledException('IDが指定されていません。');
        }
        // キャパシティが紐づいている場合は削除不可
        Integer capCount = [SELECT COUNT() FROM Supplier_Capacity__c WHERE Manufacturing_Site__c = :id];
        if (capCount > 0) {
            throw new AuraHandledException('この拠点には ' + capCount + ' 件のキャパシティが登録されています。先にキャパシティを削除または他拠点へ移動してください。');
        }
        delete [SELECT Id FROM Manufacturing_Site__c WHERE Id = :id LIMIT 1];
    }

    public class SiteListDTO {
        @AuraEnabled public List<SiteDTO> items = new List<SiteDTO>();
        @AuraEnabled public Integer totalCount = 0;
        @AuraEnabled public Integer ownCount = 0;
        @AuraEnabled public Integer subcontractorCount = 0;
    }

    public class SiteDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public Boolean isOwnSite;
        @AuraEnabled public String prefecture;
        @AuraEnabled public String address;
        @AuraEnabled public Decimal latitude;
        @AuraEnabled public Decimal longitude;
        @AuraEnabled public String description;
        @AuraEnabled public Integer capacityItemCount;
        @AuraEnabled public Datetime lastModified;
    }

    // =========================================================================
    // サプライヤー認証一覧（supplierCertificationList LWC用）
    // =========================================================================

    @AuraEnabled(cacheable=true)
    public static CertListDTO getCertifications(Id accountId) {
        Id supplierId = resolveSupplierId(accountId);
        if (supplierId == null) {
            throw new AuraHandledException('サプライヤーAccountが特定できません。');
        }

        List<Supplier_Certification__c> certs = [
            SELECT Id, Name, Certification_Type__c, Status__c,
                   Issuing_Body__c, Issue_Date__c, Expiry_Date__c,
                   Last_Surveillance_Date__c, Next_Surveillance_Date__c,
                   Scope__c, Notes__c, LastModifiedDate
            FROM Supplier_Certification__c
            WHERE Supplier__c = :supplierId
            ORDER BY Expiry_Date__c ASC NULLS LAST
        ];

        Date today = Date.today();
        Date warnThreshold = today.addDays(CERT_EXPIRY_WARNING_DAYS);

        CertListDTO result = new CertListDTO();
        for (Supplier_Certification__c c : certs) {
            CertDTO d = new CertDTO();
            d.id = c.Id;
            d.name = c.Name;
            d.certType = c.Certification_Type__c;
            d.status = c.Status__c;
            d.issuingBody = c.Issuing_Body__c;
            d.issueDate = c.Issue_Date__c;
            d.expiryDate = c.Expiry_Date__c;
            d.lastSurveillanceDate = c.Last_Surveillance_Date__c;
            d.nextSurveillanceDate = c.Next_Surveillance_Date__c;
            d.scope = c.Scope__c;
            d.notes = c.Notes__c;
            d.lastModified = c.LastModifiedDate;

            // 派生フラグ
            if (c.Expiry_Date__c != null) {
                d.daysToExpiry = today.daysBetween(c.Expiry_Date__c);
                if (c.Expiry_Date__c < today) {
                    d.derivedStatus = 'EXPIRED';
                } else if (c.Expiry_Date__c <= warnThreshold) {
                    d.derivedStatus = 'EXPIRING_SOON';
                } else {
                    d.derivedStatus = 'VALID';
                }
            } else {
                d.derivedStatus = 'UNKNOWN';
            }

            result.items.add(d);

            if (d.derivedStatus == 'VALID') result.validCount++;
            else if (d.derivedStatus == 'EXPIRING_SOON') result.expiringCount++;
            else if (d.derivedStatus == 'EXPIRED') result.expiredCount++;
        }
        result.totalCount = result.items.size();
        return result;
    }

    @AuraEnabled
    public static Id saveCertification(
        Id id,
        Id accountId,
        String certType,
        String status,
        String issuingBody,
        Date issueDate,
        Date expiryDate,
        Date lastSurveillanceDate,
        Date nextSurveillanceDate,
        String scope,
        String notes
    ) {
        if (String.isBlank(certType)) {
            throw new AuraHandledException('認証種別は必須です。');
        }
        if (String.isBlank(issuingBody)) {
            throw new AuraHandledException('認証機関は必須です。');
        }
        if (expiryDate == null) {
            throw new AuraHandledException('有効期限は必須です。');
        }

        Supplier_Certification__c c;
        if (id != null) {
            c = [SELECT Id, Supplier__c FROM Supplier_Certification__c WHERE Id = :id LIMIT 1];
        } else {
            Id supplierId = resolveSupplierId(accountId);
            if (supplierId == null) {
                throw new AuraHandledException('サプライヤーAccountが特定できません。');
            }
            c = new Supplier_Certification__c(Supplier__c = supplierId);
        }
        c.Certification_Type__c = certType;
        c.Status__c = String.isBlank(status) ? '有効' : status;
        c.Issuing_Body__c = issuingBody;
        c.Issue_Date__c = issueDate;
        c.Expiry_Date__c = expiryDate;
        c.Last_Surveillance_Date__c = lastSurveillanceDate;
        c.Next_Surveillance_Date__c = nextSurveillanceDate;
        c.Scope__c = scope;
        c.Notes__c = notes;
        upsert c;
        return c.Id;
    }

    @AuraEnabled
    public static void deleteCertification(Id id) {
        if (id == null) {
            throw new AuraHandledException('IDが指定されていません。');
        }
        delete [SELECT Id FROM Supplier_Certification__c WHERE Id = :id LIMIT 1];
    }

    public class CertListDTO {
        @AuraEnabled public List<CertDTO> items = new List<CertDTO>();
        @AuraEnabled public Integer totalCount = 0;
        @AuraEnabled public Integer validCount = 0;
        @AuraEnabled public Integer expiringCount = 0;
        @AuraEnabled public Integer expiredCount = 0;
    }

    public class CertDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String certType;
        @AuraEnabled public String status;
        @AuraEnabled public String issuingBody;
        @AuraEnabled public Date issueDate;
        @AuraEnabled public Date expiryDate;
        @AuraEnabled public Integer daysToExpiry;
        @AuraEnabled public Date lastSurveillanceDate;
        @AuraEnabled public Date nextSurveillanceDate;
        @AuraEnabled public String scope;
        @AuraEnabled public String notes;
        @AuraEnabled public Datetime lastModified;
        @AuraEnabled public String derivedStatus; // VALID / EXPIRING_SOON / EXPIRED / UNKNOWN
    }

    public class InvestigationDTO {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String status;
        @AuraEnabled public String severity;
        @AuraEnabled public Date requestDate;
        @AuraEnabled public Date responseDueDate;
        @AuraEnabled public Date responseDate;
        @AuraEnabled public Integer daysToDue;
        @AuraEnabled public String supplierName;
        @AuraEnabled public String supplierContact;
        @AuraEnabled public String partNumber;
        @AuraEnabled public String partName;
        @AuraEnabled public String requestDetail;
        @AuraEnabled public String impactRange;
        @AuraEnabled public String causeCategory;
        @AuraEnabled public String rootCause;
        @AuraEnabled public String actionTaken;
        @AuraEnabled public String recurrencePrevention;
        @AuraEnabled public String responseDetail;
        @AuraEnabled public String evidenceAttachments;
        @AuraEnabled public Date verificationDate;
        @AuraEnabled public String verificationResult;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public Datetime lastModifiedDate;
        @AuraEnabled public Boolean editable = false;
        @AuraEnabled public Boolean submitted = false;
    }
}
