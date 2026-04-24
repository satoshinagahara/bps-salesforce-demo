import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getFullRecord from '@salesforce/apex/IdpSupplierQuoteController.getFullRecord';
import startJudgment from '@salesforce/apex/IdpSupplierQuoteController.startJudgment';
import markAsConfirmed from '@salesforce/apex/IdpSupplierQuoteController.markAsConfirmed';
import clearIdpResult from '@salesforce/apex/IdpSupplierQuoteController.clearIdpResult';

const STATUS_ENTERED = '担当者入力完了';
const STATUS_AWAITING_CHECK = 'AI判定待ち';
const STATUS_REVIEWING = '担当者確認中';
const STATUS_CONFIRMED = '担当者確認済';

const FIELD_SPECS = [
    { key: 'Supplier', label: 'サプライヤー', type: 'lookup',
      humanApiName: 'Supplier__c', humanNameRel: 'Supplier__r',
      aiField: 'AI_Supplier_Text__c', confField: 'AI_Supplier_Confidence__c',
      levelField: 'Supplier_Discrepancy_Level__c', reasonField: 'Supplier_Discrepancy_Reason__c' },
    { key: 'Unit_Price', label: '単価', type: 'currency',
      humanApiName: 'Unit_Price__c',
      aiField: 'AI_Unit_Price__c', confField: 'AI_Unit_Price_Confidence__c',
      levelField: 'Unit_Price_Discrepancy_Level__c', reasonField: 'Unit_Price_Discrepancy_Reason__c' },
    { key: 'Lead_Time_Days', label: '納期日数', type: 'number',
      humanApiName: 'Lead_Time_Days__c',
      aiField: 'AI_Lead_Time_Days__c', confField: 'AI_Lead_Time_Days_Confidence__c',
      levelField: 'Lead_Time_Days_Discrepancy_Level__c', reasonField: 'Lead_Time_Days_Discrepancy_Reason__c' },
    { key: 'MOQ', label: 'MOQ', type: 'number',
      humanApiName: 'MOQ__c',
      aiField: 'AI_MOQ__c', confField: 'AI_MOQ_Confidence__c',
      levelField: 'MOQ_Discrepancy_Level__c', reasonField: 'MOQ_Discrepancy_Reason__c' },
    { key: 'Manufacturing_Site', label: '製造拠点', type: 'lookup',
      humanApiName: 'Manufacturing_Site__c', humanNameRel: 'Manufacturing_Site__r',
      aiField: 'AI_Manufacturing_Site__c', confField: 'AI_Manufacturing_Site_Confidence__c',
      levelField: 'Manufacturing_Site_Discrepancy_Level__c', reasonField: 'Manufacturing_Site_Discrepancy_Reason__c' },
    { key: 'Valid_Until', label: '有効期限', type: 'date',
      humanApiName: 'Valid_Until__c',
      aiField: 'AI_Valid_Until__c', confField: 'AI_Valid_Until_Confidence__c',
      levelField: 'Valid_Until_Discrepancy_Level__c', reasonField: 'Valid_Until_Discrepancy_Reason__c' },
    { key: 'Response_Date', label: '回答日', type: 'date',
      humanApiName: 'Response_Date__c',
      aiField: 'AI_Response_Date__c', confField: 'AI_Response_Date_Confidence__c',
      levelField: 'Response_Date_Discrepancy_Level__c', reasonField: 'Response_Date_Discrepancy_Reason__c' }
];

export default class IdpQuoteDualEntry extends LightningElement {
    @api recordId;

    record = null;
    _wiredRecord;
    isBusy = false;
    _pendingAction = null;  // 'judge' | 'confirm' — what to do after form save

    @wire(getFullRecord, { rfqQuoteId: '$recordId' })
    wiredRecord(result) {
        this._wiredRecord = result;
        if (result.data) this.record = result.data;
    }

    // --- Status flags ---
    get status() { return this.record ? this.record.IDP_Review_Status__c : STATUS_ENTERED; }
    get isEntered() { return this.status === STATUS_ENTERED || !this.status; }
    get isAwaitingCheck() { return this.status === STATUS_AWAITING_CHECK; }
    get isReviewing() { return this.status === STATUS_REVIEWING; }
    get isConfirmed() { return this.status === STATUS_CONFIRMED; }

    get hasErrorMessage() {
        return !!(this.record && this.record.IDP_Error_Message__c);
    }
    get errorBannerMessage() {
        return this.record ? this.record.IDP_Error_Message__c : '';
    }

    get isReadOnly() {
        // 担当者入力完了 と 担当者確認中 では編集可、それ以外(AI判定待ち・担当者確認済)はread-only
        return !(this.isEntered || this.isReviewing);
    }
    get showNoteField() {
        return this.isReviewing || this.isConfirmed;
    }
    get noteFieldDisabled() {
        return this.isConfirmed;
    }

    get showJudgeButton() { return this.isAwaitingCheck; }
    get showConfirmButton() { return this.isReviewing; }
    get showResetButton() {
        return this.isAwaitingCheck || this.isReviewing || this.isConfirmed || this.hasErrorMessage;
    }
    get showSaveButton() {
        return !this.isReadOnly && !this.isBusy;
    }
    get busyOrReadOnly() {
        return this.isBusy || this.isReadOnly;
    }

