import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getPresignedUrl from '@salesforce/apex/IdpSupplierQuoteController.getPresignedUrl';
import initializeIdpRecord from '@salesforce/apex/IdpSupplierQuoteController.initializeIdpRecord';
import startExtraction from '@salesforce/apex/IdpSupplierQuoteController.startExtraction';
import getIdpStatus from '@salesforce/apex/IdpSupplierQuoteController.getIdpStatus';

const ALLOWED_EXTENSIONS = ['.pdf', '.png', '.jpg', '.jpeg'];
const MAX_POLL_COUNT = 90;
const POLL_INTERVAL_MS = 3000;

const STATUS_ENTERED = '担当者入力完了';
const STATUS_AWAITING_CHECK = 'AI判定待ち';
const STATUS_REVIEWING = '担当者確認中';
const STATUS_CONFIRMED = '担当者確認済';

export default class IdpQuoteFileUploader extends LightningElement {
    @api recordId;

    selectedFile = null;
    isDragOver = false;
    isProcessing = false;
    statusMessage = '';
    errorMessage = '';
    uploadProgress = 0;
    showProgressBar = false;

    _wiredStatus;
    record = null;
    _pollTimer = null;
    _pollCount = 0;

    @wire(getIdpStatus, { rfqQuoteId: '$recordId' })
    wiredStatus(result) {
        this._wiredStatus = result;
        if (result.data) {
            this.record = result.data;
            // IDP抽出中の派生判定: Document_URLが付いてExtracted_Atがnullなら処理中
            if (this._isExtractingDerived() && !this._pollTimer) {
                this.isProcessing = true;
                this.statusMessage = 'IDPが項目を抽出中...';
                this._startPolling();
            }
        }
    }

    _isExtractingDerived() {
        const r = this.record;
        if (!r) return false;
        return !!r.IDP_Document_URL__c && !r.IDP_Extracted_At__c && !r.IDP_Error_Message__c;
    }

