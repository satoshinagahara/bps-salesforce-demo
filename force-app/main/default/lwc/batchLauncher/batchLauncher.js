import { LightningElement, wire } from 'lwc';
import getAvailableBatches from '@salesforce/apex/BatchLauncherController.getAvailableBatches';
import launchBatch from '@salesforce/apex/BatchLauncherController.launchBatch';
import getJobStatus from '@salesforce/apex/BatchLauncherController.getJobStatus';

const POLL_INTERVAL = 15000;
const MAX_RETRIES = 3;

export default class BatchLauncher extends LightningElement {
    batches = [];
    _pollingIntervals = {};
    _retryCount = {};

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
        this._retryCount[batchName] = 0;
        const intervalId = setInterval(async () => {
            try {
                const status = await getJobStatus({ jobId });
                this._retryCount[batchName] = 0;
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
                this._retryCount[batchName]++;
                if (this._retryCount[batchName] >= MAX_RETRIES) {
                    clearInterval(intervalId);
                    this.updateBatch(batchName, { isRunning: false, statusMessage: 'ステータス確認エラー（バッチは実行中の可能性があります）', statusClass: '' });
                }
            }
        }, POLL_INTERVAL);
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
