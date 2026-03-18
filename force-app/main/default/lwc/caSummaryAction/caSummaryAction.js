import { LightningElement, api } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import generateSummary from '@salesforce/apex/CASummaryController.generateSummary';

export default class CaSummaryAction extends LightningElement {
    _recordId;
    summary = '';
    isLoading = false;
    hasResult = false;
    error = '';
    summaryLines = [];

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        if (value) {
            this.generate();
        }
    }

    generate() {
        this.isLoading = true;
        this.hasResult = false;
        this.error = '';
        this.summary = '';
        this.summaryLines = [];

        generateSummary({ caId: this._recordId })
            .then(result => {
                this.summary = result;
                this.summaryLines = this.parseSummary(result);
                this.hasResult = true;
                this.isLoading = false;
            })
            .catch(err => {
                this.error = err.body ? err.body.message : err.message;
                this.isLoading = false;
            });
    }

    parseSummary(text) {
        if (!text) return [];
        const lines = text.split('\n').filter(l => l.trim().length > 0);
        return lines.map((line, idx) => {
            let className = 'summary-line';
            if (idx === 0) {
                className = 'summary-headline';
            } else if (line.includes('リスク') || line.includes('警告') || line.includes('超過') || line.includes('注意') || line.includes('懸念')) {
                className = 'summary-risk';
            }
            return { key: 'line-' + idx, text: line, className };
        });
    }

    handleClose() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleRegenerate() {
        this.generate();
    }

    get generatedTime() {
        const now = new Date();
        return now.getFullYear() + '/'
            + String(now.getMonth() + 1).padStart(2, '0') + '/'
            + String(now.getDate()).padStart(2, '0') + ' '
            + String(now.getHours()).padStart(2, '0') + ':'
            + String(now.getMinutes()).padStart(2, '0');
    }
}
