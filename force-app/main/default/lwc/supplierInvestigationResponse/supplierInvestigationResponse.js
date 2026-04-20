import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getInvestigation from '@salesforce/apex/SupplierPortalController.getInvestigation';
import saveDraft from '@salesforce/apex/SupplierPortalController.saveInvestigationDraft';
import submitInvestigation from '@salesforce/apex/SupplierPortalController.submitInvestigation';

const CAUSE_CATEGORIES = [
    { label: '材料変更', value: '材料変更' },
    { label: '工程変更', value: '工程変更' },
    { label: '設備故障', value: '設備故障' },
    { label: '人的ミス', value: '人的ミス' },
    { label: '検査漏れ', value: '検査漏れ' },
    { label: 'その他',   value: 'その他'   }
];

export default class SupplierInvestigationResponse extends LightningElement {
    @api recordId;           // Supplier_Investigation__c Record Page配置時
    @api investigationId;    // AppPage/Community 明示指定
    @api accountId;

    urlInvestigationId; // Experience Cloud URL query ?investigationId=xxx

    @wire(CurrentPageReference)
    wiredPageRef(pageRef) {
        if (pageRef?.state) {
            this.urlInvestigationId = pageRef.state.investigationId || pageRef.state.c__investigationId;
        }
        // Aura系テンプレートでCurrentPageReferenceにパラメータが入らないケースのフォールバック
        if (!this.urlInvestigationId && typeof window !== 'undefined' && window.location?.search) {
            const params = new URLSearchParams(window.location.search);
            this.urlInvestigationId = params.get('investigationId') || params.get('c__investigationId') || undefined;
        }
    }

    connectedCallback() {
        if (!this.urlInvestigationId && typeof window !== 'undefined' && window.location?.search) {
            const params = new URLSearchParams(window.location.search);
            this.urlInvestigationId = params.get('investigationId') || params.get('c__investigationId') || undefined;
        }
    }

    data;
    error;
    wiredResult;

    @track form = {
        causeCategory: null,
        rootCause: '',
        actionTaken: '',
        recurrencePrevention: '',
        responseDetail: '',
        evidenceAttachments: ''
    };

    isSubmitting = false;
    showSubmitConfirm = false;
    causeCategoryOptions = CAUSE_CATEGORIES;

    @wire(getInvestigation, { investigationId: '$targetInvestigationId', accountId: '$accountId' })
    wiredInvestigation(result) {
        this.wiredResult = result;
        if (result.data) {
            this.data = result.data;
            this.error = undefined;
            this.form = {
                causeCategory: result.data.causeCategory || null,
                rootCause: result.data.rootCause || '',
                actionTaken: result.data.actionTaken || '',
                recurrencePrevention: result.data.recurrencePrevention || '',
                responseDetail: result.data.responseDetail || '',
                evidenceAttachments: result.data.evidenceAttachments || ''
            };
        } else if (result.error) {
            this.error = this.extractError(result.error);
            this.data = undefined;
        }
    }

    get targetInvestigationId() {
        return this.investigationId || this.recordId || this.urlInvestigationId || null;
    }

    get isLoading() {
        return !this.data && !this.error;
    }

    get hasData() {
        return !!this.data;
    }

    get isEditable() {
        return this.data?.editable === true;
    }

    get isSubmitted() {
        return this.data?.submitted === true;
    }

    get severityBadgeClass() {
        const s = this.data?.severity;
        if (s === '重大') return 'sir-badge sir-badge--critical';
        if (s === '重要') return 'sir-badge sir-badge--warn';
        return 'sir-badge sir-badge--muted';
    }

    get statusBadgeClass() {
        const s = this.data?.status;
        if (s === '完了') return 'sir-badge sir-badge--ok';
        if (s === '回答済' || s === '対策実施中') return 'sir-badge sir-badge--inprogress';
        if (s === '調査中') return 'sir-badge sir-badge--warn';
        return 'sir-badge sir-badge--muted';
    }

    get dueLabel() {
        if (!this.data?.responseDueDate) return '—';
        return this.fmtDate(this.data.responseDueDate);
    }

