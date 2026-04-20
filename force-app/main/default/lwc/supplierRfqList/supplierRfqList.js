import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getRfqList from '@salesforce/apex/SupplierPortalController.getRfqList';

const FILTERS = [
    { key: 'all',      label: 'すべて' },
    { key: 'pending',  label: '未回答' },
    { key: 'answered', label: '回答済' },
    { key: 'closed',   label: '採用/不採用/辞退' }
];

export default class SupplierRfqList extends LightningElement {
    @api recordId;
    @api accountId;

    data;
    error;
    wiredResult;

    @track selectedFilter = 'all';

    // View mode: 'list' | 'respond'
    viewMode = 'list';
    selectedRfqId;

    get targetAccountId() {
        return this.accountId || this.recordId || null;
    }

    get isListMode() { return this.viewMode === 'list'; }
    get isRespondMode() { return this.viewMode === 'respond'; }

    @wire(getRfqList, { accountId: '$targetAccountId', filter: '$selectedFilter' })
    wiredRfqs(result) {
        this.wiredResult = result;
        if (result.data) {
            this.data = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = this.extractError(result.error);
            this.data = undefined;
        }
    }

    get isLoading() {
        return !this.data && !this.error;
    }

    get hasItems() {
        return this.data && this.data.items.length > 0;
    }

    get filterButtons() {
        const counts = {
            all: this.data?.totalCount ?? 0,
            pending: this.data?.pendingCount ?? 0,
            answered: this.data?.answeredCount ?? 0,
            closed: this.data?.closedCount ?? 0
        };
        return FILTERS.map(f => ({
            ...f,
            count: counts[f.key] ?? 0,
            btnClass: this.selectedFilter === f.key
                ? 'srl-filter__btn srl-filter__btn--active'
                : 'srl-filter__btn'
        }));
    }

    get rfqRows() {
        if (!this.data?.items) return [];
        return this.data.items.map(r => ({
            ...r,
            dueLabel: r.dueDate ? this.fmtDate(r.dueDate) : '—',
            daysLabel: r.daysToDue != null
                ? (r.daysToDue < 0 ? `${Math.abs(r.daysToDue)}日超過` : `残 ${r.daysToDue}日`)
                : '',
            dueClass: r.daysToDue != null && r.daysToDue <= 7 && r.quoteStatus === '依頼中'
                ? 'srl-card__meta-value srl-card__meta-value--warn'
                : 'srl-card__meta-value',
            quoteBadgeClass: this.getQuoteBadgeClass(r.quoteStatus),
            qtyLabel: r.requiredQuantity != null ? this.fmtNumber(r.requiredQuantity) : '—',
            priceLabel: r.unitPrice != null ? `¥${this.fmtNumber(r.unitPrice)}` : '—'
        }));
    }

    get totalLabel() {
        return `${this.data?.items?.length ?? 0} / ${this.data?.totalCount ?? 0} 件`;
    }

    getQuoteBadgeClass(status) {
        if (status === '採用') return 'srl-badge srl-badge--ok';
        if (status === '不採用' || status === '辞退') return 'srl-badge srl-badge--muted';
        if (status === '依頼中') return 'srl-badge srl-badge--warn';
        return 'srl-badge srl-badge--inprogress';
    }

    handleFilterClick(event) {
        const key = event.currentTarget.dataset.filter;
        if (key) this.selectedFilter = key;
    }

    handleRfqClick(event) {
        const rfqId = event.currentTarget.dataset.rfqId;
        this.selectedRfqId = rfqId;
        this.viewMode = 'respond';
        if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'smooth' });
    }

    async handleBackToList() {
        this.viewMode = 'list';
        this.selectedRfqId = undefined;
        // 回答送信後に戻ってきた可能性があるため refresh
        await refreshApex(this.wiredResult);
    }

    // === utils ===
    fmtDate(d) {
        if (!d) return '';
        const dt = typeof d === 'string' ? new Date(d) : d;
        return `${dt.getFullYear()}/${String(dt.getMonth() + 1).padStart(2, '0')}/${String(dt.getDate()).padStart(2, '0')}`;
    }

    fmtNumber(n) {
        if (n == null) return '0';
        return new Intl.NumberFormat('ja-JP').format(n);
    }

    extractError(err) {
        if (err?.body?.message) return err.body.message;
        if (Array.isArray(err?.body)) return err.body.map(e => e.message).join(', ');
        return err?.message || 'エラーが発生しました';
    }
}