    // --- Computed ---
    get dropZoneClass() {
        return this.isDragOver ? 'drop-zone-active' : 'drop-zone';
    }
    get showUploadButton() {
        return this.selectedFile && !this.isProcessing;
    }
    get formattedFileSize() {
        if (!this.selectedFile) return '';
        const b = this.selectedFile.size;
        if (b < 1024) return b + ' B';
        if (b < 1024 * 1024) return (b / 1024).toFixed(1) + ' KB';
        return (b / (1024 * 1024)).toFixed(1) + ' MB';
    }
    get fileIconName() {
        if (!this.selectedFile) return 'doctype:unknown';
        const n = this.selectedFile.name.toLowerCase();
        if (n.endsWith('.pdf')) return 'doctype:pdf';
        if (n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'doctype:image';
        return 'doctype:unknown';
    }
    get hasErrorMessage() {
        return !!(this.record && this.record.IDP_Error_Message__c);
    }
    get errorBannerMessage() {
        return this.record ? this.record.IDP_Error_Message__c : '';
    }
    get isExtracted() {
        return !!(this.record && this.record.IDP_Extracted_At__c);
    }
    get showCompletionNote() {
        return this.isExtracted && !this.isProcessing && !this.hasErrorMessage;
    }

    // --- Drag & Drop ---
    handleDragOver(event) { event.preventDefault(); event.stopPropagation(); this.isDragOver = true; }
    handleDragLeave(event) { event.preventDefault(); event.stopPropagation(); this.isDragOver = false; }
    handleDrop(event) {
        event.preventDefault();
        event.stopPropagation();
        this.isDragOver = false;
        const files = event.dataTransfer.files;
        if (files && files.length > 0) this._validateAndSetFile(files[0]);
    }

    // --- File select ---
    handleFileSelectClick() {
        const inp = this.template.querySelector('input.file-input');
        if (inp) inp.click();
    }
    handleFileChange(event) {
        const files = event.target.files;
        if (files && files.length > 0) this._validateAndSetFile(files[0]);
        event.target.value = '';
    }
    handleRemoveFile() {
        this.selectedFile = null;
        this.errorMessage = '';
    }

    _validateAndSetFile(file) {
        this.errorMessage = '';
        const lower = file.name.toLowerCase();
        const ok = ALLOWED_EXTENSIONS.some(e => lower.endsWith(e));
        if (!ok) {
            this.errorMessage = '対応していないファイル形式です。PDF / PNG / JPG のいずれかを選択してください。';
            this.selectedFile = null;
            return;
        }
        this.selectedFile = file;
    }

    // --- Upload flow ---
    async handleUpload() {
        if (!this.selectedFile || this.isProcessing) return;

        this.isProcessing = true;
        this.errorMessage = '';
        this.uploadProgress = 0;
        this.showProgressBar = true;
        this.statusMessage = 'Presigned URL を取得中...';

        try {
            const presign = await getPresignedUrl({
                fileName: this.selectedFile.name,
                contentType: this._getContentType(this.selectedFile.name)
            });

            this.statusMessage = 'ファイルをアップロード中...';
            await this._uploadToS3(presign.presignedUrl, this.selectedFile);
            this.uploadProgress = 100;

            this.showProgressBar = false;
            this.statusMessage = 'IDP処理を開始しています...';
            await initializeIdpRecord({
                rfqQuoteId: this.recordId,
                bucket: presign.bucket,
                s3Key: presign.s3Key,
                fileName: this.selectedFile.name
            });
            refreshApex(this._wiredStatus);

            await startExtraction({
                rfqQuoteId: this.recordId,
                bucket: presign.bucket,
                s3Key: presign.s3Key
            });

            this.statusMessage = 'IDPが項目を抽出中...';
            this._startPolling();
            this.selectedFile = null;

        } catch (err) {
            this._handleError(err);
            this.isProcessing = false;
            this.showProgressBar = false;
        }
    }

    _uploadToS3(url, file) {
        return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open('PUT', url, true);
            xhr.setRequestHeader('Content-Type', this._getContentType(file.name));
            xhr.upload.onprogress = (e) => {
                if (e.lengthComputable) this.uploadProgress = Math.round((e.loaded / e.total) * 100);
            };
            xhr.onload = () => {
                if (xhr.status >= 200 && xhr.status < 300) resolve();
                else reject(new Error(`S3アップロード失敗 (HTTP ${xhr.status})`));
            };
            xhr.onerror = () => reject(new Error('ネットワークエラー'));
            xhr.send(file);
        });
    }

    _startPolling() {
        this._pollCount = 0;
        this._clearPolling();
        this._pollTimer = setInterval(async () => {
            this._pollCount++;
            if (this._pollCount > MAX_POLL_COUNT) {
                this._clearPolling();
                this.isProcessing = false;
                this._handleError({ message: 'タイムアウトしました。画面を更新してください。' });
                return;
            }
            try {
                await refreshApex(this._wiredStatus);
                if (this.hasErrorMessage) {
                    this._clearPolling();
                    this.isProcessing = false;
                    this.statusMessage = '';
                    this._toast('エラー', this.errorBannerMessage || 'IDP処理でエラーが発生しました。', 'error');
                } else if (this.isExtracted) {
                    this._clearPolling();
                    this.isProcessing = false;
                    this.statusMessage = '';
                    this._toast('抽出完了', 'IDPが項目を抽出しました。比較表で確認してください。', 'success');
                }
            } catch (err) {
                this._clearPolling();
                this.isProcessing = false;
                this._handleError(err);
            }
        }, POLL_INTERVAL_MS);
    }

    _clearPolling() {
        if (this._pollTimer) { clearInterval(this._pollTimer); this._pollTimer = null; }
    }

    // --- Helpers ---
    _getContentType(fileName) {
        const l = fileName.toLowerCase();
        if (l.endsWith('.pdf')) return 'application/pdf';
        if (l.endsWith('.png')) return 'image/png';
        if (l.endsWith('.jpg') || l.endsWith('.jpeg')) return 'image/jpeg';
        return 'application/octet-stream';
    }

    _handleError(err) {
        let msg = '予期しないエラーが発生しました。';
        if (err?.body?.message) msg = err.body.message;
        else if (err?.message) msg = err.message;
        this.errorMessage = msg;
        this.statusMessage = '';
        this._toast('エラー', msg, 'error');
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    disconnectedCallback() { this._clearPolling(); }
}
