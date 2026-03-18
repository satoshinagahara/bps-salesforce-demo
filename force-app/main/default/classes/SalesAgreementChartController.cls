public with sharing class SalesAgreementChartController {
    @AuraEnabled(cacheable=true)
    public static List<ProductScheduleData> getScheduleData(Id agreementId) {
        List<Sales_Agreement_Product__c> products = [
            SELECT Id, Product__r.Name, Unit_Price__c,
                (SELECT Schedule_Month__c, Plan_Quantity__c, Plan_Amount__c,
                        Actual_Quantity__c, Actual_Amount__c
                 FROM Schedules__r ORDER BY Schedule_Month__c)
            FROM Sales_Agreement_Product__c
            WHERE Sales_Agreement__c = :agreementId
        ];

        List<ProductScheduleData> result = new List<ProductScheduleData>();
        for (Sales_Agreement_Product__c sap : products) {
            ProductScheduleData psd = new ProductScheduleData();
            psd.productName = sap.Product__r.Name;
            psd.unitPrice = sap.Unit_Price__c;
            psd.schedules = new List<ScheduleData>();
            Decimal totalPlan = 0, totalActual = 0;
            Decimal maxQty = 0;

            for (Sales_Agreement_Schedule__c s : sap.Schedules__r) {
                ScheduleData sd = new ScheduleData();
                sd.month = s.Schedule_Month__c;
                sd.planQty = s.Plan_Quantity__c != null ? s.Plan_Quantity__c : 0;
                sd.actualQty = s.Actual_Quantity__c != null ? s.Actual_Quantity__c : 0;
                sd.planAmt = s.Plan_Amount__c != null ? s.Plan_Amount__c : 0;
                sd.actualAmt = s.Actual_Amount__c != null ? s.Actual_Amount__c : 0;
                sd.hasActual = s.Actual_Quantity__c != null && s.Actual_Quantity__c > 0;
                psd.schedules.add(sd);
                totalPlan += sd.planQty;
                if (sd.hasActual) totalActual += sd.actualQty;
                if (sd.planQty > maxQty) maxQty = sd.planQty;
                if (sd.actualQty > maxQty) maxQty = sd.actualQty;
            }
            psd.totalPlanQty = totalPlan;
            psd.totalActualQty = totalActual;
            psd.maxQty = maxQty;
            Decimal planWithActual = 0;
            for (ScheduleData sd : psd.schedules) {
                if (sd.hasActual) planWithActual += sd.planQty;
            }
            psd.achievementRate = planWithActual > 0 ? (totalActual / planWithActual * 100).setScale(1) : 0;
            result.add(psd);
        }
        return result;
    }

    public class ProductScheduleData {
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal unitPrice;
        @AuraEnabled public List<ScheduleData> schedules;
        @AuraEnabled public Decimal totalPlanQty;
        @AuraEnabled public Decimal totalActualQty;
        @AuraEnabled public Decimal maxQty;
        @AuraEnabled public Decimal achievementRate;
    }

    public class ScheduleData {
        @AuraEnabled public Date month;
        @AuraEnabled public Decimal planQty;
        @AuraEnabled public Decimal actualQty;
        @AuraEnabled public Decimal planAmt;
        @AuraEnabled public Decimal actualAmt;
        @AuraEnabled public Boolean hasActual;
    }
}
