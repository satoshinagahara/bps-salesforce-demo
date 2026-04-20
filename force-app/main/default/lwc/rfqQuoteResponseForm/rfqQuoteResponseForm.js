import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getRfqQuote from '@salesforce/apex/SupplierPortalController.getRfqQuote';
import submitQuote from '@salesforce/apex/SupplierPortalController.submitQuote';
import declineQuote from '@salesforce/apex/SupplierPortalController.declineQuote';

/**
 * RFQ見積回答フォーム
 * - RFQレコードページに配置してサプライヤーの見積提出を受ける
 */
export default class RfqQuoteResponseForm extends LightningElement {
    @api recordId; // RFQ__c.Id (Record Page 配置時に自動注入)
    @api rfqId; // App Page / Community からの指定
    @api accountId;

    urlRfqId; // Experience Cloudでクエリパラメータ ?rfqId=xxx から取得

    @wire(CurrentPageReference)
    wiredPageRef(pageRef) {
        if (pageRef?.state) {
            this.urlRfqId = pageRef.state.rfqId || pageRef.state.c__rfqId;
        }
        // Aura系テンプレートでCurrentPageReferenceにパラメータが入らないケースのフォールバック
        if (!this.urlRfqId && typeof window !== 'undefined' && window.location?.search) {
            const params = new URLSearchParams(window.location.search);
            this.urlRfqId = params.get('rfqId') || params.get('c__rfqId') || undefined;
        }
    }

    connectedCallback() {
        // wiredPageRef 発火前のセーフガード
        if (!this.urlRfqId && typeof window !== 'undefined' && window.location?.search) {
            const params = new URLSearchParams(window.location.search);
            this.urlRfqId = params.get('rfqId') || params.get('c__rfqId') || undefined;
        }
    }

    detail;
    error;
    wiredResult;

    @track formUnitPrice;
    @track formMoq;
    @track formLeadTime;
    @track formValidUntil;
    @track formSiteId;
    @track formNotes;

    isSubmitting = false;
    showDeclineDialog = false;
    declineNotes = '';

