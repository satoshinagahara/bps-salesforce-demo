public with sharing class OpportunitySummaryBatch implements Database.Batchable<SObject>, Database.AllowsCallouts {

    // サマリカード未生成 or 更新が必要な商談を対象
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Name, StageName, Amount, CurrencyIsoCode, CloseDate, Type,
                   Description, LeadSource, IsClosed, IsWon,
                   Account.Name, Account.Industry, Account.BillingState, Account.NumberOfEmployees,
                   (SELECT Product2.Name, Product2.Family, Quantity FROM OpportunityLineItems),
                   (SELECT Subject, Status, ActivityDate, Description FROM Tasks ORDER BY ActivityDate LIMIT 20),
                   (SELECT Subject, StartDateTime, Description FROM Events ORDER BY StartDateTime LIMIT 10)
            FROM Opportunity
            WHERE Id NOT IN (SELECT Opportunity__c FROM Opportunity_Summary__c WHERE Opportunity__c != null)
              AND StageName NOT IN ('Closed Lost')
              AND StageName != null
            ORDER BY LastModifiedDate DESC
        ]);
    }

    public void execute(Database.BatchableContext bc, List<Opportunity> opps) {
        // 面談記録を一括取得（カスタムLookupのためサブクエリ不可）
        Set<Id> oppIds = new Set<Id>();
        for (Opportunity opp : opps) {
            oppIds.add(opp.Id);
        }
        Map<Id, List<Meeting_Record__c>> meetingsByOpp = new Map<Id, List<Meeting_Record__c>>();
        for (Meeting_Record__c mr : [
            SELECT Opportunity__c, Meeting_Date__c, Meeting_Type__c, Participants__c, Summary__c
            FROM Meeting_Record__c
            WHERE Opportunity__c IN :oppIds
            ORDER BY Meeting_Date__c DESC
            LIMIT 50
        ]) {
            if (!meetingsByOpp.containsKey(mr.Opportunity__c)) {
                meetingsByOpp.put(mr.Opportunity__c, new List<Meeting_Record__c>());
            }
            meetingsByOpp.get(mr.Opportunity__c).add(mr);
        }

        for (Opportunity opp : opps) {
            try {
                List<Meeting_Record__c> meetings = meetingsByOpp.get(opp.Id);
                Integer meetingCount = meetings != null ? meetings.size() : 0;
                Integer taskCount = opp.Tasks != null ? opp.Tasks.size() : 0;
                Integer eventCount = opp.Events != null ? opp.Events.size() : 0;
                Integer totalActivity = taskCount + eventCount + meetingCount;

                // 信頼度3未満相当（Description無し or 活動+面談が2件未満）はスキップ
                if (String.isBlank(opp.Description) || totalActivity < 2) {
                    System.debug('スキップ（データ不足）: ' + opp.Name +
                        ' [Desc:' + (String.isNotBlank(opp.Description) ? 'Y' : 'N') +
                        ' Activity:' + totalActivity + ']');
                    continue;
                }

                generateSummaryCard(opp, meetings);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'サマリカード生成エラー [' + opp.Name + ']: ' + e.getMessage());
            }
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('OpportunitySummaryBatch 完了');
    }

    private void generateSummaryCard(Opportunity opp, List<Meeting_Record__c> meetings) {
        // 1. 信頼度関連データの計算
        Integer productCount = opp.OpportunityLineItems != null ? opp.OpportunityLineItems.size() : 0;
        Integer taskCount = opp.Tasks != null ? opp.Tasks.size() : 0;
        Integer eventCount = opp.Events != null ? opp.Events.size() : 0;
        Integer activityCount = taskCount + eventCount;
        Boolean hasDescription = String.isNotBlank(opp.Description);

        // 信頼度スコア計算（0-9）= データ充実度(0-3) × フェーズ係数(1-3)
        Integer meetingCount = meetings != null ? meetings.size() : 0;
        Integer totalActivity = activityCount + meetingCount;

        // データ充実度: 0=Descなし / 1=Descのみ / 2=Desc+(商品or活動) / 3=Desc+商品+活動
        Integer dataRichness = 0;
        if (hasDescription) dataRichness = 1;
        if (hasDescription && (productCount > 0 || totalActivity > 0)) dataRichness = 2;
        if (hasDescription && productCount > 0 && totalActivity > 0) dataRichness = 3;

        // フェーズ係数: 1=初期 / 2=提案中 / 3=交渉・完了
        Integer phaseCoeff = getPhaseCoefficient(opp.StageName);

        Integer score = dataRichness * phaseCoeff;

        // 2. LLM用の入力テキストを構築
        String inputText = buildInputText(opp, productCount, activityCount, meetings);

        // 3. Prompt TemplateでサマリカードJSON生成
        String summaryJson = callSummaryPromptTemplate(inputText);
        if (summaryJson == null) return;

        // 4. JSONパース → Opportunity_Summary__c に保存
        saveSummaryCard(opp, summaryJson, score, productCount, activityCount, hasDescription);
    }

    private Integer getPhaseCoefficient(String stageName) {
        if (stageName == null) return 1;
        // 交渉・完了フェーズ
        if (stageName == 'Negotiation' || stageName == 'Closed Won' || stageName == 'Closed Lost') return 3;
        // 提案・DW系フェーズ
        if (stageName.startsWith('Proposal') || stageName.startsWith('DW_')) return 2;
        // 初期フェーズ（Discovery, Qualification等）
        return 1;
    }

    private String buildInputText(Opportunity opp, Integer productCount, Integer activityCount, List<Meeting_Record__c> meetings) {
        String text = '';
        text += '商談名: ' + opp.Name + '\n';
        text += 'フェーズ: ' + opp.StageName + '\n';
        text += '金額: ' + (opp.Amount != null ? String.valueOf(opp.Amount) : '未設定') + '\n';
        text += '種別: ' + (opp.Type != null ? opp.Type : '未設定') + '\n';
        text += '説明: ' + (opp.Description != null ? opp.Description : '') + '\n';
        text += 'アカウント: ' + opp.Account.Name + '\n';
        text += '業種: ' + (opp.Account.Industry != null ? opp.Account.Industry : '未設定') + '\n';

        // 商品
        if (opp.OpportunityLineItems != null && !opp.OpportunityLineItems.isEmpty()) {
            text += '商品:\n';
            for (OpportunityLineItem oli : opp.OpportunityLineItems) {
                text += '  - ' + oli.Product2.Name;
                if (oli.Product2.Family != null) text += ' (' + oli.Product2.Family + ')';
                text += ' x' + String.valueOf(oli.Quantity.intValue()) + '\n';
            }
        }

        // 活動（Task）
        if (opp.Tasks != null && !opp.Tasks.isEmpty()) {
            text += '活動:\n';
            for (Task t : opp.Tasks) {
                if (t.Subject != null && !t.Subject.startsWith('Test')) {
                    String detail = t.Description != null ? ': ' + t.Description.left(100) : '';
                    text += '  - [' + t.Status + '] ' + t.Subject + detail + '\n';
                }
            }
        }

        // 行動（Event）
        if (opp.Events != null && !opp.Events.isEmpty()) {
            text += '行動:\n';
            for (Event e : opp.Events) {
                String detail = e.Description != null ? ': ' + e.Description.left(100) : '';
                text += '  - ' + e.Subject + detail + '\n';
            }
        }

        // 面談記録（Meeting_Record__c）
        if (meetings != null && !meetings.isEmpty()) {
            text += '面談記録:\n';
            for (Meeting_Record__c mr : meetings) {
                text += '  [' + String.valueOf(mr.Meeting_Date__c) + ' ' +
                        (mr.Meeting_Type__c != null ? mr.Meeting_Type__c : '') + ']\n';
                if (mr.Participants__c != null) {
                    text += '  参加者: ' + mr.Participants__c.left(200) + '\n';
                }
                if (mr.Summary__c != null) {
                    text += '  内容: ' + mr.Summary__c.left(1000) + '\n';
                }
                text += '\n';
            }
        }

        return text;
    }

    private String callSummaryPromptTemplate(String inputText) {
        try {
            ConnectApi.EinsteinPromptTemplateGenerationsInput input =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();
            input.isPreview = false;
            input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            input.additionalConfig.applicationName = 'PromptBuilderPreview';
            input.additionalConfig.numGenerations = 1;
            input.additionalConfig.temperature = 0.2;

            Map<String, ConnectApi.WrappedValue> inputParams =
                new Map<String, ConnectApi.WrappedValue>();
            ConnectApi.WrappedValue wv = new ConnectApi.WrappedValue();
            wv.value = inputText;
            inputParams.put('Input:opportunityData', wv);
            input.inputParams = inputParams;

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation result =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                    'OpportunitySummaryGeneration', input);

            return result.generations[0].text;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Prompt Template呼び出しエラー: ' + e.getMessage());
            return null;
        }
    }

    private void saveSummaryCard(Opportunity opp, String summaryJson, Integer score,
                                  Integer productCount, Integer activityCount, Boolean hasDescription) {
        try {
            // JSONクリーニング（LLMがコードブロックで囲む場合の対応）
            String cleaned = summaryJson.trim();
            if (cleaned.startsWith('```')) {
                cleaned = cleaned.replaceAll('(?s)^```json?\\s*', '').replaceAll('(?s)\\s*```$', '');
            }

            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(cleaned);

            Opportunity_Summary__c card = new Opportunity_Summary__c();
            card.Opportunity__c = opp.Id;
            card.Deal_Type__c = (String) parsed.get('dealType');
            card.Customer_Segment__c = (String) parsed.get('customerSegment');
            card.Deal_Scale__c = (String) parsed.get('dealScale');
            card.Sales_Motion__c = (String) parsed.get('salesMotion');
            card.Decision_Complexity__c = (String) parsed.get('decisionComplexity');
            card.Competitive_Situation__c = (String) parsed.get('competitiveSituation');
            card.Urgency_Driver__c = (String) parsed.get('urgencyDriver');
            card.Sales_Process_Pattern__c = (String) parsed.get('salesProcessPattern');
            card.Engagement_Depth__c = (String) parsed.get('engagementDepth');
            card.Customer_Challenge__c = (String) parsed.get('customerChallenge');
            card.Our_Value_Proposition__c = (String) parsed.get('ourValueProposition');
            card.Deal_Narrative__c = (String) parsed.get('dealNarrative');
            card.Key_Risks__c = (String) parsed.get('keyRisks');
            card.Lessons_Or_Insights__c = (String) parsed.get('lessonsOrInsights');
            card.Activity_Summary__c = (String) parsed.get('activitySummary');
            card.Activity_Milestones__c = (String) parsed.get('activityMilestones');
            card.Key_Stakeholders__c = (String) parsed.get('keyStakeholders');

            // 信頼度関連フィールド
            card.Confidence_Score__c = score;
            card.Product_Count__c = productCount;
            card.Activity_Count__c = activityCount;
            card.Has_Description__c = hasDescription;
            card.Opportunity_Stage__c = opp.StageName;

            insert card;
            System.debug('サマリカード生成完了: ' + opp.Name + ' (信頼度: ' + score + ')');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'サマリカード保存エラー [' + opp.Name + ']: ' + e.getMessage());
        }
    }
}
