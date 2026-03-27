import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from 'lightning/uiRecordApi';
import getPresignedUrl from '@salesforce/apex/ProposalUploaderController.getPresignedUrl';
import startExtraction from '@salesforce/apex/ProposalUploaderController.startExtraction';
import getProposalContexts from '@salesforce/apex/ProposalUploaderController.getProposalContexts';
import getExtractionStatus from '@salesforce/apex/ProposalUploaderController.getExtractionStatus';

const ALLOWED_EXTENSIONS = ['.pptx', '.pdf'];
const MAX_POLL_COUNT = 60;
const POLL_INTERVAL_MS = 5000;

const COLUMNS = [
    { label: 'ファイル名', fieldName: 'File_Name__c', type: 'text', sortable: true },
    {
        label: 'ステータス',
        fieldName: 'Extraction_Status__c',
        type: 'text',
        cellAttributes: {
            class: { fieldName: 'statusClass' }
        }
    },
    {
        label: '抽出日時',
        fieldName: 'Extracted_At__c',
        type: 'date',
        typeAttributes: {
            year: 'numeric',
            month: '2-digit',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit',
            timeZone: 'Asia/Tokyo'
        },
        sortable: true
    }
];

export default class ProposalUploader extends LightningElement {
    @api recordId;

    selectedFile = null;
    isDragOver = false;
    isProcessing = false;
    statusMessage = '';
    errorMessage = '';
    uploadProgress = 0;
    showProgressBar = false;
    columns = COLUMNS;

    _wiredResult;
    proposalContexts = [];
    _pollTimer = null;
    _pollCount = 0;

    // --- Wire: 既存レコード一覧 ---
    @wire(getProposalContexts, { opportunityId: '$recordId' })
    wiredProposalContexts(result) {
        this._wiredResult = result;
        if (result.data) {
            this.proposalContexts = result.data.map(record => ({
                ...record,
                statusClass: this._getStatusClass(record.Extraction_Status__c)
            }));
        } else if (result.error) {
            console.error('提案書一覧取得エラー:', result.error);
        }
    }

    // --- Computed ---
    get dropZoneClass() {
        return this.isDragOver ? 'drop-zone-active' : 'drop-zone';
    }

    get showUploadButton() {
        return this.selectedFile && !this.isProcessing;
    }

    get hasProposalContexts() {
        return this.proposalContexts && this.proposalContexts.length > 0;
    }

    get showEmptyState() {
        return !this.hasProposalContexts && !this.isProcessing;
    }

    get formattedFileSize() {
        if (!this.selectedFile) return '';
        const bytes = this.selectedFile.size;
        if (bytes < 1024) return bytes + ' B';
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
        return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    }

    get fileIconName() {
        if (!this.selectedFile) return 'doctype:unknown';
        const name = this.selectedFile.name.toLowerCase();
        if (name.endsWith('.pptx')) return 'doctype:ppt';
        if (name.endsWith('.pdf')) return 'doctype:pdf';
        return 'doctype:unknown';
    }

    // --- ドラッグ&ドロップ ---
    handleDragOver(event) {
        event.preventDefault();
        event.stopPropagation();
        this.isDragOver = true;
    }

    handleDragLeave(event) {
        event.preventDefault();
        event.stopPropagation();
        this.isDragOver = false;
    }

    handleDrop(event) {
        event.preventDefault();
        event.stopPropagation();
        this.isDragOver = false;

        const files = event.dataTransfer.files;
        if (files && files.length > 0) {
            this._validateAndSetFile(files[0]);
        }
    }

    // --- ファイル選択 ---
    handleFileSelectClick() {
        const fileInput = this.template.querySelector('input.file-input');
        if (fileInput) {
            fileInput.click();
        }
    }

    handleFileChange(event) {
        const files = event.target.files;
        if (files && files.length > 0) {
            this._validateAndSetFile(files[0]);
        }
        // リセットして同じファイルの再選択を可能にする
        event.target.value = '';
    }

    handleRemoveFile() {
        this.selectedFile = null;
        this.errorMessage = '';
    }

    // --- バリデーション ---
    _validateAndSetFile(file) {
        this.errorMessage = '';
        const fileName = file.name.toLowerCase();
        const isValid = ALLOWED_EXTENSIONS.some(ext => fileName.endsWith(ext));

        if (!isValid) {
            this.errorMessage = '対応していないファイル形式です。PPTX または PDF ファイルを選択してください。';
            this.selectedFile = null;
            return;
        }

        this.selectedFile = file;
    }

