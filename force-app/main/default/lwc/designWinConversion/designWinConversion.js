import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getConversionPreview from '@salesforce/apex/DesignWinConversionController.getConversionPreview';
import convertToAgreement from '@salesforce/apex/DesignWinConversionController.convertToAgreement';

export default class DesignWinConversion extends NavigationMixin(LightningElement) {
    @api recordId;

    preview;
    error;
    isLoading = true;
    isConverting = false;
    showModal = false;

    contractStart;
    contractEnd;

    @wire(getConversionPreview, { opportunityId: '$recordId' })
    wiredPreview({ data, error }) {
        this.isLoading = false;
        if (data) {
            this.preview = data;
            this.error = undefined;
        } else if (error) {
            this.error = error.body ? error.body.message : error.message;
            this.preview = undefined;
        }
    }

    get canConvert() {
        return this.preview && this.preview.isDesignWin && this.preview.isClosed
            && this.preview.forecastCount > 0 && !this.preview.hasExisting;
    }

    get convertDisabled() {
        return !this.canConvert;
    }

    get buttonLabel() {
        if (!this.preview) return '読込中...';
        if (!this.preview.isDesignWin) return 'Design Win商談のみ';
        if (!this.preview.isClosed) return 'Design Win後に変換可能';
        if (this.preview.hasExisting) return '変換済み';
        if (this.preview.forecastCount === 0) return '予測データなし';
        return '販売契約に変換';
    }

    get statusMessage() {
        if (!this.preview) return '';
        if (this.preview.hasExisting) {
            return '既に販売契約「' + this.preview.existingName + '」が作成されています。';
        }
        if (!this.preview.isDesignWin) return 'この商談はDesign Winレコードタイプではありません。';
        if (!this.preview.isClosed) return 'ステージが「Design Win」になると変換可能です。';
        if (this.preview.forecastCount === 0) return '受注予測データがありません。';
        return '';
    }

    get hasStatus() {
        return this.statusMessage !== '';
    }

    get products() {
        if (!this.preview || !this.preview.products) return [];
        return this.preview.products.map((p, i) => ({
            key: 'p' + i,
            productName: p.productName,
            unitPrice: this.fmtCurrency(p.unitPrice),
            totalQty: this.fmtNumber(p.totalQty),
            totalAmt: this.fmtCurrency(p.totalAmt)
        }));
    }

    get hasProducts() {
        return this.products.length > 0;
    }

    get isConvertDisabled() {
        return !this.contractStart || !this.contractEnd || this.isConverting;
    }

    fmtCurrency(v) {
        if (v == null) return '¥0';
        return '¥' + Number(v).toLocaleString();
    }

    fmtNumber(v) {
        if (v == null) return '0';
        return Number(v).toLocaleString();
    }

    handleOpenModal() {
        this.showModal = true;
    }

    handleCloseModal() {
        this.showModal = false;
    }

    handleStartChange(e) {
        this.contractStart = e.target.value;
    }

    handleEndChange(e) {
        this.contractEnd = e.target.value;
    }

    async handleConvert() {
        this.isConverting = true;
        try {
            const saId = await convertToAgreement({
                opportunityId: this.recordId,
                contractStart: this.contractStart,
                contractEnd: this.contractEnd
            });
            this.showModal = false;
            this.dispatchEvent(new ShowToastEvent({
                title: '変換完了',
                message: '販売契約が作成されました。',
                variant: 'success'
            }));
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: saId,
                    objectApiName: 'Sales_Agreement__c',
                    actionName: 'view'
                }
            });
        } catch (err) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'エラー',
                message: err.body ? err.body.message : err.message,
                variant: 'error'
            }));
        } finally {
            this.isConverting = false;
        }
    }
}