    get dueCountdownLabel() {
        const d = this.data?.daysToDue;
        if (d == null) return '';
        if (this.isSubmitted) return '';
        if (d < 0) return `期限超過 ${Math.abs(d)} 日`;
        if (d === 0) return '本日期限';
        return `あと ${d} 日`;
    }

    get dueCountdownClass() {
        const d = this.data?.daysToDue;
        if (d == null || this.isSubmitted) return 'sir-meta__value';
        if (d < 0) return 'sir-meta__value sir-meta__value--critical';
        if (d <= 3) return 'sir-meta__value sir-meta__value--warn';
        return 'sir-meta__value';
    }

    get partLabel() {
        if (!this.data?.partNumber) return '未設定';
        return `${this.data.partNumber} / ${this.data.partName ?? ''}`;
    }

    get requestDateLabel() { return this.fmtDate(this.data?.requestDate); }
    get responseDateLabel() { return this.fmtDate(this.data?.responseDate); }
    get verificationDateLabel() { return this.fmtDate(this.data?.verificationDate); }

    get hasVerification() {
        return this.isSubmitted && (this.data?.verificationResult || this.data?.verificationDate);
    }

    // === field change ===
    handleFieldChange(event) {
        const field = event.target.dataset.field;
        this.form = { ...this.form, [field]: event.target.value };
    }

    // === save draft ===
    async handleSaveDraft() {
        this.isSubmitting = true;
        try {
            await saveDraft({
                investigationId: this.data.id,
                causeCategory: this.form.causeCategory || null,
                rootCause: this.form.rootCause || null,
                actionTaken: this.form.actionTaken || null,
                recurrencePrevention: this.form.recurrencePrevention || null,
                responseDetail: this.form.responseDetail || null,
                evidenceAttachments: this.form.evidenceAttachments || null
            });
            this.showToast('下書き保存完了', '回答内容を保存しました。', 'success');
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.showToast('エラー', this.extractError(err), 'error');
        } finally {
            this.isSubmitting = false;
        }
    }

    // === submit confirmation ===
    openSubmitConfirm() {
        // クライアント側バリデーション
        if (!this.form.causeCategory) {
            this.showToast('入力不足', '原因区分を選択してください。', 'warning');
            return;
        }
        if (!this.form.rootCause) {
            this.showToast('入力不足', '根本原因を記入してください。', 'warning');
            return;
        }
        if (!this.form.actionTaken) {
            this.showToast('入力不足', '対策内容を記入してください。', 'warning');
            return;
        }
        if (!this.form.recurrencePrevention) {
            this.showToast('入力不足', '再発防止策を記入してください。', 'warning');
            return;
        }
        this.showSubmitConfirm = true;
    }

    closeSubmitConfirm() {
        this.showSubmitConfirm = false;
    }

    async handleSubmit() {
        this.isSubmitting = true;
        try {
            await submitInvestigation({
                investigationId: this.data.id,
                causeCategory: this.form.causeCategory,
                rootCause: this.form.rootCause,
                actionTaken: this.form.actionTaken,
                recurrencePrevention: this.form.recurrencePrevention,
                responseDetail: this.form.responseDetail || null,
                evidenceAttachments: this.form.evidenceAttachments || null
            });
            this.showToast('回答提出完了', '調査回答を提出しました。', 'success');
            this.showSubmitConfirm = false;
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.showToast('エラー', this.extractError(err), 'error');
        } finally {
            this.isSubmitting = false;
        }
    }

    // === utils ===
    fmtDate(d) {
        if (!d) return '—';
        const dt = typeof d === 'string' ? new Date(d) : d;
        return `${dt.getFullYear()}/${String(dt.getMonth() + 1).padStart(2, '0')}/${String(dt.getDate()).padStart(2, '0')}`;
    }

    extractError(err) {
        if (err?.body?.message) return err.body.message;
        if (Array.isArray(err?.body)) return err.body.map(e => e.message).join(', ');
        return err?.message || 'エラーが発生しました';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
