import { LightningElement, wire } from 'lwc';
import getAvailableBatches from '@salesforce/apex/BatchLauncherController.getAvailableBatches';
import launchBatch from '@salesforce/apex/BatchLauncherController.launchBatch';
import getJobStatus from '@salesforce/apex/BatchLauncherController.getJobStatus';

export default class BatchLauncher extends LightningElement {
    batches = [];
    _pollingIntervals = {};

    @wire(getAvailableBatches)
    wiredBatches({ data, error }) {
        if (data) {
            this.batches = data.map(b => ({
                ...b,
                isRunning: false,
                statusMessage: null,
                statusClass: ''
            }));
        }
    }

    get isEmpty() {
        return this.batches.length === 0;
    }

    async handleLaunch(event) {
        const batchName = event.target.dataset.batchName;
        this.updateBatch(batchName, { isRunning: true, statusMessage: '起動中...', statusClass: '' });

        try {
            const result = await launchBatch({ batchName });
            if (result.errorMessage) {
                this.updateBatch(batchName, {
                    isRunning: false,
                    statusMessage: 'エラー: ' + result.errorMessage,
                    statusClass: 'slds-badge_error'
                });
            } else {
                this.updateBatch(batchName, {
                    isRunning: true,
                    statusMessage: '実行中...',
                    statusClass: ''
                });
                this.pollJobStatus(batchName, result.jobId);
            }
        } catch (error) {
            this.updateBatch(batchName, {
                isRunning: false,
                statusMessage: 'エラー: ' + (error.body ? error.body.message : error.message),
                statusClass: 'slds-badge_error'
            });
        }
    }

    pollJobStatus(batchName, jobId) {
        const intervalId = setInterval(async () => {
            try {
                const status = await getJobStatus({ jobId });
                if (status.isComplete) {
                    clearInterval(intervalId);
                    const msg = status.status === 'Completed'
                        ? `完了（${status.processed}件処理、${status.errors}件エラー）`
                        : `${status.status}`;
                    const cls = status.status === 'Completed' && status.errors === 0
                        ? 'slds-badge_success'
                        : 'slds-badge_error';
                    this.updateBatch(batchName, {
                        isRunning: false,
                        statusMessage: msg,
                        statusClass: cls
                    });
                } else {
                    this.updateBatch(batchName, {
                        isRunning: true,
                        statusMessage: `実行中... (${status.processed}/${status.total})`,
                        statusClass: ''
                    });
                }
            } catch (e) {
                clearInterval(intervalId);
                this.updateBatch(batchName, { isRunning: false, statusMessage: 'ステータス確認エラー', statusClass: '' });
            }
        }, 5000);
        this._pollingIntervals[batchName] = intervalId;
    }

    updateBatch(batchName, updates) {
        this.batches = this.batches.map(b => {
            if (b.name === batchName) {
                return { ...b, ...updates };
            }
            return b;
        });
    }

    disconnectedCallback() {
        Object.values(this._pollingIntervals).forEach(id => clearInterval(id));
    }
}