    get overallLevelLabel() {
        return this.record ? (this.record.IDP_Overall_Discrepancy_Level__c || '未判定') : '未判定';
    }
    get overallLevelClass() {
        return this._levelBadgeClass(this.overallLevelLabel);
    }
    get hasJudgmentSummary() {
        return this.record && this.record.IDP_Judgment_Summary__c;
    }
    get readyAlertVisible() {
        return this.isAwaitingCheck;
    }

    get fieldRows() {
        if (!this.record) return [];
        return FIELD_SPECS.map(spec => this._buildRow(spec));
    }

    _buildRow(spec) {
        const r = this.record;
        let aiVal = r[spec.aiField];
        const conf = r[spec.confField];
        const level = r[spec.levelField] || '未判定';
        const reason = r[spec.reasonField] || '';

        return {
            key: spec.key,
            label: spec.label,
            humanApiName: spec.humanApiName,
            aiDisplay: this._formatValue(aiVal, spec.type),
            hasAiValue: aiVal !== null && aiVal !== undefined && aiVal !== '',
            confidence: conf != null ? conf : null,
            hasConfidence: conf != null,
            levelLabel: level,
            levelClass: this._levelBadgeClass(level),
            reason: reason,
            rowClass: 'dual-row ' + this._levelRowClass(level)
        };
    }

    _formatValue(v, type) {
        if (v === null || v === undefined || v === '') return '—';
        if (type === 'currency') return '¥' + Number(v).toLocaleString('ja-JP');
        if (type === 'number') return Number(v).toLocaleString('ja-JP');
        if (type === 'date') return v;
        return String(v);
    }

    _levelBadgeClass(level) {
        switch (level) {
            case '一致': return 'idp-level idp-level-match';
            case '表記差': return 'idp-level idp-level-notation';
            case '読み取り差': return 'idp-level idp-level-ocr';
            case '単位換算差': return 'idp-level idp-level-unit';
            case '致命差': return 'idp-level idp-level-critical';
            default: return 'idp-level idp-level-unjudged';
        }
    }

    _levelRowClass(level) {
        switch (level) {
            case '致命差': return 'row-critical';
            case '単位換算差': return 'row-unit';
            case '読み取り差': return 'row-ocr';
            case '表記差': return 'row-notation';
            case '一致': return 'row-match';
            default: return 'row-unjudged';
        }
    }

    // --- Form submission handlers ---

    handleFormSuccess() {
        // Form saved. If a pending workflow action exists, run it.
        const pending = this._pendingAction;
        this._pendingAction = null;

        refreshApex(this._wiredRecord);

        if (pending === 'judge') {
            this._runJudgment();
        } else if (pending === 'confirm') {
            this._runConfirm();
        } else {
            this.isBusy = false;
            this._toast('保存', '変更を保存しました。', 'success');
        }
    }

    handleFormError(event) {
        this._pendingAction = null;
        this.isBusy = false;
        const msg = event.detail?.message || event.detail?.detail || '保存に失敗しました。';
        this._toast('保存エラー', msg, 'error');
    }

    // --- Button handlers ---

    handleSave() {
        this.isBusy = true;
        this._submitForm();
    }

    handleJudge() {
        this.isBusy = true;
        this._pendingAction = 'judge';
        this._submitForm();
    }

    handleConfirm() {
        this.isBusy = true;
        this._pendingAction = 'confirm';
        this._submitForm();
    }

    async handleReset() {
        if (!confirm('IDP抽出結果・判定結果をすべてクリアして最初からやり直しますか?')) return;
        this.isBusy = true;
        try {
            await clearIdpResult({ rfqQuoteId: this.recordId });
            await refreshApex(this._wiredRecord);
            this._toast('リセット完了', 'IDP結果をクリアしました。', 'success');
        } catch (err) {
            this._handleError(err);
        } finally {
            this.isBusy = false;
        }
    }

    async handleReload() {
        this.isBusy = true;
        try {
            await refreshApex(this._wiredRecord);
            this._toast('更新完了', '最新の状態に更新しました。', 'success');
        } catch (err) {
            this._handleError(err);
        } finally {
            this.isBusy = false;
        }
    }

    _submitForm() {
        const form = this.template.querySelector('lightning-record-edit-form');
        if (form) {
            form.submit();
        } else {
            // No form in DOM (read-only state). Run pending action directly.
            if (this._pendingAction === 'judge') {
                this._pendingAction = null;
                this._runJudgment();
            } else if (this._pendingAction === 'confirm') {
                this._pendingAction = null;
                this._runConfirm();
            } else {
                this.isBusy = false;
            }
        }
    }

    async _runJudgment() {
        try {
            await startJudgment({ rfqQuoteId: this.recordId });
            await refreshApex(this._wiredRecord);
            this._toast('判定完了', '相違判定が完了しました。結果を確認してください。', 'success');
        } catch (err) {
            this._handleError(err);
        } finally {
            this.isBusy = false;
        }
    }

    async _runConfirm() {
        try {
            // Note was saved via form. Just transition status.
            await markAsConfirmed({
                rfqQuoteId: this.recordId,
                reviewNote: this.record ? (this.record.IDP_Review_Note__c || '') : ''
            });
            await refreshApex(this._wiredRecord);
            this._toast('確認完了', 'ダブルチェック確認を完了しました。', 'success');
        } catch (err) {
            this._handleError(err);
        } finally {
            this.isBusy = false;
        }
    }

    _handleError(err) {
        let msg = '予期しないエラーが発生しました。';
        if (err?.body?.message) msg = err.body.message;
        else if (err?.message) msg = err.message;
        this._toast('エラー', msg, 'error');
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
