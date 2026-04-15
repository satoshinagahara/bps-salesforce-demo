public with sharing class AssetShowcaseController {
    private static final String GCP_ENDPOINT =
        'https://asia-northeast1-ageless-lamp-251200.cloudfunctions.net/generate-design-suggestion';

    // デモ対象のAsset情報ハードコード（Latitude/Longitude FLSを避ける）
    private static final Map<Id, AssetDemo> DEMO_MAP = new Map<Id, AssetDemo>{
        '02iIe00000165UeIAI' => new AssetDemo(
            13.7563, 100.5018,
            'タイ・バンコク郊外 工業団地B棟',
            'products/enercharge_pro_e2000.png'
        ),
        '02iIe00000165VhIAI' => new AssetDemo(
            35.1815, 136.9066,
            'アライドパワー 中部第3拠点（愛知県）',
            'products/a1000_wind_turbine.png'
        )
    };

    public class AssetDemo {
        public Decimal latitude;
        public Decimal longitude;
        public String locationLabel;
        public String imagePath;
        public AssetDemo(Decimal lat, Decimal lng, String label, String path) {
            this.latitude = lat;
            this.longitude = lng;
            this.locationLabel = label;
            this.imagePath = path;
        }
    }

    public class AssetShowcase {
        @AuraEnabled public String assetId;
        @AuraEnabled public String assetName;
        @AuraEnabled public String productName;
        @AuraEnabled public String accountName;
        @AuraEnabled public Date installDate;
        @AuraEnabled public String status;
        @AuraEnabled public String serialNumber;
        @AuraEnabled public Decimal price;
        @AuraEnabled public String priceFormatted;
        @AuraEnabled public Boolean iotEnabled;
        @AuraEnabled public Boolean hasDemoData;
        @AuraEnabled public Decimal latitude;
        @AuraEnabled public Decimal longitude;
        @AuraEnabled public String locationLabel;
        @AuraEnabled public String imageUrl;
    }

    @AuraEnabled(cacheable=true)
    public static AssetShowcase getShowcase(Id assetId) {
        Asset a = [
            SELECT Id, Name, Product2.Name, Account.Name, InstallDate, Status,
                   SerialNumber, Price, IoT__c
            FROM Asset
            WHERE Id = :assetId
            LIMIT 1
        ];

        AssetShowcase s = new AssetShowcase();
        s.assetId = a.Id;
        s.assetName = a.Name;
        s.productName = a.Product2 != null ? a.Product2.Name : '';
        s.accountName = a.Account != null ? a.Account.Name : '';
        s.installDate = a.InstallDate;
        s.status = a.Status;
        s.serialNumber = a.SerialNumber;
        s.price = a.Price;
        s.priceFormatted = formatCurrency(a.Price);
        s.iotEnabled = a.IoT__c;

        AssetDemo demo = DEMO_MAP.get(assetId);
        if (demo != null) {
            s.hasDemoData = true;
            s.latitude = demo.latitude;
            s.longitude = demo.longitude;
            s.locationLabel = demo.locationLabel;
            s.imageUrl = getSignedImageUrl(demo.imagePath);
        } else {
            s.hasDemoData = false;
        }
        return s;
    }

    private static String getSignedImageUrl(String imagePath) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(GCP_ENDPOINT + '/signed-url?path=' + EncodingUtil.urlEncode(imagePath, 'UTF-8'));
            req.setMethod('GET');
            req.setTimeout(30000);
            Http http = new Http();
            HttpResponse res = http.send(req);
            if (res.getStatusCode() == 200) {
                Map<String, Object> m = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                return (String) m.get('url');
            }
        } catch (Exception e) {
            System.debug('signed url failed: ' + e.getMessage());
        }
        return null;
    }

    private static String formatCurrency(Decimal val) {
        if (val == null) return '';
        if (val >= 100000000) return '¥' + (val / 100000000).setScale(1) + '億';
        if (val >= 10000) return '¥' + (val / 10000).setScale(0) + '万';
        return '¥' + val.setScale(0);
    }
}
