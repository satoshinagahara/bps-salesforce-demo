import { LightningElement, api, wire } from 'lwc';
import getSupplierRFQHistory from '@salesforce/apex/SupplierRFQHistoryController.getSupplierRFQHistory';
import { NavigationMixin } from 'lightning/navigation';

export default class SupplierRfqHistory extends NavigationMixin(LightningElement) {
    @api recordId; // Account Id

    data = null;
    isLoading = true;

    @wire(getSupplierRFQHistory, { accountId: '$recordId' })
    wiredHistory(result) {
        this.isLoading = false;
        const { data, error } = result;
        if (data) {
            this.data = data;
        } else if (error) {
            console.error('Error loading supplier RFQ history', error);
        }
    }

    get hasData() {
        return this.data && this.data.totalQuotes > 0;
    }

    get stats() {
        if (!this.data) return {};
        return {
            total: this.data.totalQuotes,
            adopted: this.data.adoptedCount,
            responded: this.data.respondedCount,
            declined: this.data.declinedCount,
            adoptionRate: this.data.adoptionRate,
            avgScore: this.data.avgScore,
            adoptionRateClass: this.data.adoptionRate >= 30 ? 'stat-value good' : 'stat-value',
            scoreClass: this.data.avgScore >= 80 ? 'stat-value good' : this.data.avgScore >= 60 ? 'stat-value' : 'stat-value warn'
        };
    }

    get quotes() {
        if (!this.data || !this.data.quotes) return [];
        return this.data.quotes.map(q => ({
            ...q,
            statusClass: 'status-badge status-' + this.getStatusKey(q.Status),
            vsTargetClass: q.vsTarget != null ? (q.vsTarget <= 0 ? 'diff-good' : 'diff-bad') : '',
            vsTargetLabel: q.vsTarget != null ? (q.vsTarget > 0 ? '+' + q.vsTarget + '%' : q.vsTarget + '%') : '',
            rowClass: q.isSelected ? 'history-row selected-row' : 'history-row',
            adoptedIcon: q.isSelected
        }));
    }

    getStatusKey(status) {
        const map = { '依頼中': 'pending', '回答済': 'responded', '辞退': 'declined', '採用': 'adopted', '不採用': 'rejected' };
        return map[status] || 'default';
    }

    handleRowClick(event) {
        const rfqId = event.currentTarget.dataset.rfqId;
        if (rfqId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: rfqId, objectApiName: 'RFQ__c', actionName: 'view' }
            });
        }
    }
}