    // --- アップロード処理 ---
    async handleUpload() {
        if (!this.selectedFile || this.isProcessing) return;

        this.isProcessing = true;
        this.errorMessage = '';
        this.uploadProgress = 0;
        this.showProgressBar = true;
        this.statusMessage = 'Presigned URL を取得中...';

        try {
            // 1. Presigned URL 取得
            const presignResult = await getPresignedUrl({
                fileName: this.selectedFile.name,
                contentType: this._getContentType(this.selectedFile.name)
            });

            const presignedUrl = presignResult.presignedUrl;
            const bucket = presignResult.bucket;
            const s3Key = presignResult.s3Key;

            // 2. S3 に直接アップロード
            this.statusMessage = 'ファイルをアップロード中...';
            await this._uploadToS3(presignedUrl, this.selectedFile);
            this.uploadProgress = 100;

            // 3. 抽出処理を開始
            this.showProgressBar = false;
            this.statusMessage = 'テキスト抽出を開始しています...';
            const proposalContextId = await startExtraction({
                opportunityId: this.recordId,
                bucket: bucket,
                s3Key: s3Key,
                fileName: this.selectedFile.name
            });

            // 4. ポーリング開始
            this.statusMessage = 'テキスト抽出中...';
            this._startPolling(proposalContextId);

        } catch (error) {
            this._handleError(error);
        }
    }

    // --- S3アップロード ---
    _uploadToS3(presignedUrl, file) {
        return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open('PUT', presignedUrl, true);
            xhr.setRequestHeader('Content-Type', this._getContentType(file.name));

            xhr.upload.onprogress = (event) => {
                if (event.lengthComputable) {
                    this.uploadProgress = Math.round((event.loaded / event.total) * 100);
                }
            };

            xhr.onload = () => {
                if (xhr.status >= 200 && xhr.status < 300) {
                    resolve();
                } else {
                    reject(new Error(`S3アップロードに失敗しました (HTTP ${xhr.status})`));
                }
            };

            xhr.onerror = () => {
                reject(new Error('ネットワークエラーが発生しました'));
            };

            xhr.send(file);
        });
    }

    // --- ポーリング ---
    _startPolling(proposalContextId) {
        this._pollCount = 0;
        this._clearPolling();

        this._pollTimer = setInterval(async () => {
            this._pollCount++;

            if (this._pollCount > MAX_POLL_COUNT) {
                this._clearPolling();
                this._handleError({ body: { message: 'テキスト抽出がタイムアウトしました。しばらく後に画面を更新してください。' } });
                return;
            }

            try {
                const result = await getExtractionStatus({ proposalContextId });
                const status = result.Extraction_Status__c;

                if (status === '完了') {
                    this._clearPolling();
                    this._onExtractionComplete();
                } else if (status === 'エラー') {
                    this._clearPolling();
                    this._handleError({ body: { message: 'テキスト抽出中にエラーが発生しました。' } });
                }
                // '処理中' の場合はポーリング継続
            } catch (error) {
                this._clearPolling();
                this._handleError(error);
            }
        }, POLL_INTERVAL_MS);
    }

    _clearPolling() {
        if (this._pollTimer) {
            clearInterval(this._pollTimer);
            this._pollTimer = null;
        }
    }

    // --- 完了処理 ---
    _onExtractionComplete() {
        this.isProcessing = false;
        this.showProgressBar = false;
        this.statusMessage = '';
        this.selectedFile = null;

        this.dispatchEvent(
            new ShowToastEvent({
                title: '完了',
                message: '提案書のテキスト抽出が完了しました。',
                variant: 'success'
            })
        );

        // 一覧を更新
        refreshApex(this._wiredResult);
    }

    // --- エラー処理 ---
    _handleError(error) {
        this.isProcessing = false;
        this.showProgressBar = false;
        this.statusMessage = '';

        let message = '予期しないエラーが発生しました。';
        if (error?.body?.message) {
            message = error.body.message;
        } else if (error?.message) {
            message = error.message;
        }

        this.errorMessage = message;

        this.dispatchEvent(
            new ShowToastEvent({
                title: 'エラー',
                message: message,
                variant: 'error'
            })
        );
    }

    // --- ユーティリティ ---
    _getContentType(fileName) {
        const lower = fileName.toLowerCase();
        if (lower.endsWith('.pptx')) {
            return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
        }
        if (lower.endsWith('.pdf')) {
            return 'application/pdf';
        }
        return 'application/octet-stream';
    }

    _getStatusClass(status) {
        switch (status) {
            case '完了':
                return 'slds-text-color_success';
            case 'エラー':
                return 'slds-text-color_error';
            default:
                return '';
        }
    }

    disconnectedCallback() {
        this._clearPolling();
    }
}
