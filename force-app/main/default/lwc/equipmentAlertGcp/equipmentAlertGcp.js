import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getAssetWithAlerts from '@salesforce/apex/EquipmentAlertController.getAssetWithAlerts';

export default class EquipmentAlertGcp extends LightningElement {
    @api recordId;
    context;
    error;
    _wiredResult;

    @wire(getAssetWithAlerts, { assetId: '$recordId' })
    wiredCtx(result) {
        this._wiredResult = result;
        if (result.data) {
            this.context = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error.body?.message || 'データ取得エラー';
        }
    }

    get hasAlerts() {
        return this.context && this.context.alerts && this.context.alerts.length > 0;
    }

    get latestAlert() {
        return this.hasAlerts ? this.context.alerts[0] : null;
    }

    get hasMoreAlerts() {
        return this.hasAlerts && this.context.alerts.length > 1;
    }

    get pastAlerts() {
        return this.hasAlerts ? this.context.alerts.slice(1) : [];
    }

    get hasError() {
        return !!this.error;
    }

    handleRefresh() {
        if (this._wiredResult) {
            refreshApex(this._wiredResult);
        }
    }
}
