import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getStatusData from '@salesforce/apex/ProcurementStatusController.getStatusData';

const STATUS_FILTERS = {
    open:       { label: 'オープン',       statuses: ['発行済', '評価中'] },
    evaluating: { label: '評価中',         statuses: ['評価中'] },
    due:        { label: '期限間近/超過',  statuses: ['発行済', '評価中'], dueOnly: true },
    decided:    { label: '決定済',         statuses: ['決定済'] }
};

const STATUS_BADGE_COLOR = {
    '発行済':     '#3498db',
    '評価中':     '#f39c12',
    '決定済':     '#27ae60',
    '下書き':     '#95a5a6',
    'キャンセル': '#e74c3c'
};

const CATEGORY_COLOR = {
    '新規部品':     '#3498db',
    'コスト見直し': '#f39c12',
    '代替調達':     '#9b59b6',
    '緊急調達':     '#e74c3c'
};

export default class ProcurementStatusBoard extends NavigationMixin(LightningElement) {
    data;
    error;

    selectedStatusKey = 'open';
    selectedCategory = null;

    @wire(getStatusData)
    wiredData({ data, error }) {
        if (data) {
            this.data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.data = undefined;
        }
    }

    // ========= カウント =========
    get openCount()       { return this.data?.openCount ?? 0; }
    get evaluatingCount() { return this.data?.evaluatingCount ?? 0; }
    get decidedCount()    { return this.data?.decidedCount ?? 0; }
    get dueSoonCount()    { return this.data?.dueSoonCount ?? 0; }
    get totalRfqCount()   { return this.data?.rfqList?.length ?? 0; }

    get dataLoaded() {
        return this.data !== undefined && this.data !== null;
    }

    // ========= フィルタチップ =========
    get statusChips() {
        return [
            this.makeStatusChip('open',       'オープン',       this.openCount),
            this.makeStatusChip('evaluating', '評価中',         this.evaluatingCount),
            this.makeStatusChip('due',        '期限間近/超過',  this.dueSoonCount),
            this.makeStatusChip('decided',    '決定済',         this.decidedCount)
        ];
    }

    makeStatusChip(key, label, count) {
        const isActive = this.selectedStatusKey === key;
        return {
            key,
            label,
            count,
            cssClass: `chip-status chip-status--${key}${isActive ? ' chip-status--active' : ''}`
        };
    }

    get categoryChips() {
        const byCategory = this.data?.byCategory || {};
        return Object.entries(byCategory)
            .sort((a, b) => b[1] - a[1])
            .map(([cat, count]) => ({
                key: cat,
                label: cat,
                count: count,
                cssClass: `chip-cat${this.selectedCategory === cat ? ' chip-cat--active' : ''}`,
                style: `background-color: ${CATEGORY_COLOR[cat] || '#95a5a6'}`
            }));
    }

    get hasCategoriesAvailable() {
        return this.categoryChips.length > 0;
    }

    get hasActiveFilter() {
        return this.selectedStatusKey !== 'open' || this.selectedCategory !== null;
    }

    // ========= RFQ一覧 =========
    get filteredRfqItems() {
        const list = this.data?.rfqList || [];
        const filter = STATUS_FILTERS[this.selectedStatusKey];
        if (!filter) return [];

        return list
            .filter(r => {
                if (!filter.statuses.includes(r.status)) return false;
                if (filter.dueOnly && !(r.isDueSoon || r.isOverdue)) return false;
                if (this.selectedCategory && r.category !== this.selectedCategory) return false;
                return true;
            })
            .map(r => this.decorateRfq(r));
    }

    decorateRfq(r) {
        const rowClass = r.isOverdue
            ? 'rfq-row rfq-row--overdue'
            : r.isDueSoon
                ? 'rfq-row rfq-row--due-soon'
                : 'rfq-row';
        return {
            id: r.id,
            name: r.name,
            title: r.title,
            status: r.status,
            partNumber: r.partNumber,
            dueDate: r.dueDate,
            responseRate: r.totalQuotes > 0 ? `${r.respondedQuotes}/${r.totalQuotes}` : '0/0',
            lowestPrice: r.lowestPrice != null ? `¥${Number(r.lowestPrice).toLocaleString()}` : '-',
            targetPrice: r.targetPrice != null ? `¥${Number(r.targetPrice).toLocaleString()}` : '-',
            rowClass,
            statusStyle: `background-color: ${STATUS_BADGE_COLOR[r.status] || '#95a5a6'}`,
            dueBadge: r.isOverdue ? '期限超過' : r.isDueSoon ? '期限間近' : '',
            hasDueBadge: r.isOverdue || r.isDueSoon,
            dueBadgeClass: r.isOverdue ? 'due-badge due-badge--overdue' : 'due-badge due-badge--soon',
            categoryDisplay: r.category || '',
            hasCategory: !!r.category
        };
    }

    get rfqHeaderText() {
        return `RFQ一覧 (該当 ${this.filteredRfqItems.length}件 / 全 ${this.totalRfqCount}件)`;
    }

    get hasFilteredRfqs() {
        return this.filteredRfqItems.length > 0;
    }

    get hasNoFilteredRfqs() {
        return this.dataLoaded && this.filteredRfqItems.length === 0;
    }

    // ========= 見積回答フィード =========
    get quoteItems() {
        const quotes = this.data?.recentQuotes || [];
        return quotes.map((q, idx) => ({
            key: `quote-${idx}`,
            rfqId: q.rfqId,
            rfqName: q.rfqName,
            partNumber: q.partNumber,
            supplierName: q.supplierName || '-',
            leadTimeDays: q.leadTimeDays != null ? `LT ${q.leadTimeDays}日` : 'LT -',
            relativeDate: this.formatRelativeDate(q.responseDate),
            isCheapest: q.isCheapest,
            priceDisplay: q.unitPrice != null ? `¥${Number(q.unitPrice).toLocaleString()}` : '¥-',
            rowClass: q.isCheapest ? 'quote-row quote-row--best' : 'quote-row'
        }));
    }

    get hasQuotes() {
        return this.quoteItems.length > 0;
    }

    get hasNoQuotes() {
        return this.dataLoaded && this.quoteItems.length === 0;
    }

    formatRelativeDate(dateStr) {
        if (!dateStr) return '';
        const d = new Date(dateStr);
        if (isNaN(d.getTime())) return dateStr;
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        d.setHours(0, 0, 0, 0);
        const diffDays = Math.round((today.getTime() - d.getTime()) / (1000 * 60 * 60 * 24));
        if (diffDays === 0) return '今日';
        if (diffDays === 1) return '昨日';
        if (diffDays > 1 && diffDays < 7) return `${diffDays}日前`;
        return dateStr;
    }

    // ========= ハンドラ =========
    handleStatusChip(event) {
        const key = event.currentTarget.dataset.key;
        if (key && STATUS_FILTERS[key]) {
            this.selectedStatusKey = key;
        }
    }

    handleCategoryChip(event) {
        const key = event.currentTarget.dataset.key;
        this.selectedCategory = (this.selectedCategory === key) ? null : key;
    }

    handleClearFilters() {
        this.selectedStatusKey = 'open';
        this.selectedCategory = null;
    }

    handleRFQClick(event) {
        const rfqId = event.currentTarget.dataset.id;
        if (rfqId) this.navigateToRfq(rfqId);
    }

    handleQuoteClick(event) {
        const rfqId = event.currentTarget.dataset.rfqId;
        if (rfqId) this.navigateToRfq(rfqId);
    }

    navigateToRfq(rfqId) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: rfqId,
                actionName: 'view'
            }
        });
    }
}
