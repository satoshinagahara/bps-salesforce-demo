import { LightningElement, api, wire, track } from 'lwc';
import getSupplierImpact from '@salesforce/apex/SupplierImpactController.getSupplierImpact';

const PART_COLUMNS = [
    { label: '部品番号', fieldName: 'partNumber', type: 'text', initialWidth: 120 },
    { label: '部品名', fieldName: 'partName', type: 'text', initialWidth: 180 },
    {
        label: '製品',
        fieldName: 'productUrl',
        type: 'url',
        initialWidth: 160,
        typeAttributes: { label: { fieldName: 'productLabel' }, target: '_self' }
    },
    {
        label: '数量',
        fieldName: 'quantity',
        type: 'number',
        initialWidth: 70,
        cellAttributes: { alignment: 'right' },
        typeAttributes: { minimumFractionDigits: 0, maximumFractionDigits: 2 }
    },
    { label: '単位', fieldName: 'uom', type: 'text', initialWidth: 50, cellAttributes: { alignment: 'center' } },
    {
        label: '単価',
        fieldName: 'unitCost',
        type: 'currency',
        initialWidth: 95,
        cellAttributes: { alignment: 'right' },
        typeAttributes: { currencyCode: 'JPY', minimumFractionDigits: 0, maximumFractionDigits: 0 }
    },
    {
        label: '小計',
        fieldName: 'extendedCost',
        type: 'currency',
        initialWidth: 100,
        cellAttributes: { alignment: 'right' },
        typeAttributes: { currencyCode: 'JPY', minimumFractionDigits: 0, maximumFractionDigits: 0 }
    },
    { label: 'LT', fieldName: 'leadTime', type: 'text', initialWidth: 80 },
    { label: '', fieldName: 'sharedBadge', type: 'text', initialWidth: 90 }
];

export default class SupplierImpactMap extends LightningElement {
    @api recordId;

    @track data = null;
    @track error = null;
    @track isLoading = true;

    partColumns = PART_COLUMNS;

    @wire(getSupplierImpact, { accountId: '$recordId' })
    wiredData({ data, error }) {
        this.isLoading = false;
        if (data) {
            this.data = data;
            this.error = null;
        } else if (error) {
            this.error = error?.body?.message ?? 'データの取得に失敗しました';
            this.data = null;
        }
    }

    // ── Capacity alerts ──────────────────────────────────────────────
    get totalCapacityAlerts() { return this.data?.totalCapacityAlerts ?? 0; }
    get hasCapacityAlerts() { return this.totalCapacityAlerts > 0; }
    get capacityAlertMessage() {
        return this.totalCapacityAlerts + ' 部品のキャパシティが逼迫しています（稼働率80%超）';
    }

    // ── Summary KPIs ─────────────────────────────────────────────────
    get hasData() { return this.data && this.data.totalParts > 0; }
    get isEmpty() { return !this.isLoading && !this.error && !this.hasData; }

    get totalParts() { return this.data?.totalParts ?? 0; }
    get totalProducts() { return this.data?.totalProducts ?? 0; }
    get totalSupplyCost() {
        if (!this.data) return '¥0';
        return '¥' + Math.round(this.data.totalSupplyCost).toLocaleString();
    }
    get sharedPartCount() { return this.data?.sharedPartCount ?? 0; }

    // ── Product dependency bars ──────────────────────────────────────
    get productBars() {
        if (!this.data?.products) return [];
        return this.data.products
            .map(p => {
                const dep = p.dependency;
                let riskLevel, riskLabel, barClass;
                if (dep >= 50) {
                    riskLevel = 'high';
                    riskLabel = '高リスク';
                    barClass = 'dep-bar risk-high';
                } else if (dep >= 30) {
                    riskLevel = 'medium';
                    riskLabel = '中リスク';
                    barClass = 'dep-bar risk-medium';
                } else {
                    riskLevel = 'low';
                    riskLabel = '';
                    barClass = 'dep-bar risk-low';
                }
                return {
                    productId: p.productId,
                    productName: p.productName,
                    productCode: p.productCode,
                    productUrl: '/lightning/r/Product2/' + p.productId + '/view',
                    dependency: dep,
                    dependencyLabel: dep + '%',
                    supplierCost: p.supplierCost,
                    supplierCostLabel: '¥' + Math.round(p.supplierCost).toLocaleString(),
                    bomTotalCost: p.bomTotalCost,
                    partCount: p.partCount,
                    capacityAlerts: p.capacityAlerts || 0,
                    hasCapAlerts: (p.capacityAlerts || 0) > 0,
                    capAlertLabel: (p.capacityAlerts || 0) + '件 逼迫',
                    riskLevel,
                    riskLabel,
                    hasRiskBadge: dep >= 30,
                    riskBadgeClass: 'risk-badge risk-badge-' + riskLevel,
                    barWidth: 'width:' + Math.max(dep, 2) + '%',
                    barClass
                };
            })
            .sort((a, b) => b.dependency - a.dependency);
    }

    get hasHighRisk() {
        return this.productBars.some(p => p.riskLevel === 'high');
    }

    get hasMediumRisk() {
        return this.productBars.some(p => p.riskLevel === 'medium');
    }

    get riskWarningMessage() {
        const high = this.productBars.filter(p => p.riskLevel === 'high').length;
        const medium = this.productBars.filter(p => p.riskLevel === 'medium').length;
        const parts = [];
        if (high > 0) parts.push(`高リスク(50%以上) ${high}製品`);
        if (medium > 0) parts.push(`中リスク(30%以上) ${medium}製品`);
        return parts.join('、') + ' — 供給停止時の影響に注意してください。';
    }

    get hasRiskWarning() {
        return this.hasHighRisk || this.hasMediumRisk;
    }

    // ── Parts table ──────────────────────────────────────────────────
    get partRows() {
        if (!this.data?.parts) return [];
        return this.data.parts.map(p => ({
            ...p,
            productUrl: '/lightning/r/Product2/' + p.productId + '/view',
            productLabel: p.productCode ? p.productCode + ' ' + p.productName : p.productName,
            sharedBadge: p.isShared ? '★ 共通部品' : ''
        }));
    }

    // ── Expand/Collapse parts ────────────────────────────────────────
    @track showParts = false;

    get partsToggleLabel() {
        return this.showParts ? '供給部品一覧を閉じる' : '供給部品一覧を表示';
    }
    get partsToggleIcon() {
        return this.showParts ? 'utility:chevronup' : 'utility:chevrondown';
    }

    handleToggleParts() {
        this.showParts = !this.showParts;
    }
}
