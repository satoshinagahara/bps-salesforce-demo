public with sharing class SupplyChainTDController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getGameData() {
        List<Manufacturing_Site__c> sites = [
            SELECT Id, Name, Prefecture__c, Latitude__c, Longitude__c,
                   Is_Own_Site__c, Supplier__r.Name
            FROM Manufacturing_Site__c
            WHERE Latitude__c != null AND Longitude__c != null
            ORDER BY Is_Own_Site__c DESC, Name
        ];

        List<Map<String, Object>> ownSites = new List<Map<String, Object>>();
        List<Map<String, Object>> supplierSites = new List<Map<String, Object>>();

        for (Manufacturing_Site__c s : sites) {
            Map<String, Object> site = new Map<String, Object>();
            site.put('id', s.Id);
            site.put('name', s.Name);
            site.put('prefecture', s.Prefecture__c);
            site.put('lat', s.Latitude__c);
            site.put('lng', s.Longitude__c);
            site.put('supplierName', s.Supplier__r.Name);
            if (s.Is_Own_Site__c) {
                ownSites.add(site);
            } else {
                supplierSites.add(site);
            }
        }

        // BOM dependency count per supplier site
        Set<Id> supplierSiteIds = new Set<Id>();
        for (Manufacturing_Site__c s : sites) {
            if (!s.Is_Own_Site__c) supplierSiteIds.add(s.Id);
        }
        Map<Id, Integer> bomDeps = new Map<Id, Integer>();
        if (!supplierSiteIds.isEmpty()) {
            for (AggregateResult ar : [
                SELECT Manufacturing_Site__c siteId, COUNT(Id) cnt
                FROM BOM_Part__c
                WHERE Manufacturing_Site__c IN :supplierSiteIds
                GROUP BY Manufacturing_Site__c
            ]) {
                bomDeps.put((Id)ar.get('siteId'), (Integer)ar.get('cnt'));
            }
        }
        for (Map<String, Object> ss : supplierSites) {
            Id sid = (Id)ss.get('id');
            ss.put('bomDeps', bomDeps.containsKey(sid) ? bomDeps.get(sid) : 0);
        }

        Map<String, Object> result = new Map<String, Object>();
        result.put('ownSites', ownSites);
        result.put('supplierSites', supplierSites);
        return result;
    }
}
