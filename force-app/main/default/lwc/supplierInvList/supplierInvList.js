import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getInvestigationList from '@salesforce/apex/SupplierPortalController.getInvestigationList';

const FILTERS = [
    { key: 'all',       label: 'すべて' },
    { key: 'ongoing',   label: '対応中' },
    { key: 'responded', label: '回答済' },
    { key: 'completed', label: '完了' }
];

export default class SupplierInvList extends LightningElement {
    @api recordId;
    @api accountId;

    data;
    error;
    wiredResult;

    @track selectedFilter = 'ongoing';

    // View mode: 'list' | 'respond'
    viewMode = 'list';
    selectedInvestigationId;

    get targetAccountId() {
        return this.accountId || this.recordId || null;
    }

    get isListMode() { return this.viewMode === 'list'; }
    get isRespondMode() { return this.viewMode === 'respond'; }

    @wire(getInvestigationList, { accountId: '$targetAccountId', filter: '$selectedFilter' })
    wiredInvestigations(result) {
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
            ongoing: this.data?.ongoingCount ?? 0,
            responded: this.data?.respondedCount ?? 0,
            completed: this.data?.completedCount ?? 0
        };
        return FILTERS.map(f => ({
            ...f,
            count: counts[f.key] ?? 0,
            btnClass: this.selectedFilter === f.key
                ? 'sil-filter__btn sil-filter__btn--active'
                : 'sil-filter__btn'
        }));
    }

    get investigationRows() {
        if (!this.data?.items) return [];
        return this.data.items.map(r => ({
            ...r,
            dueLabel: r.responseDueDate ? this.fmtDate(r.responseDueDate) : '—',
            daysLabel: r.daysToDue != null
                ? (r.daysToDue < 0 ? `${Math.abs(r.daysToDue)}日超過` : `残 ${r.daysToDue}日`)
                : '',
            dueClass: r.daysToDue != null && r.daysToDue <= 7 && r.status !== '完了' && r.status !== '回答済'
                ? 'sil-card__meta-value sil-card__meta-value--warn'
                : 'sil-card__meta-value',
            statusBadgeClass: this.getStatusBadgeClass(r.status),
            severityBadgeClass: this.getSeverityBadgeClass(r.severity)
        }));
    }

    get totalLabel() {
        return `${this.data?.items?.length ?? 0} / ${this.data?.totalCount ?? 0} 件`;
    }

    getStatusBadgeClass(status) {
        if (status === '完了') return 'sil-badge sil-badge--ok';
        if (status === '回答済') return 'sil-badge sil-badge--inprogress';
        if (status === '対策実施中') return 'sil-badge sil-badge--inprogress';
        if (status === '調査中') return 'sil-badge sil-badge--warn';
        if (status === '依頼中') return 'sil-badge sil-badge--warn';
        return 'sil-badge sil-badge--muted';
    }

    getSeverityBadgeClass(severity) {
        if (severity === '重大') return 'sil-sev sil-sev--critical';
        if (severity === '重要') return 'sil-sev sil-sev--major';
        if (severity === '軽微') return 'sil-sev sil-sev--minor';
        return 'sil-sev sil-sev--muted';
    }

    handleFilterClick(event) {
        const key = event.currentTarget.dataset.filter;
        if (key) this.selectedFilter = key;
    }

    handleInvestigationClick(event) {
        const id = event.currentTarget.dataset.investigationId;
        this.selectedInvestigationId = id;
        this.viewMode = 'respond';
        if (typeof window !== 'undefined') window.scrollTo({ top: 0, behavior: 'smooth' });
    }

    async handleBackToList() {
        this.viewMode = 'list';
        this.selectedInvestigationId = undefined;
        await refreshApex(this.wiredResult);
    }

    // === utils ===
    fmtDate(d) {
        if (!d) return '';
        const dt = typeof d === 'string' ? new Date(d) : d;
        return `${dt.getFullYear()}/${String(dt.getMonth() + 1).padStart(2, '0')}/${String(dt.getDate()).padStart(2, '0')}`;
    }

    extractError(err) {
        if (err?.body?.message) return err.body.message;
        if (Array.isArray(err?.body)) return err.body.map(e => e.message).join(', ');
        return err?.message || 'エラーが発生しました';
    }
}
