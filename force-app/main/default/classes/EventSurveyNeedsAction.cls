public with sharing class EventSurveyNeedsAction {

    @InvocableMethod(label='イベントアンケートニーズ抽出' description='イベントアンケートをRAG分析し、取引先ごとにニーズカードを自動生成する')
    public static List<AnalysisResult> analyzeEventSurvey(List<AnalysisInput> inputs) {
        List<AnalysisResult> results = new List<AnalysisResult>();
        for (AnalysisInput input : inputs) {
            if (input.campaignId != null) {
                results.add(processByCampaign(input.campaignId));
            } else if (String.isNotBlank(input.searchQuery)) {
                results.add(processBySearchQuery(input.searchQuery));
            }
        }
        return results;
    }

    public class AnalysisInput {
        @InvocableVariable(label='キャンペーンID')
        public Id campaignId;
        @InvocableVariable(label='検索クエリ（取引先名またはイベント名）')
        public String searchQuery;
    }

    public class AnalysisResult {
        @InvocableVariable(label='結果メッセージ')
        public String resultMessage;
        @InvocableVariable(label='新規作成数')
        public Integer createdCount;
        @InvocableVariable(label='スキップ数')
        public Integer skippedCount;
        @InvocableVariable(label='エラー')
        public String errorMessage;
        @InvocableVariable(label='LLMレスポンス')
        public String rawResponse;
    }

    // === キャンペーンID指定: 取引先ごとに分析 ===
    private static AnalysisResult processByCampaign(Id campaignId) {
        AnalysisResult result = new AnalysisResult();
        result.createdCount = 0;
        result.skippedCount = 0;

        try {
            Campaign campaign = [
                SELECT Id, Name FROM Campaign WHERE Id = :campaignId LIMIT 1
            ];

            // 1. アンケート回答者のメールアドレスに一致するContactを取得 → Account特定
            //    Contact.Email でマッチするAccountグループを構築
            Map<Id, AccountSurveyGroup> accountGroups = buildAccountGroups();

            if (accountGroups.isEmpty()) {
                result.resultMessage = 'アンケート回答者に一致する取引先が見つかりませんでした。';
                return result;
            }

            // 2. 全取引先のデータ取得 + LLM呼び出し（callout phase: DMLより前に実行）
            List<PendingNeedsCards> allPending = new List<PendingNeedsCards>();
            for (AccountSurveyGroup acctGroup : accountGroups.values()) {
                try {
                    String surveyData = getSurveyDataForAccount(acctGroup, campaign.Name);
                    if (String.isBlank(surveyData)) continue;
                    String llmResponse = callAccountNeedsTemplate(surveyData);
                    PendingNeedsCards pending = new PendingNeedsCards();
                    pending.accountId = acctGroup.accountId;
                    pending.sourceType = acctGroup.sourceType;
                    pending.llmResponse = llmResponse;
                    allPending.add(pending);
                } catch (Exception e) {
                    System.debug(LoggingLevel.ERROR, '取引先 ' + acctGroup.accountName + ' 分析エラー: ' + e.getMessage());
                }
            }

            // 3. DML phase: 全取引先のニーズカードをまとめて作成
            for (PendingNeedsCards pending : allPending) {
                processLLMResponseSimple(pending.llmResponse, pending.accountId, pending.sourceType, result);
            }

            result.resultMessage = 'キャンペーン「' + campaign.Name + '」の分析完了: '
                + accountGroups.size() + '取引先を分析、'
                + result.createdCount + '件ニーズカード作成、'
                + result.skippedCount + '件スキップ';

        } catch (Exception e) {
            result.errorMessage = e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString();
        }
        return result;
    }

    // === 検索クエリ指定（後方互換） ===
    private static AnalysisResult processBySearchQuery(String searchQuery) {
        AnalysisResult result = new AnalysisResult();
        result.createdCount = 0;
        result.skippedCount = 0;

        try {
            String llmResponse = callPromptTemplate(searchQuery);
            result.rawResponse = llmResponse;
            processLLMResponseSimple(llmResponse, null, 'イベントアンケート（新規）', result);

            Integer total = result.createdCount + result.skippedCount;
            result.resultMessage = '分析完了: ' + result.createdCount + '件ニーズカード作成、'
                + result.skippedCount + '件スキップ（計' + total + '件検出）';
        } catch (Exception e) {
            result.errorMessage = e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString();
        }
        return result;
    }

    // === 取引先グループの構築（アンケート回答者起点） ===
    private static Map<Id, AccountSurveyGroup> buildAccountGroups() {
        Map<Id, AccountSurveyGroup> groups = new Map<Id, AccountSurveyGroup>();

        // 1. Data Cloud EventSurvey DMO からアンケート回答者のメール一覧を取得
        Set<String> surveyEmails = getSurveyAttendeeEmails();
        if (surveyEmails.isEmpty()) return groups;

        // 2. アンケート回答者のメールドメインを抽出
        Set<String> surveyDomains = new Set<String>();
        for (String email : surveyEmails) {
            if (email.contains('@')) {
                surveyDomains.add(email.substringAfter('@').toLowerCase());
            }
        }

        // 3. メール完全一致: Contact.Email がアンケート回答者と一致 → 「既存担当者」
        List<Contact> matchedContacts = [
            SELECT Id, Email, AccountId, Account.Name
            FROM Contact
            WHERE Email IN :surveyEmails
              AND AccountId != null
        ];

        Set<Id> matchedAccountIds = new Set<Id>();
        for (Contact c : matchedContacts) {
            Id acctId = c.AccountId;
            matchedAccountIds.add(acctId);
            if (!groups.containsKey(acctId)) {
                AccountSurveyGroup g = new AccountSurveyGroup();
                g.accountId = acctId;
                g.accountName = c.Account.Name;
                g.sourceType = 'イベントアンケート（既存担当者）';
                g.respondentEmails = new Set<String>();
                groups.put(acctId, g);
            }
            groups.get(acctId).respondentEmails.add(c.Email.toLowerCase());
        }

        // 4. ドメインマッチ: Contact未登録だがAccount.Email_Domain__cがアンケートドメインと一致 → 「既存顧客・未登録者」
        List<Account> domainMatchAccounts = [
            SELECT Id, Name, Email_Domain__c
            FROM Account
            WHERE Email_Domain__c IN :surveyDomains
              AND Id NOT IN :matchedAccountIds
        ];
        for (Account a : domainMatchAccounts) {
            AccountSurveyGroup g = new AccountSurveyGroup();
            g.accountId = a.Id;
            g.accountName = a.Name;
            g.sourceType = 'イベントアンケート（既存顧客・未登録者）';
            g.respondentEmails = new Set<String>();
            g.emailDomain = a.Email_Domain__c.toLowerCase();
            groups.put(a.Id, g);
        }

        return groups;
    }

    // === Data Cloud EventSurvey DMO からアンケート回答者メール一覧を取得 ===
    private static Set<String> getSurveyAttendeeEmails() {
        Set<String> emails = new Set<String>();
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(Url.getOrgDomainUrl().toExternalForm()
                + '/services/data/v62.0/ssot/queryv2');
            req.setMethod('POST');
            req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
            req.setHeader('Content-Type', 'application/json');
            req.setBody('{"sql":"SELECT attendee_email__c FROM EventSurvey__dlm WHERE attendee_email__c IS NOT NULL LIMIT 200"}');

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() == 200 || res.getStatusCode() == 201) {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                List<Object> data = (List<Object>) parsed.get('data');
                if (data != null) {
                    for (Object row : data) {
                        List<Object> rowData = (List<Object>) row;
                        if (rowData != null && !rowData.isEmpty() && rowData[0] != null) {
                            String email = String.valueOf(rowData[0]).toLowerCase().trim();
                            if (String.isNotBlank(email)) {
                                emails.add(email);
                            }
                        }
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Data Cloud クエリエラー: ' + e.getMessage());
        }
        return emails;
    }

    // === Data Cloud から取引先のアンケート回答データを取得 ===
    private static String getSurveyDataForAccount(AccountSurveyGroup acctGroup, String eventName) {
        // メールアドレスまたはドメインで絞り込み
        String whereClause;
        if (!acctGroup.respondentEmails.isEmpty()) {
            List<String> emailList = new List<String>(acctGroup.respondentEmails);
            List<String> quoted = new List<String>();
            for (String e : emailList) {
                quoted.add('\'' + String.escapeSingleQuotes(e) + '\'');
            }
            whereClause = 'LOWER(attendee_email__c) IN (' + String.join(quoted, ',') + ')';
        } else if (String.isNotBlank(acctGroup.emailDomain)) {
            whereClause = 'LOWER(attendee_email__c) LIKE \'%@' + String.escapeSingleQuotes(acctGroup.emailDomain) + '\'';
        } else {
            return null;
        }

        String sql = 'SELECT attendee_name__c, attendee_email__c, company_name__c, '
            + 'interest_area__c, pain_points__c, product_interest__c, comments__c, '
            + 'follow_up_requested__c, event_name__c '
            + 'FROM EventSurvey__dlm WHERE ' + whereClause + ' LIMIT 50';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(Url.getOrgDomainUrl().toExternalForm() + '/services/data/v62.0/ssot/queryv2');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
        req.setHeader('Content-Type', 'application/json');
        req.setBody('{"sql":"' + sql.replace('"', '\\"') + '"}');

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) return null;

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        List<Object> data = (List<Object>) parsed.get('data');
        if (data == null || data.isEmpty()) return null;

        // テキスト形式に整形
        String result = '取引先名: ' + acctGroup.accountName + '\n';
        result += 'イベント名: ' + eventName + '\n';
        result += '回答者数: ' + data.size() + '名\n\n';

        List<String> fields = new List<String>{
            'attendee_name', 'attendee_email', 'company_name',
            'interest_area', 'pain_points', 'product_interest', 'comments', 'follow_up_requested', 'event_name'
        };

        Integer idx = 1;
        for (Object row : data) {
            List<Object> rowData = (List<Object>) row;
            result += '--- 回答者' + idx + ' ---\n';
            result += '氏名: ' + safeStr(rowData, 0) + '\n';
            result += 'メール: ' + safeStr(rowData, 1) + '\n';
            result += '会社名: ' + safeStr(rowData, 2) + '\n';
            result += '関心分野: ' + safeStr(rowData, 3) + '\n';
            result += '課題・悩み: ' + safeStr(rowData, 4) + '\n';
            result += '興味のある製品: ' + safeStr(rowData, 5) + '\n';
            result += 'コメント: ' + safeStr(rowData, 6) + '\n';
            result += 'フォローアップ希望: ' + safeStr(rowData, 7) + '\n\n';
            idx++;
        }
        return result;
    }

    private static String safeStr(List<Object> rowData, Integer idx) {
        if (rowData == null || idx >= rowData.size() || rowData[idx] == null) return '（なし）';
        return String.valueOf(rowData[idx]);
    }

    // === 取引先別ニーズ抽出 Prompt Template 呼び出し（Retriever不使用） ===
    private static String callAccountNeedsTemplate(String accountSurveyData) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;

        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
        wv.value = accountSurveyData;
        inputParams.put('Input:accountSurveyData', wv);
        input.inputParams = inputParams;

        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptBuilderPreview';
        input.additionalConfig.temperature = 0.2;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                'EventSurveyAccountNeeds', input
            );

        if (response.generations == null || response.generations.isEmpty()) {
            throw new EventSurveyException('Prompt Templateからの応答が空です。');
        }

        return ((ConnectApi.EinsteinLLMGenerationItemOutput) response.generations[0]).text;
    }

    // === Retriever使用 Prompt Template 呼び出し（後方互換・searchQuery指定時） ===
    private static String callPromptTemplate(String searchQuery) {
        ConnectApi.EinsteinPromptTemplateGenerationsInput input = new ConnectApi.EinsteinPromptTemplateGenerationsInput();
        input.isPreview = false;

        Map<String, ConnectApi.WrappedValue> inputParams = new Map<String, ConnectApi.WrappedValue>();
        ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
        wv.value = searchQuery;
        inputParams.put('Input:searchQuery', wv);
        input.inputParams = inputParams;

        input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
        input.additionalConfig.applicationName = 'PromptBuilderPreview';
        input.additionalConfig.temperature = 0.2;

        ConnectApi.EinsteinPromptTemplateGenerationsRepresentation response =
            ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                'EventSurveyAnalysis', input
            );

        if (response.generations == null || response.generations.isEmpty()) {
            throw new EventSurveyException('Prompt Templateからの応答が空です。');
        }

        return ((ConnectApi.EinsteinLLMGenerationItemOutput) response.generations[0]).text;
    }

    // === LLMレスポンス解析 → ニーズカード作成（取引先ID・ソース種別は外部から指定） ===
    private static void processLLMResponseSimple(String llmResponse, Id accountId, String sourceType, AnalysisResult result) {
        String jsonStr = extractJsonFromResponse(llmResponse);
        if (jsonStr == null) return;

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
        String eventName = (String) parsed.get('event_name');
        List<Object> suggestedCards = (List<Object>) parsed.get('suggested_needs_cards');

        if (suggestedCards == null || suggestedCards.isEmpty()) return;

        // accountIdがnullの場合、LLMのaccount_nameから解決を試みる（後方互換）
        if (accountId == null) {
            String accountName = (String) parsed.get('account_name');
            accountId = resolveAccountId(accountName);
        }

        // 優先度調整
        String adjustedSourceType = sourceType;
        if (adjustedSourceType == null) {
            adjustedSourceType = 'イベントアンケート（新規）';
        }

        List<Needs_Card__c> toUpsert = new List<Needs_Card__c>();

        for (Object sc : suggestedCards) {
            Map<String, Object> card = (Map<String, Object>) sc;
            String title = (String) card.get('title');
            String needType = mapNeedType((String) card.get('need_type'));
            String priority = adjustPriority((String) card.get('priority'), adjustedSourceType);
            String customerVoice = (String) card.get('customer_voice');
            String description = (String) card.get('description');
            String status = determineStatus(adjustedSourceType);

            String sourceSurveyId = generateSourceKey(eventName, title, accountId);

            Needs_Card__c nc = new Needs_Card__c();
            nc.Source_Survey_Id__c = sourceSurveyId;
            nc.Title__c = truncate(title, 255);
            nc.Need_Type__c = needType;
            nc.Priority__c = priority;
            nc.Customer_Voice__c = customerVoice;
            nc.Description__c = description
                + '\n\n【ソース】イベントアンケート: ' + (eventName != null ? eventName : '不明')
                + '\n【ソース種別】' + adjustedSourceType;
            nc.Status__c = status;
            nc.Source_Type__c = adjustedSourceType;

            if (accountId != null) {
                nc.Account__c = accountId;
            }

            toUpsert.add(nc);
        }

        if (!toUpsert.isEmpty()) {
            Schema.SObjectField externalIdField = Needs_Card__c.Source_Survey_Id__c;
            List<Database.UpsertResult> upsertResults = Database.upsert(toUpsert, externalIdField, false);
            for (Database.UpsertResult ur : upsertResults) {
                if (ur.isSuccess()) {
                    result.createdCount++;
                } else {
                    result.skippedCount++;
                }
            }
        }
    }

    // === ヘルパークラス ===
    private class PendingNeedsCards {
        Id accountId;
        String sourceType;
        String llmResponse;
    }

    private class AccountSurveyGroup {
        Id accountId;
        String accountName;
        String sourceType;
        Set<String> respondentEmails;
        String emailDomain;
    }

    private static Id resolveAccountId(String accountName) {
        if (String.isBlank(accountName)) return null;
        List<Account> accts = [SELECT Id FROM Account WHERE Name = :accountName LIMIT 1];
        if (!accts.isEmpty()) return accts[0].Id;
        String likeName = '%' + accountName + '%';
        accts = [SELECT Id FROM Account WHERE Name LIKE :likeName LIMIT 1];
        return accts.isEmpty() ? null : accts[0].Id;
    }

    private static String adjustPriority(String llmPriority, String sourceType) {
        if (sourceType == 'イベントアンケート（新規）') {
            if (llmPriority == '高') return '中';
            if (llmPriority == '中') return '低';
        }
        return llmPriority;
    }

    private static String determineStatus(String sourceType) {
        if (sourceType == 'イベントアンケート（既存担当者）') {
            return '新規';
        }
        return '確認済';
    }

    private static String mapNeedType(String llmNeedType) {
        Map<String, String> typeMap = new Map<String, String>{
            '製品ニーズ' => '製品ニーズ',
            '技術ニーズ' => '製品ニーズ',
            '業務改善ニーズ' => '改善要望',
            'コンサルニーズ' => 'サービスニーズ',
            'サービスニーズ' => 'サービスニーズ',
            '改善要望' => '改善要望',
            '新規案件' => '新規案件'
        };
        String mapped = typeMap.get(llmNeedType);
        return mapped != null ? mapped : '製品ニーズ';
    }

    private static String generateSourceKey(String eventName, String title, Id accountId) {
        String raw = (eventName != null ? eventName : '') + '__'
            + (accountId != null ? String.valueOf(accountId) : '') + '__'
            + (title != null ? title : '');
        Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(raw));
        return EncodingUtil.convertToHex(digest).substring(0, 40);
    }

    private static String truncate(String text, Integer maxLength) {
        if (text == null) return null;
        return text.length() > maxLength ? text.substring(0, maxLength) : text;
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
        Integer braceStart = response.indexOf('{');
        Integer braceEnd = response.lastIndexOf('}');
        if (braceStart >= 0 && braceEnd > braceStart) {
            return response.substring(braceStart, braceEnd + 1);
        }
        return null;
    }

    public class EventSurveyException extends Exception {}
}
