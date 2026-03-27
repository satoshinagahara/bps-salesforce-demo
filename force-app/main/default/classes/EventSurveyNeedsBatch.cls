public with sharing class EventSurveyNeedsBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Schedulable {

    private Datetime lastDataStreamUpdate;

    public EventSurveyNeedsBatch() {}

    public EventSurveyNeedsBatch(Datetime lastDataStreamUpdate) {
        this.lastDataStreamUpdate = lastDataStreamUpdate;
    }

    // Schedulable: 定期実行エントリポイント
    public void execute(SchedulableContext sc) {
        // データストリームの最終更新日を確認してからBatch起動
        Datetime streamLastUpdate = getDataStreamLastUpdate();
        if (streamLastUpdate == null) {
            System.debug('データストリームの更新日を取得できませんでした。スキップします。');
            return;
        }

        Database.executeBatch(new EventSurveyNeedsBatch(streamLastUpdate), 1);
    }

    // Batchable: データストリーム更新後に未処理 or 再処理が必要なキャンペーンを取得
    public Database.QueryLocator start(Database.BatchableContext bc) {
        // Survey_Analyzed_Date__c が null（未分析）または データストリーム最終更新より古い（差分あり）
        return Database.getQueryLocator([
            SELECT Id, Name, Type, StartDate, Description, Survey_Analyzed_Date__c
            FROM Campaign
            WHERE Type IN ('Seminar / Conference', 'Webinar', 'Conference', 'Trade Show')
              AND Status != 'Aborted'
              AND (Survey_Analyzed_Date__c = null OR Survey_Analyzed_Date__c < :lastDataStreamUpdate)
            ORDER BY StartDate DESC
        ]);
    }

    // Batchable: キャンペーンごとにニーズカード生成
    public void execute(Database.BatchableContext bc, List<Campaign> campaigns) {
        for (Campaign campaign : campaigns) {
            try {
                EventSurveyNeedsAction.AnalysisInput needsInput = new EventSurveyNeedsAction.AnalysisInput();
                needsInput.campaignId = campaign.Id;
                EventSurveyNeedsAction.analyzeEventSurvey(
                    new List<EventSurveyNeedsAction.AnalysisInput>{ needsInput }
                );

                campaign.Survey_Analyzed_Date__c = Datetime.now();
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'Campaign ' + campaign.Name + ' 処理エラー: ' + e.getMessage());
            }
        }
        update campaigns;
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('EventSurveyNeedsBatch 完了');
    }

    // データストリームの最終更新日を取得（エンゲージメントDLO側）
    public static Datetime getDataStreamLastUpdate() {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(Url.getOrgDomainUrl().toExternalForm()
                + '/services/data/v62.0/ssot/data-streams');
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + UserInfo.getSessionId());
            req.setHeader('Content-Type', 'application/json');

            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() == 200) {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                List<Object> streams = (List<Object>) parsed.get('dataStreams');
                for (Object s : streams) {
                    Map<String, Object> stream = (Map<String, Object>) s;
                    String name = (String) stream.get('name');
                    // エンゲージメントDLOのデータストリームを探す
                    if (name != null && name.containsIgnoreCase('Event_Survey') && name.containsIgnoreCase('Engagement')) {
                        String lastRefresh = (String) stream.get('lastRefreshDate');
                        if (lastRefresh != null) {
                            return Datetime.valueOf(lastRefresh.replace('T', ' ').substring(0, 19));
                        }
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'データストリーム確認エラー: ' + e.getMessage());
        }
        return null;
    }

    // スケジュール登録ヘルパー（毎日朝6時に実行）
    public static String scheduleDaily() {
        return System.schedule(
            'EventSurvey Needs Auto Generation',
            '0 0 6 * * ?',
            new EventSurveyNeedsBatch()
        );
    }
}
