public with sharing class BatchLauncherController {

    @AuraEnabled
    public static LaunchResult launchBatch(String batchName) {
        LaunchResult result = new LaunchResult();
        try {
            switch on batchName {
                when 'NeedsCardGeneration' {
                    Id jobId = Database.executeBatch(new NeedsCardBatch(), 1);
                    result.jobId = jobId;
                    result.message = '面談記録→ニーズカード抽出バッチを起動しました。完了後にアンケートバッチが自動チェーン起動します。';
                }
                when 'BOMSupplierMatching' {
                    Id jobId = Database.executeBatch(new BOMSupplierMatchingBatch(), 1);
                    result.jobId = jobId;
                    result.message = 'BOMサプライヤー名寄せバッチを起動しました。';
                }
                when 'OpportunitySummary' {
                    Id jobId = Database.executeBatch(new OpportunitySummaryBatch(), 1);
                    result.jobId = jobId;
                    result.message = '商談サマリカード生成バッチを起動しました。';
                }
                when else {
                    result.errorMessage = '不明なバッチ名: ' + batchName;
                }
            }
        } catch (Exception e) {
            result.errorMessage = e.getTypeName() + ': ' + e.getMessage();
        }
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<BatchInfo> getAvailableBatches() {
        List<BatchInfo> batches = new List<BatchInfo>();

        BatchInfo b0 = new BatchInfo();
        b0.name = 'NeedsCardGeneration';
        b0.label = '面談＋アンケート → ニーズカード生成';
        b0.description = '未抽出の面談記録からニーズカードを抽出し、完了後にイベントアンケートからのニーズカード自動生成もチェーン実行します。';
        b0.iconName = 'standard:customer';
        batches.add(b0);

        BatchInfo b2 = new BatchInfo();
        b2.name = 'BOMSupplierMatching';
        b2.label = 'BOM → サプライヤー名寄せ';
        b2.description = 'Data CloudのBOMデータからサプライヤー名をAccountマスタとLLMで名寄せします。';
        b2.iconName = 'standard:product';
        batches.add(b2);

        BatchInfo b3 = new BatchInfo();
        b3.name = 'OpportunitySummary';
        b3.label = '商談 → サマリカード生成';
        b3.description = '全商談のデータ（商品・活動・Description等）をLLMで分析し、商談サマリカード（中間表現）を自動生成します。信頼度スコアも計算されます。';
        b3.iconName = 'standard:opportunity';
        batches.add(b3);

        return batches;
    }

    @AuraEnabled
    public static JobStatus getJobStatus(Id jobId) {
        JobStatus status = new JobStatus();
        try {
            AsyncApexJob job = [
                SELECT Id, Status, NumberOfErrors, JobItemsProcessed, TotalJobItems, CompletedDate
                FROM AsyncApexJob
                WHERE Id = :jobId
                LIMIT 1
            ];
            status.status = job.Status;
            status.processed = job.JobItemsProcessed;
            status.total = job.TotalJobItems;
            status.errors = job.NumberOfErrors;
            status.isComplete = (job.Status == 'Completed' || job.Status == 'Failed' || job.Status == 'Aborted');
        } catch (Exception e) {
            status.status = 'Unknown';
            status.isComplete = true;
        }
        return status;
    }

    public class LaunchResult {
        @AuraEnabled public Id jobId;
        @AuraEnabled public String message;
        @AuraEnabled public String errorMessage;
    }

    public class BatchInfo {
        @AuraEnabled public String name;
        @AuraEnabled public String label;
        @AuraEnabled public String description;
        @AuraEnabled public String iconName;
    }

    public class JobStatus {
        @AuraEnabled public String status;
        @AuraEnabled public Integer processed;
        @AuraEnabled public Integer total;
        @AuraEnabled public Integer errors;
        @AuraEnabled public Boolean isComplete;
    }
}