    @wire(getRfqQuote, { rfqId: '$targetRfqId', accountId: '$accountId' })
    wiredDetail(result) {
        this.wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.detail = data;
            this.error = undefined;
            this.initForm();
        } else if (error) {
            this.error = this.extractError(error);
            this.detail = undefined;
        }
    }

    get targetRfqId() {
        return this.rfqId || this.recordId || this.urlRfqId;
    }

    initForm() {
        const d = this.detail;
        this.formUnitPrice = d.quoteUnitPrice;
        this.formMoq = d.quoteMoq;
        this.formLeadTime = d.quoteLeadTimeDays;
        this.formValidUntil = d.quoteValidUntil;
        this.formSiteId = d.quoteManufacturingSiteId;
        this.formNotes = d.quoteNotes;
    }

    // ==== 表示用 ====
    get isLoading() {
        return !this.detail && !this.error;
    }

    get hasQuote() {
        return !!this.detail?.quoteId;
    }

    get isEditable() {
        return this.detail?.isEditable === true;
    }

    get isClosed() {
        const s = this.detail?.quoteStatus;
        return s === '採用' || s === '不採用' || s === '辞退';
    }

    get statusBadgeClass() {
        const s = this.detail?.quoteStatus;
        if (s === '採用') return 'rqf-badge rqf-badge--ok';
        if (s === '不採用' || s === '辞退') return 'rqf-badge rqf-badge--muted';
        if (s === '依頼中') return 'rqf-badge rqf-badge--warn';
        if (s === '回答済') return 'rqf-badge rqf-badge--inprogress';
        return 'rqf-badge';
    }

    get dueLabel() {
        const d = this.detail;
        if (!d?.dueDate) return '—';
        const dt = this.fmtDate(d.dueDate);
        if (d.daysToDue != null) {
            if (d.daysToDue < 0) return `${dt} （${Math.abs(d.daysToDue)}日超過）`;
            if (d.daysToDue === 0) return `${dt} （本日締切）`;
            return `${dt} （残${d.daysToDue}日）`;
        }
        return dt;
    }

    get dueLabelClass() {
        const d = this.detail?.daysToDue;
        if (d != null && d <= 7) return 'rqf-meta__value rqf-meta__value--warn';
        return 'rqf-meta__value';
    }

    get siteOptions() {
        return (this.detail?.siteOptions || []).map(o => ({
            label: o.siteName,
            value: o.siteId
        }));
    }

    get formattedRequiredQuantity() {
        return this.fmtNumber(this.detail?.requiredQuantity);
    }

    get formattedTargetPrice() {
        return this.detail?.targetUnitPrice != null
            ? `¥${this.fmtNumber(this.detail.targetUnitPrice)}`
            : '—';
    }

    get responseDateLabel() {
        return this.detail?.quoteResponseDate
            ? this.fmtDate(this.detail.quoteResponseDate)
            : '—';
    }

    // 読み取り専用時に表示する値
    get displayUnitPrice() {
        return this.detail?.quoteUnitPrice != null
            ? `¥${this.fmtNumber(this.detail.quoteUnitPrice)}`
            : '—';
    }

    get displayMoq() {
        return this.detail?.quoteMoq != null
            ? this.fmtNumber(this.detail.quoteMoq)
            : '—';
    }

    get displayLeadTime() {
        return this.detail?.quoteLeadTimeDays != null
            ? `${this.detail.quoteLeadTimeDays} 日`
            : '—';
    }

    get displayValidUntil() {
        return this.detail?.quoteValidUntil
            ? this.fmtDate(this.detail.quoteValidUntil)
            : '—';
    }

    // ==== フォーム入力ハンドラ ====
    handleUnitPriceChange(e) { this.formUnitPrice = e.target.value; }
    handleMoqChange(e) { this.formMoq = e.target.value; }
    handleLeadTimeChange(e) { this.formLeadTime = e.target.value; }
    handleValidUntilChange(e) { this.formValidUntil = e.target.value; }
    handleSiteChange(e) { this.formSiteId = e.detail.value; }
    handleNotesChange(e) { this.formNotes = e.target.value; }
    handleDeclineNotesChange(e) { this.declineNotes = e.target.value; }

    // ==== 提出 ====
    async handleSubmit() {
        if (!this.validateInputs()) return;
        this.isSubmitting = true;
        try {
            await submitQuote({
                quoteId: this.detail.quoteId,
                unitPrice: this.formUnitPrice ? Number(this.formUnitPrice) : null,
                moq: this.formMoq ? Number(this.formMoq) : null,
                leadTimeDays: this.formLeadTime ? Number(this.formLeadTime) : null,
                validUntil: this.formValidUntil || null,
                siteId: this.formSiteId || null,
                notes: this.formNotes || null
            });
            this.showToast('見積を提出しました', '貴社の回答が購買側に送信されました。', 'success');
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.showToast('エラー', this.extractError(err), 'error');
        } finally {
            this.isSubmitting = false;
        }
    }

    validateInputs() {
        const inputs = this.template.querySelectorAll('.rqf-input');
        let ok = true;
        inputs.forEach(i => {
            if (!i.reportValidity()) ok = false;
        });
        if (!this.formUnitPrice) {
            this.showToast('入力不足', '単価は必須です。', 'warning');
            ok = false;
        }
        if (!this.formSiteId) {
            this.showToast('入力不足', '製造拠点を選択してください。', 'warning');
            ok = false;
        }
        return ok;
    }

    // ==== 辞退 ====
    openDeclineDialog() {
        this.declineNotes = '';
        this.showDeclineDialog = true;
    }

    closeDeclineDialog() {
        this.showDeclineDialog = false;
    }

    async handleDeclineConfirm() {
        this.isSubmitting = true;
        try {
            await declineQuote({
                quoteId: this.detail.quoteId,
                notes: this.declineNotes || null
            });
            this.showToast('辞退を送信しました', '購買側に通知されました。', 'success');
            this.showDeclineDialog = false;
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.showToast('エラー', this.extractError(err), 'error');
        } finally {
            this.isSubmitting = false;
        }
    }

    // ==== ユーティリティ ====
    fmtDate(d) {
        if (!d) return '';
        const dt = typeof d === 'string' ? new Date(d) : d;
        return `${dt.getFullYear()}/${String(dt.getMonth() + 1).padStart(2, '0')}/${String(dt.getDate()).padStart(2, '0')}`;
    }

    fmtNumber(n) {
        if (n == null) return '0';
        return new Intl.NumberFormat('ja-JP').format(n);
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
