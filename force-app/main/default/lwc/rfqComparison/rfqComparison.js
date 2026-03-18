import { LightningElement, api, wire } from 'lwc';
import getRFQWithQuotes from '@salesforce/apex/RFQComparisonController.getRFQWithQuotes';
import adoptQuote from '@salesforce/apex/RFQComparisonController.adoptQuote';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';

export default class RfqComparison extends LightningElement {
    @api recordId; // RFQ__c Id

    rfqDetail = null;
    isLoading = true;
    _wiredDetail;

    @wire(getRFQWithQuotes, { rfqId: '$recordId' })
    wiredDetail(result) {
        this._wiredDetail = result;
        const { data, error } = result;
        this.isLoading = false;
        if (data) {
            this.rfqDetail = data;
        } else if (error) {
            console.error('Error loading RFQ detail', error);
        }
    }

    get hasData() {
        return this.rfqDetail != null;
    }

    get quotes() {
        if (!this.rfqDetail || !this.rfqDetail.quotes) return [];
        return this.rfqDetail.quotes.map(q => {
            const priceDiff = this.rfqDetail.TargetUnitPrice && q.UnitPrice
                ? ((q.UnitPrice - this.rfqDetail.TargetUnitPrice) / this.rfqDetail.TargetUnitPrice * 100).toFixed(1)
                : null;
            const costDiff = this.rfqDetail.CurrentUnitCost && q.UnitPrice
                ? ((q.UnitPrice - this.rfqDetail.CurrentUnitCost) / this.rfqDetail.CurrentUnitCost * 100).toFixed(1)
                : null;
            return {
                ...q,
                priceDiffPercent: priceDiff,
                priceDiffClass: priceDiff !== null ? (parseFloat(priceDiff) <= 0 ? 'diff-good' : 'diff-bad') : '',
                costDiffPercent: costDiff,
                costDiffClass: costDiff !== null ? (parseFloat(costDiff) <= 0 ? 'diff-good' : 'diff-bad') : '',
                priceClass: q.isBestPrice ? 'best-value' : '',
                leadTimeClass: q.isBestLeadTime ? 'best-value' : '',
                statusClass: 'status-badge status-' + this.getStatusKey(q.Status),
                isAdoptable: this.rfqDetail.Status !== '決定済' && q.Status === '回答済',
                rowClass: q.isSelected ? 'quote-row selected-row' : 'quote-row'
            };
        });
    }

    get quoteCount() {
        return this.rfqDetail ? this.rfqDetail.quoteCount : 0;
    }

    get isDecided() {
        return this.rfqDetail && this.rfqDetail.Status === '決定済';
    }

    get headerInfo() {
        if (!this.rfqDetail) return {};
        return {
            partNumber: this.rfqDetail.PartNumber || '',
            category: this.rfqDetail.Category || '',
            dueDate: this.rfqDetail.DueDate || '',
            requiredQty: this.rfqDetail.RequiredQuantity || '',
            targetPrice: this.rfqDetail.TargetUnitPrice,
            currentCost: this.rfqDetail.CurrentUnitCost,
            partSpec: this.rfqDetail.PartSpec || ''
        };
    }

    getStatusKey(status) {
        const map = { '依頼中': 'pending', '回答済': 'responded', '辞退': 'declined', '採用': 'adopted', '不採用': 'rejected' };
        return map[status] || 'default';
    }

    async handleAdopt(event) {
        const quoteId = event.currentTarget.dataset.quoteId;
        const supplierName = event.currentTarget.dataset.supplierName;
        this.isLoading = true;
        try {
            await adoptQuote({ rfqId: this.recordId, quoteId: quoteId });
            this.dispatchEvent(new ShowToastEvent({
                title: '採用決定',
                message: `${supplierName} の見積を採用しました`,
                variant: 'success'
            }));
            await refreshApex(this._wiredDetail);
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'エラー',
                message: error.body ? error.body.message : error.message,
                variant: 'error'
            }));
        } finally {
            this.isLoading = false;
        }
    }
}
