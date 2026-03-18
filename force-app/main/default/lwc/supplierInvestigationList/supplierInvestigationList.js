import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getInvestigations from '@salesforce/apex/SupplierInvestigationListController.getInvestigations';

export default class SupplierInvestigationList extends NavigationMixin(LightningElement) {
    @api recordId;
    items = [];
    isLoading = true;

    @wire(getInvestigations, { accountId: '$recordId' })
    wiredData({ data, error }) {
        this.isLoading = false;
        if (data) {
            this.items = data.map(si => ({
                ...si,
                statusClass: 'status-badge ' + this.getStatusClass(si.status),
                severityClass: si.severity ? 'severity-badge ' + this.getSeverityClass(si.severity) : '',
                overdueClass: si.isOverdue ? 'overdue' : '',
                hasSeverity: !!si.severity
            }));
        } else if (error) {
            console.error('Error', error);
        }
    }

    get hasItems() {
        return this.items.length > 0;
    }

    get statusSummary() {
        const counts = { '依頼中': 0, '調査中': 0, '回答済': 0, '対策実施中': 0, '完了': 0 };
        this.items.forEach(i => { if (counts[i.status] !== undefined) counts[i.status]++; });
        return Object.entries(counts)
            .filter(([, v]) => v > 0)
            .map(([k, v]) => ({ label: k, count: v, cls: 'summary-chip ' + this.getStatusClass(k) }));
    }

    getStatusClass(status) {
        const map = { '依頼中': 'requested', '調査中': 'investigating', '回答済': 'responded', '対策実施中': 'action', '完了': 'closed' };
        return map[status] || '';
    }

    getSeverityClass(sev) {
        const map = { '重大': 'critical', '重要': 'major', '軽微': 'minor' };
        return map[sev] || '';
    }

    handleRowClick(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: event.currentTarget.dataset.id, objectApiName: 'Supplier_Investigation__c', actionName: 'view' }
        });
    }
}
