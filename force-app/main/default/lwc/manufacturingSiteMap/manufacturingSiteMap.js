import { LightningElement, api, wire, track } from 'lwc';
import getSitesBySupplier from '@salesforce/apex/ManufacturingSiteMapController.getSitesBySupplier';

const PART_COLUMNS = [
    { label: '部品番号', fieldName: 'partNumber', type: 'text', initialWidth: 110 },
    { label: '部品名', fieldName: 'partName', type: 'text', initialWidth: 150 },
    { label: '製品', fieldName: 'productLabel', type: 'text', initialWidth: 130 },
    {
        label: '月産能力',
        fieldName: 'monthlyCapacity',
        type: 'number',
        initialWidth: 90,
        cellAttributes: { alignment: 'right' },
        typeAttributes: { minimumFractionDigits: 0, maximumFractionDigits: 0 }
    },
    {
        label: '小計',
        fieldName: 'extendedCost',
        type: 'currency',
        initialWidth: 90,
        cellAttributes: { alignment: 'right' },
        typeAttributes: { currencyCode: 'JPY', minimumFractionDigits: 0, maximumFractionDigits: 0 }
    },
    { label: 'LT', fieldName: 'leadTime', type: 'text', initialWidth: 70 }
];

export default class ManufacturingSiteMap extends LightningElement {
    @api recordId;

    @track sites = null;
    @track error = null;
    @track isLoading = true;
    @track selectedSiteId = null;

    partColumns = PART_COLUMNS;

    @wire(getSitesBySupplier, { accountId: '$recordId' })
    wiredSites({ data, error }) {
        this.isLoading = false;
        if (data) {
            this.sites = data;
            this.error = null;
        } else if (error) {
            this.error = error?.body?.message ?? 'データの取得に失敗しました';
            this.sites = null;
        }
    }

    get hasData()  { return this.sites && this.sites.length > 0; }
    get isEmpty()  { return !this.isLoading && !this.error && !this.hasData; }

    // ── Map markers ──────────────────────────────────────────────────
    get mapMarkers() {
        if (!this.sites) return [];
        return this.sites.map(s => ({
            location: {
                Latitude: s.latitude,
                Longitude: s.longitude
            },
            title: s.name,
            description: s.address + ' | ' + s.partCount + '部品 | ' + s.productCount + '製品',
            value: s.id,
            icon: s.productCount >= 3 ? 'standard:incident' :
                  s.productCount >= 2 ? 'standard:warning_action' :
                  'standard:location'
        }));
    }

    get mapCenter() {
        if (!this.sites || this.sites.length === 0) {
            return { Latitude: 36.5, Longitude: 137.5 };
        }
        const lats = this.sites.map(s => s.latitude);
        const lngs = this.sites.map(s => s.longitude);
        return {
            Latitude: (Math.min(...lats) + Math.max(...lats)) / 2,
            Longitude: (Math.min(...lngs) + Math.max(...lngs)) / 2
        };
    }

    // ── Selected site ────────────────────────────────────────────────
    get selectedSite() {
        if (!this.selectedSiteId || !this.sites) return null;
        return this.sites.find(s => s.id === this.selectedSiteId);
    }

    get hasSiteSelected() { return this.selectedSite != null; }

    get selectedSiteName()       { return this.selectedSite?.name ?? ''; }
    get selectedSiteAddress()    { return this.selectedSite?.address ?? ''; }
    get selectedSitePrefecture() { return this.selectedSite?.prefecture ?? ''; }
    get selectedSitePartCount()  { return this.selectedSite?.partCount ?? 0; }
    get selectedSiteProductCount() { return this.selectedSite?.productCount ?? 0; }
    get selectedSiteTotalCost() {
        if (!this.selectedSite) return '¥0';
        return '¥' + Math.round(this.selectedSite.totalCost).toLocaleString();
    }
    get selectedSiteProducts() {
        if (!this.selectedSite?.products) return '';
        return this.selectedSite.products.join(', ');
    }

    get selectedSiteRiskLevel() {
        const pc = this.selectedSite?.productCount ?? 0;
        if (pc >= 3) return 'HIGH';
        if (pc >= 2) return 'MEDIUM';
        return 'LOW';
    }
    get selectedSiteRiskClass() {
        const level = this.selectedSiteRiskLevel;
        if (level === 'HIGH') return 'risk-badge risk-high';
        if (level === 'MEDIUM') return 'risk-badge risk-medium';
        return 'risk-badge risk-low';
    }

    get selectedSiteParts() {
        if (!this.selectedSite?.parts) return [];
        return this.selectedSite.parts.map(p => ({
            ...p,
            productLabel: p.productCode ? p.productCode + ' ' + p.productName : p.productName
        }));
    }

    handleMarkerSelect(event) {
        this.selectedSiteId = event.detail.selectedMarkerValue;
    }

    // ── Summary ──────────────────────────────────────────────────────
    get totalSites()    { return this.sites?.length ?? 0; }
    get totalParts()    {
        if (!this.sites) return 0;
        return this.sites.reduce((sum, s) => sum + (s.partCount || 0), 0);
    }
    get totalProducts() {
        if (!this.sites) return 0;
        const all = new Set();
        this.sites.forEach(s => (s.products || []).forEach(p => all.add(p)));
        return all.size;
    }
    get totalCost() {
        if (!this.sites) return '¥0';
        const sum = this.sites.reduce((acc, s) => acc + (s.totalCost || 0), 0);
        return '¥' + Math.round(sum).toLocaleString();
    }
}
