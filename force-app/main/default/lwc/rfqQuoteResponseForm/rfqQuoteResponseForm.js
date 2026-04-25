import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { CurrentPageReference } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getRfqQuote from '@salesforce/apex/SupplierPortalController.getRfqQuote';
import submitQuote from '@salesforce/apex/SupplierPortalController.submitQuote';
import declineQuote from '@salesforce/apex/SupplierPortalController.declineQuote';
import getPresignedUrl from '@salesforce/apex/IdpSupplierQuoteController.getPresignedUrl';
import extractPdfSync from '@salesforce/apex/IdpSupplierQuoteController.extractPdfSync';

const ALLOWED_EXTENSIONS = ['.pdf', '.png', '.jpg', '.jpeg'];

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

    // --- IDP file upload state ---
    selectedFile = null;
    isDragOver = false;
    isExtracting = false;
    uploadProgress = 0;
    extractionError = '';
    @track idpData = null;  // 抽出結果(submit時に併送)

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
                notes: this.formNotes || null,
                idpDataJson: this.idpData ? JSON.stringify(this.idpData) : null
            });
            this.showToast('見積を提出しました', '貴社の回答が購買側に送信されました。', 'success');
            this.idpData = null;
            this.selectedFile = null;
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.showToast('エラー', this.extractError(err), 'error');
        } finally {
            this.isSubmitting = false;
        }
    }

    // ==== IDP ファイルアップロード ====
    get dropZoneClass() {
        return this.isDragOver ? 'rqf-dropzone rqf-dropzone--active' : 'rqf-dropzone';
    }
    get hasIdpExtraction() {
        return !!this.idpData;
    }
    get extractedFileName() {
        return this.selectedFile?.name || (this.idpData ? '見積書(アップ済)' : '');
    }
    get formattedFileSize() {
        if (!this.selectedFile) return '';
        const b = this.selectedFile.size;
        if (b < 1024) return b + ' B';
        if (b < 1024 * 1024) return (b / 1024).toFixed(1) + ' KB';
        return (b / (1024 * 1024)).toFixed(1) + ' MB';
    }
    get showUploadButton() {
        return this.selectedFile && !this.isExtracting;
    }
    get fileIconName() {
        if (!this.selectedFile) return 'doctype:unknown';
        const n = this.selectedFile.name.toLowerCase();
        if (n.endsWith('.pdf')) return 'doctype:pdf';
        if (n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'doctype:image';
        return 'doctype:unknown';
    }

    handleIdpDragOver(e) { e.preventDefault(); e.stopPropagation(); this.isDragOver = true; }
    handleIdpDragLeave(e) { e.preventDefault(); e.stopPropagation(); this.isDragOver = false; }
    handleIdpDrop(e) {
        e.preventDefault(); e.stopPropagation(); this.isDragOver = false;
        const files = e.dataTransfer.files;
        if (files && files.length > 0) this._validateAndSetFile(files[0]);
    }
    handleIdpFileSelectClick() {
        const inp = this.template.querySelector('input.rqf-file-input');
        if (inp) inp.click();
    }
    handleIdpFileChange(e) {
        const files = e.target.files;
        if (files && files.length > 0) this._validateAndSetFile(files[0]);
        e.target.value = '';
    }
    handleIdpRemoveFile() {
        this.selectedFile = null;
        this.extractionError = '';
        this.idpData = null;
    }

    _validateAndSetFile(file) {
        this.extractionError = '';
        const lower = file.name.toLowerCase();
        const ok = ALLOWED_EXTENSIONS.some(ext => lower.endsWith(ext));
        if (!ok) {
            this.extractionError = '対応していないファイル形式です。PDF / PNG / JPG のいずれかを選択してください。';
            this.selectedFile = null;
            return;
        }
        this.selectedFile = file;
    }

    async handleIdpExtract() {
        if (!this.selectedFile || this.isExtracting) return;
        this.isExtracting = true;
        this.extractionError = '';
        this.uploadProgress = 0;
        try {
            // 1. Presigned URL取得
            const presign = await getPresignedUrl({
                fileName: this.selectedFile.name,
                contentType: this._getContentType(this.selectedFile.name)
            });
            // 2. S3にアップロード
            await this._uploadToS3(presign.presignedUrl, this.selectedFile);
            // 3. 同期抽出
            const result = await extractPdfSync({
                bucket: presign.bucket,
                s3Key: presign.s3Key
            });
            this.idpData = result;
            // 4. 抽出値をフォームに反映
            this._applyExtractionToForm(result.extraction);
            this.showToast('IDP抽出完了', '抽出値をフォームに反映しました。内容をご確認の上、必要に応じて修正してください。', 'success');
        } catch (err) {
            this.extractionError = this.extractError(err);
            this.showToast('IDPエラー', this.extractionError, 'error');
        } finally {
            this.isExtracting = false;
        }
    }

    _uploadToS3(url, file) {
        return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open('PUT', url, true);
            xhr.setRequestHeader('Content-Type', this._getContentType(file.name));
            xhr.upload.onprogress = (evt) => {
                if (evt.lengthComputable) this.uploadProgress = Math.round((evt.loaded / evt.total) * 100);
            };
            xhr.onload = () => {
                if (xhr.status >= 200 && xhr.status < 300) resolve();
                else reject(new Error(`S3アップロード失敗 (HTTP ${xhr.status})`));
            };
            xhr.onerror = () => reject(new Error('ネットワークエラー'));
            xhr.send(file);
        });
    }

    _applyExtractionToForm(extraction) {
        if (!extraction) return;
        const v = (key) => (extraction[key] || {}).value;
        // 担当者(=サプライヤー)の入力欄に AI抽出値を反映
        // ※ サプライヤー名は Account Lookup で確定しているため上書きしない
        if (v('unit_price') != null) this.formUnitPrice = v('unit_price');
        if (v('moq') != null) this.formMoq = v('moq');
        if (v('lead_time_days') != null) this.formLeadTime = v('lead_time_days');
        if (v('valid_until')) this.formValidUntil = v('valid_until');
        // 製造拠点は siteOptions と一致するものを fuzzy match
        if (v('manufacturing_site') && this.detail?.siteOptions) {
            const aiSite = String(v('manufacturing_site')).trim();
            const match = this.detail.siteOptions.find(o =>
                aiSite.includes(o.siteName) || o.siteName.includes(aiSite)
            );
            if (match) this.formSiteId = match.siteId;
        }
        // 備考: IDPが抽出した備考をフォームに反映(サプライヤーが編集自由)
        if (v('notes')) this.formNotes = v('notes');
    }

    _getContentType(fileName) {
        const l = fileName.toLowerCase();
        if (l.endsWith('.pdf')) return 'application/pdf';
        if (l.endsWith('.png')) return 'image/png';
        if (l.endsWith('.jpg') || l.endsWith('.jpeg')) return 'image/jpeg';
        return 'application/octet-stream';
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
