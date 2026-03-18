import { LightningElement, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getAllSites from '@salesforce/apex/ManufacturingSiteMapController.getAllSites';
import simulateDisaster from '@salesforce/apex/ManufacturingSiteMapController.simulateDisaster';

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

const DISASTER_PRESETS = [
    { label: 'シナリオを選択...', value: '' },
    { label: '南海トラフ地震（東海〜近畿）', value: 'nankai' },
    { label: '首都直下地震（関東）', value: 'shutochokka' },
    { label: '東北地方太平洋沖地震', value: 'tohoku' }
];

const PRESET_PREFECTURES = {
    nankai: ['静岡県', '愛知県', '三重県', '和歌山県', '大阪府', '徳島県'],
    shutochokka: ['東京都', '神奈川県', '千葉県', '埼玉県'],
    tohoku: ['宮城県', '岩手県', '福島県']
};

const SUPPLIER_COLORS = [
    '#0176d3', '#e87d2f', '#2e844a', '#ba0517', '#7526c4',
    '#067fad', '#c23934', '#3ba755', '#d47500', '#5a1ba9'
];

export default class AllSitesMap extends NavigationMixin(LightningElement) {
    @track allData = null;
    @track error = null;
    @track isLoading = true;
    @track selectedSiteId = null;
    @track filterSupplier = '';
    @track filterPrefecture = '';

    // Disaster simulation
    @track simMode = false;
    @track simPreset = '';
    @track simSelectedPrefs = [];
    @track simResult = null;
    @track simLoading = false;
    @track simExpandedProduct = null;

    partColumns = PART_COLUMNS;
    disasterPresets = DISASTER_PRESETS;
    _supplierColorMap = {};

    @wire(getAllSites)
    wiredSites({ data, error }) {
        this.isLoading = false;
        if (data) {
            this.allData = data;
            this.error = null;
            this._buildColorMap();
        } else if (error) {
            this.error = error?.body?.message ?? 'データの取得に失敗しました';
            this.allData = null;
        }
    }

    _buildColorMap() {
        if (!this.allData?.suppliers) return;
        this.allData.suppliers.forEach((s, i) => {
            this._supplierColorMap[s.value] = SUPPLIER_COLORS[i % SUPPLIER_COLORS.length];
        });
    }

    get hasData()  { return this.allData?.sites?.length > 0; }
    get isEmpty()  { return !this.isLoading && !this.error && !this.hasData; }

    // ── Filter options ────────────────────────────────────────────────
    get supplierOptions() {
        const opts = [{ label: 'すべてのサプライヤー', value: '' }];
        if (this.allData?.suppliers) {
            this.allData.suppliers.forEach(s => opts.push(s));
        }
        return opts;
    }

    get prefectureOptions() {
        const opts = [{ label: 'すべての都道府県', value: '' }];
        if (this.allData?.prefectures) {
            this.allData.prefectures.forEach(p => opts.push({ label: p, value: p }));
        }
        return opts;
    }

    get filteredSites() {
        if (!this.allData?.sites) return [];
        return this.allData.sites.filter(s => {
            if (this.filterSupplier && s.supplierId !== this.filterSupplier) return false;
            if (this.filterPrefecture && s.prefecture !== this.filterPrefecture) return false;
            return true;
        });
    }

    // ── Map markers ───────────────────────────────────────────────────
    get mapMarkers() {
        if (this.simMode && this.simResult) {
            // Show all sites, highlight affected ones
            const affectedIds = new Set((this.simResult.affectedSites || []).map(s => s.id));
            return (this.allData?.sites || []).map(s => ({
                location: { Latitude: s.latitude, Longitude: s.longitude },
                title: s.name,
                description: (affectedIds.has(s.id) ? '*** 被災 *** ' : '') +
                    s.supplierName + ' | ' + s.address,
                value: s.id,
                icon: affectedIds.has(s.id) ? 'standard:incident' : 'standard:location'
            }));
        }
        return this.filteredSites.map(s => ({
            location: { Latitude: s.latitude, Longitude: s.longitude },
            title: s.name,
            description: s.supplierName + ' | ' + s.address + ' | ' + s.partCount + '部品',
            value: s.id,
            icon: 'standard:location'
        }));
    }

    get mapCenter() {
        const sites = this.simMode && this.simResult
            ? (this.simResult.affectedSites || [])
            : this.filteredSites;
        if (!sites.length) return { Latitude: 36.5, Longitude: 137.5 };
        const lats = sites.map(s => s.latitude);
        const lngs = sites.map(s => s.longitude);
        return {
            Latitude: (Math.min(...lats) + Math.max(...lats)) / 2,
            Longitude: (Math.min(...lngs) + Math.max(...lngs)) / 2
        };
    }

    // ── Normal mode summary ───────────────────────────────────────────
    get totalSites()     { return this.filteredSites.length; }
    get totalSuppliers() {
        return new Set(this.filteredSites.map(s => s.supplierId)).size;
    }
    get totalParts() {
        return this.filteredSites.reduce((sum, s) => sum + (s.partCount || 0), 0);
    }
    get totalProducts() {
        const all = new Set();
        this.filteredSites.forEach(s => (s.products || []).forEach(p => all.add(p)));
        return all.size;
    }
    get totalCost() {
        const sum = this.filteredSites.reduce((acc, s) => acc + (s.totalCost || 0), 0);
        return '¥' + Math.round(sum).toLocaleString();
    }

    get supplierLegend() {
        if (!this.allData?.suppliers) return [];
        const activeIds = new Set(this.filteredSites.map(s => s.supplierId));
        return this.allData.suppliers
            .filter(s => activeIds.has(s.value))
            .map(s => ({
                id: s.value,
                name: s.label,
                dotStyle: 'background-color: ' + (this._supplierColorMap[s.value] || '#706e6b'),
                siteCount: this.filteredSites.filter(site => site.supplierId === s.value).length
            }));
    }

    get siteCards() {
        return this.filteredSites.map(s => ({
            ...s,
            costLabel: '¥' + Math.round(s.totalCost || 0).toLocaleString(),
            capLabel: s.capacityCount > 0 ? s.capacityCount + 'キャパ' : '',
            hasCapacity: s.capacityCount > 0,
            siteTypeLabel: s.isAssemblySite ? '組立拠点' : '',
            siteTypeClass: s.isAssemblySite ? 'site-type-tag assembly' : '',
            cardClass: 'site-card' + (s.id === this.selectedSiteId ? ' selected' : ''),
            borderColor: 'border-left: 4px solid ' + (this._supplierColorMap[s.supplierId] || '#706e6b')
        }));
    }

    get selectedSiteCapCount() { return this.selectedSite?.capacityCount ?? 0; }
    get hasSelectedSiteCapacity() { return this.selectedSiteCapCount > 0; }

    // ── Selected site (normal mode) ───────────────────────────────────
    get selectedSite() {
        if (!this.selectedSiteId) return null;
        return this.filteredSites.find(s => s.id === this.selectedSiteId) || null;
    }
    get hasSiteSelected() { return this.selectedSite != null; }
    get selectedSiteName()    { return this.selectedSite?.name ?? ''; }
    get selectedSiteAddress() { return this.selectedSite?.address ?? ''; }
    get selectedSiteSupplier(){ return this.selectedSite?.supplierName ?? ''; }
    get selectedSitePartCount()    { return this.selectedSite?.partCount ?? 0; }
    get selectedSiteProductCount() { return this.selectedSite?.productCount ?? 0; }
    get selectedSiteTotalCost() {
        if (!this.selectedSite) return '¥0';
        return '¥' + Math.round(this.selectedSite.totalCost).toLocaleString();
    }
    get selectedSiteProducts() {
        return (this.selectedSite?.products || []).join(', ');
    }
    get selectedSiteIsAssembly() { return this.selectedSite?.isAssemblySite ?? false; }
    get selectedSiteBomCount()  { return this.selectedSite?.bomCount ?? 0; }
    get selectedSiteParts() {
        if (!this.selectedSite?.parts) return [];
        return this.selectedSite.parts.map(p => ({
            ...p,
            productLabel: p.productCode ? p.productCode + ' ' + p.productName : p.productName
        }));
    }

    // ── Disaster simulation getters ───────────────────────────────────
    get hasSimResult()    { return this.simResult != null; }
    get simOwnSites()     { return this.simResult?.ownSitesAffected ?? 0; }
    get simSupplierSites(){ return this.simResult?.supplierSitesAffected ?? 0; }
    get simTotalProducts(){ return this.simResult?.totalProductsAffected ?? 0; }
    get simTotalRiskCost(){
        const c = this.simResult?.totalRiskCost ?? 0;
        return '¥' + Math.round(c).toLocaleString();
    }
    get simSafeOwnSites() { return this.simResult?.safeOwnSites ?? 0; }

    get simAffectedPrefLabel() {
        return this.simSelectedPrefs.join('・');
    }

    get simProductCards() {
        if (!this.simResult?.productImpact) return [];
        const sorted = [...this.simResult.productImpact].sort((a, b) =>
            (a.sortRank || 99) - (b.sortRank || 99)
        );
        return sorted.map(p => ({
            ...p,
            key: p.productId,
            displayName: (p.productCode || '') + ' ' + (p.productName || ''),
            riskClass: 'sim-risk-badge sim-risk-' + (p.riskLevel || 'low').toLowerCase(),
            costLabel: '¥' + Math.round(p.affectedSupplyCost || 0).toLocaleString(),
            depPct: (p.supplyDependencyPct || 0) + '%',
            depBarStyle: 'width: ' + Math.min(p.supplyDependencyPct || 0, 100) + '%',
            depBarClass: 'dep-bar-fill' + (p.supplyDependencyPct >= 50 ? ' critical' : p.supplyDependencyPct >= 20 ? ' warning' : ''),
            altLabel: p.hasAlternativeSite ? '代替BOMあり' : (p.bomCount > 1 ? '全BOM被災' : '代替BOMなし'),
            altClass: p.hasAlternativeSite ? 'alt-ok' : 'alt-none',
            bomCountLabel: p.bomCount + ' BOM（' + (p.affectedBomCount || 0) + '件 被災）',
            hasBomBreakdown: p.bomBreakdown && p.bomBreakdown.length > 0,
            bomCards: (p.bomBreakdown || []).map(b => ({
                ...b,
                key: b.bomId,
                statusClass: 'bom-status ' + (b.isAffected ? 'bom-affected' : 'bom-safe'),
                siteLabel: b.assemblySite + '（' + b.assemblySitePrefecture + '）',
                costLabel: b.affectedSupplyCost > 0 ? '¥' + Math.round(b.affectedSupplyCost).toLocaleString() : '—',
                hasAffectedParts: b.affectedParts && b.affectedParts.length > 0
            })),
            isExpanded: p.productId === this.simExpandedProduct,
            hasAffectedParts: p.affectedParts && p.affectedParts.length > 0
        }));
    }

    get simAffectedSiteList() {
        if (!this.simResult?.affectedSites) return [];
        return this.simResult.affectedSites.map(s => ({
            ...s,
            typeLabel: s.isOwnSite ? '自社工場' : 'サプライヤー拠点',
            typeClass: s.isOwnSite ? 'site-type-own' : 'site-type-supplier'
        }));
    }

    get hasOffloadOptions() { return this.simResult?.hasOffloadOptions ?? false; }
    get offloadProposals() {
        if (!this.simResult?.offloadProposals) return [];
        return this.simResult.offloadProposals.map((p, i) => ({
            ...p,
            key: 'off-' + i,
            affectedCapFmt: (p.affectedCapacity || 0).toLocaleString('ja-JP'),
            spareFmt: (p.alternativeSpareCapacity || 0).toLocaleString('ja-JP'),
            offloadPctFmt: (p.offloadPct || 0) + '%',
            canOffloadClass: p.canOffload ? 'offload-ok' : 'offload-partial',
            supplierTag: p.isSameSupplier ? '同一サプライヤー' : '別サプライヤー',
            supplierTagClass: p.isSameSupplier ? 'same-supplier' : 'diff-supplier'
        }));
    }

    // ── Normal mode handlers ──────────────────────────────────────────
    handleMarkerSelect(event) {
        this.selectedSiteId = event.detail.selectedMarkerValue;
    }
    handleSiteCardClick(event) {
        this.selectedSiteId = event.currentTarget.dataset.id;
    }
    handleSupplierFilter(event) {
        this.filterSupplier = event.detail.value;
        this.selectedSiteId = null;
    }
    handlePrefectureFilter(event) {
        this.filterPrefecture = event.detail.value;
        this.selectedSiteId = null;
    }
    handleClearFilters() {
        this.filterSupplier = '';
        this.filterPrefecture = '';
        this.selectedSiteId = null;
    }
    get hasActiveFilter() {
        return this.filterSupplier || this.filterPrefecture;
    }
    handleNavigateSupplier() {
        if (!this.selectedSite?.supplierId) return;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.selectedSite.supplierId, objectApiName: 'Account', actionName: 'view' }
        });
    }
    handleBackToList() { this.selectedSiteId = null; }

    // ── Simulation handlers ───────────────────────────────────────────
    handleToggleSimMode() {
        this.simMode = !this.simMode;
        if (!this.simMode) {
            this.simResult = null;
            this.simPreset = '';
            this.simSelectedPrefs = [];
            this.simExpandedProduct = null;
        }
    }

    get simModeButtonLabel() {
        return this.simMode ? '通常モードに戻る' : '災害シミュレーション';
    }
    get simModeButtonVariant() {
        return this.simMode ? 'brand-outline' : 'destructive';
    }
    get simModeButtonIcon() {
        return this.simMode ? 'utility:back' : 'utility:warning';
    }

    handlePresetChange(event) {
        this.simPreset = event.detail.value;
        this.simSelectedPrefs = PRESET_PREFECTURES[this.simPreset] || [];
        this.simResult = null;
        this.simExpandedProduct = null;
    }

    get canRunSim() {
        return this.simSelectedPrefs.length > 0 && !this.simLoading;
    }
    get cannotRunSim() {
        return !this.canRunSim;
    }

    handleRunSimulation() {
        if (!this.canRunSim) return;
        this.simLoading = true;
        this.simResult = null;
        this.simExpandedProduct = null;
        simulateDisaster({ prefectures: this.simSelectedPrefs })
            .then(result => {
                this.simResult = result;
                this.simLoading = false;
            })
            .catch(err => {
                this.error = err?.body?.message ?? 'シミュレーション実行エラー';
                this.simLoading = false;
            });
    }

    handleProductCardClick(event) {
        const pid = event.currentTarget.dataset.id;
        this.simExpandedProduct = this.simExpandedProduct === pid ? null : pid;
    }

    handleScrollToOffload() {
        const el = this.template.querySelector('[data-id="offload-anchor"]');
        if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
}
