import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getStatusData from '@salesforce/apex/ProcurementStatusController.getStatusData';

export default class ProcurementStatusBoard extends NavigationMixin(LightningElement) {
    data;
    error;

    openCount = 0;
    evaluatingCount = 0;
    decidedCount = 0;
    dueSoonCount = 0;

    rfqItems = [];
    quoteItems = [];
    categoryItems = [];

    @wire(getStatusData)
    wiredData({ data, error }) {
        if (data) {
            this.data = data;
            this.error = undefined;
            this.openCount = data.openCount || 0;
            this.evaluatingCount = data.evaluatingCount || 0;
            this.decidedCount = data.decidedCount || 0;
            this.dueSoonCount = data.dueSoonCount || 0;
            this.processRFQs(data.rfqList || []);
            this.processQuotes(data.recentQuotes || []);
            this.processCategories(data.byCategory || {});
        } else if (error) {
            this.error = error;
        }
    }

    processRFQs(rfqList) {
        const statusColorMap = {
            '発行済': '#3498db',
            '評価中': '#f39c12',
            '決定済': '#27ae60',
            '下書き': '#95a5a6',
            'キャンセル': '#e74c3c'
        };
        this.rfqItems = rfqList
            .filter(r => r.status === '発行済' || r.status === '評価中')
            .map(r => ({
                id: r.id,
                name: r.name,
                title: r.title,
                status: r.status,
                partNumber: r.partNumber,
                dueDate: r.dueDate,
                responseRate: r.totalQuotes > 0
                    ? `${r.respondedQuotes}/${r.totalQuotes}`
                    : '0/0',
                responseRatePct: r.totalQuotes > 0
                    ? Math.round((r.respondedQuotes / r.totalQuotes) * 100)
                    : 0,
                lowestPrice: r.lowestPrice != null ? `¥${Number(r.lowestPrice).toLocaleString()}` : '-',
                targetPrice: r.targetPrice != null ? `¥${Number(r.targetPrice).toLocaleString()}` : '-',
                isDueSoon: r.isDueSoon,
                isOverdue: r.isOverdue,
                rowClass: r.isOverdue ? 'rfq-row rfq-row--overdue' : r.isDueSoon ? 'rfq-row rfq-row--due-soon' : 'rfq-row',
                dueBadge: r.isOverdue ? '期限超過' : r.isDueSoon ? '期限間近' : '',
                hasDueBadge: r.isOverdue || r.isDueSoon,
                dueBadgeClass: r.isOverdue ? 'due-badge due-badge--overdue' : 'due-badge due-badge--soon',
                statusStyle: `background-color: ${statusColorMap[r.status] || '#95a5a6'}`,
                lowResponse: r.totalQuotes > 0 && r.respondedQuotes < r.totalQuotes
            }));
    }

    processQuotes(quotes) {
        this.quoteItems = quotes.map((q, idx) => ({
            key: `quote-${idx}`,
            rfqName: q.rfqName,
            partNumber: q.partNumber,
            supplierName: q.supplierName || '-',
            leadTimeDays: q.leadTimeDays != null ? `${q.leadTimeDays}日` : '-',
            responseDate: q.responseDate,
            isCheapest: q.isCheapest,
            priceDisplay: q.isCheapest
                ? `★最安値 ¥${q.unitPrice != null ? Number(q.unitPrice).toLocaleString() : '-'}`
                : `¥${q.unitPrice != null ? Number(q.unitPrice).toLocaleString() : '-'}`,
            priceClass: q.isCheapest ? 'price-value price-value--best' : 'price-value'
        }));
    }

    processCategories(byCategory) {
        const colorMap = {
            '新規部品': '#3498db',
            'コスト見直し': '#f39c12',
            '代替調達': '#9b59b6',
            '緊急調達': '#e74c3c'
        };
        this.categoryItems = Object.entries(byCategory)
            .sort((a, b) => b[1] - a[1])
            .map(([key, value]) => ({
                label: key,
                count: value,
                style: `background-color: ${colorMap[key] || '#95a5a6'}`
            }));
    }

    get hasRFQs() {
        return this.rfqItems.length > 0;
    }

    get hasQuotes() {
        return this.quoteItems.length > 0;
    }

    get hasCategories() {
        return this.categoryItems.length > 0;
    }

    get dueSoonClass() {
        return this.dueSoonCount > 0 ? 'kpi-card kpi-card--warning' : 'kpi-card';
    }

    handleRFQClick(event) {
        const rfqId = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: rfqId,
                actionName: 'view'
            }
        });
    }
}
