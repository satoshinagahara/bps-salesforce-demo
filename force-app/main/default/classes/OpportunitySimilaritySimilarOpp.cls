@JsonAccess(serializable='always' deserializable='always')
global class OpportunitySimilaritySimilarOpp {
    @AuraEnabled
    global String name;

    @AuraEnabled
    global String accountName;

    @AuraEnabled
    global String matchReason;

    @AuraEnabled
    global String dealType;

    @AuraEnabled
    global String salesMotion;

    @AuraEnabled
    global String competitiveSituation;

    @AuraEnabled
    global String processPattern;

    @AuraEnabled
    global String customerChallenge;

    @AuraEnabled
    global String valueProposition;

    @AuraEnabled
    global String lessons;

    @AuraEnabled
    global Boolean isWon;
}
