public with sharing class AssetMilestoneController {

    public class MilestoneDto {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String milestoneType;
        @AuraEnabled public Date scheduledDate;
        @AuraEnabled public Date completedDate;
        @AuraEnabled public String status;
        @AuraEnabled public String description;
        @AuraEnabled public String notes;
        @AuraEnabled public Boolean isPast;       // 予定日が今日以前
        @AuraEnabled public Boolean isToday;      // 予定日が今日
        @AuraEnabled public Boolean isFuture;     // 予定日が今日より後
        @AuraEnabled public Boolean isCompleted;  // ステータスが実施済
        @AuraEnabled public Boolean isNear;       // 14日以内に予定
        @AuraEnabled public Integer daysFromToday;
    }

    @AuraEnabled(cacheable=true)
    public static List<MilestoneDto> getMilestones(Id assetId) {
        List<Asset_Milestone__c> rows = [
            SELECT Id, Name, Milestone_Type__c, Scheduled_Date__c, Completed_Date__c,
                   Status__c, Description__c, Notes__c
            FROM Asset_Milestone__c
            WHERE Asset__c = :assetId
            ORDER BY Scheduled_Date__c ASC, CreatedDate ASC
        ];

        Date today = Date.today();
        List<MilestoneDto> out = new List<MilestoneDto>();
        for (Asset_Milestone__c m : rows) {
            MilestoneDto d = new MilestoneDto();
            d.id = m.Id;
            d.name = m.Name;
            d.milestoneType = m.Milestone_Type__c;
            d.scheduledDate = m.Scheduled_Date__c;
            d.completedDate = m.Completed_Date__c;
            d.status = m.Status__c;
            d.description = m.Description__c;
            d.notes = m.Notes__c;
            d.isCompleted = (m.Status__c == '実施済');

            if (m.Scheduled_Date__c != null) {
                Integer diff = today.daysBetween(m.Scheduled_Date__c);
                d.daysFromToday = diff;
                d.isPast = (diff < 0);
                d.isToday = (diff == 0);
                d.isFuture = (diff > 0);
                d.isNear = (diff >= 0 && diff <= 14);
            }
            out.add(d);
        }
        return out;
    }
}
