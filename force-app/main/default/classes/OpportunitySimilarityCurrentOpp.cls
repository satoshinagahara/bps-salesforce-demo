@JsonAccess(serializable='always' deserializable='always')
global class OpportunitySimilarityCurrentOpp {
    @AuraEnabled
    global String name;

    @AuraEnabled
    global String stage;

    @AuraEnabled
    global Decimal amount;

    @AuraEnabled
    global String accountName;

    @AuraEnabled
    global String dealType;

    @AuraEnabled
    global String salesMotion;

    @AuraEnabled
    global String competitiveSituation;

    @AuraEnabled
    global String customerChallenge;

    @AuraEnabled
    global String keyRisks;

    @AuraEnabled
    global Boolean hasSummaryCard;
}
