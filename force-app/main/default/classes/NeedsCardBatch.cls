public with sharing class NeedsCardBatch implements Database.Batchable<SObject>, Database.AllowsCallouts {

    // Batchable: 未抽出の面談記録を取得
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator([
            SELECT Id, Summary__c, Transcript__c
            FROM Meeting_Record__c
            WHERE Needs_Extracted__c = false
              AND Account__c != null
            ORDER BY Meeting_Date__c DESC
        ]);
    }

    // Batchable: 面談記録ごとにニーズカード抽出
    public void execute(Database.BatchableContext bc, List<Meeting_Record__c> meetings) {
        for (Meeting_Record__c meeting : meetings) {
            // Summary/Transcriptが両方空の面談はスキップ
            if (String.isBlank(meeting.Summary__c) && String.isBlank(meeting.Transcript__c)) {
                continue;
            }
            try {
                NeedsCardExtractionAction.ExtractionInput input = new NeedsCardExtractionAction.ExtractionInput();
                input.meetingRecordId = meeting.Id;
                NeedsCardExtractionAction.extractNeeds(
                    new List<NeedsCardExtractionAction.ExtractionInput>{ input }
                );
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, '面談記録 ' + meeting.Id + ' 処理エラー: ' + e.getMessage());
            }
        }
    }

    // Batchable: 完了後にイベントアンケートニーズバッチをチェーン起動
    public void finish(Database.BatchableContext bc) {
        System.debug('NeedsCardBatch（面談記録）完了。アンケートバッチをチェーン起動します。');
        try {
            Datetime streamLastUpdate = EventSurveyNeedsBatch.getDataStreamLastUpdate();
            if (streamLastUpdate == null) {
                System.debug('データストリームの更新日を取得できませんでした。アンケートバッチをスキップします。');
                return;
            }
            Database.executeBatch(new EventSurveyNeedsBatch(streamLastUpdate), 1);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'アンケートバッチ チェーン起動エラー: ' + e.getMessage());
        }
    }
}
