@JsonAccess(serializable='always' deserializable='always')
global class OpportunitySimilarityResult {
    @AuraEnabled
    global String reportText;

    @AuraEnabled
    global String userQuery;

    @AuraEnabled
    global String currentOpportunityJson;

    @AuraEnabled
    global String similarOpportunitiesJson;
}
