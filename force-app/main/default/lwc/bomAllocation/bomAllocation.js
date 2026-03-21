import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getProductsWithBom from '@salesforce/apex/BOMAllocationController.getProductsWithBom';
import getBomCandidates from '@salesforce/apex/BOMAllocationController.getBomCandidates';
import assignBom from '@salesforce/apex/BOMAllocationController.assignBom';
import splitProduct from '@salesforce/apex/BOMAllocationController.splitProduct';

export default class BomAllocation extends LightningElement {
    @api recordId;
    @track products = [];
    isLoading = true;
    _wiredResult;

    // BOM選択モーダル
    showBomModal = false;
    modalProductName = '';
    modalSapId = null;
    modalProductId = null;
    @track bomCandidates = [];
    loadingCandidates = false;
    selectedBomId = null;

    // 分割モーダル
    showSplitModal = false;
    splitSapId = null;
    splitSourceBom = '';
    splitSourceQty = 0;
    splitPercent = 40;
    splitNewBomId = null;

    @wire(getProductsWithBom, { agreementId: '$recordId' })
    wiredProducts(result) {
        this._wiredResult = result;
        this.isLoading = false;
        if (result.data) {
            this.products = result.data.map(p => ({
                ...p,
                bomDisplay: p.bomNumber ? `${p.bomNumber} Rev.${p.bomRevision || '-'}` : '',
                monthlyQtyDisplay: p.monthlyQty != null ? Math.round(p.monthlyQty) + ' 台' : '',
                statusClass: p.bomStatus === '承認済' ? 'slds-badge_success'
                    : p.bomStatus === '廃止' ? 'slds-badge_error' : '',
                rowClass: !p.hasBom && p.needsAttention ? 'slds-hint-parent bom-warn-row' : 'slds-hint-parent',
                bomButtonLabel: p.hasBom ? '変更' : '設定',
                bomButtonVariant: p.hasBom ? 'neutral' : 'brand',
                canSplit: p.hasBom && p.bomCandidateCount > 1
            }));
        }
    }

    get hasProducts() {
        return this.products.length > 0;
    }

    // ==========================================
    // BOM選択モーダル
    // ==========================================

    async handleSelectBom(event) {
        this.modalSapId = event.currentTarget.dataset.sapId;
        this.modalProductId = event.currentTarget.dataset.productId;
        const prod = this.products.find(p => p.sapId === this.modalSapId);
        this.modalProductName = prod ? prod.productName : '';
        this.selectedBomId = prod ? prod.bomHeaderId : null;
        this.showBomModal = true;
        await this.loadCandidates();
    }

    async loadCandidates() {
        this.loadingCandidates = true;
        try {
            const data = await getBomCandidates({ productId: this.modalProductId });
            this.bomCandidates = data.map(c => ({
                ...c,
                isSelected: c.bomHeaderId === this.selectedBomId,
                assemblySiteDisplay: c.assemblySite || '未設定',
                statusBadgeClass: c.status === '承認済' ? 'slds-badge_success'
                    : c.status === '廃止' ? 'slds-badge_error' : '',
                cardClass: c.bomHeaderId === this.selectedBomId
                    ? 'slds-box slds-m-bottom_small slds-theme_shade'
                    : 'slds-box slds-m-bottom_small'
            }));
        } catch (error) {
            this.showToast('エラー', error.body?.message || error.message, 'error');
        } finally {
            this.loadingCandidates = false;
        }
    }

    handleCandidateClick(event) {
        const bomId = event.currentTarget.dataset.bomId;
        this.selectedBomId = bomId;
        this.bomCandidates = this.bomCandidates.map(c => ({
            ...c,
            isSelected: c.bomHeaderId === bomId,
            cardClass: c.bomHeaderId === bomId
                ? 'slds-box slds-m-bottom_small slds-theme_shade'
                : 'slds-box slds-m-bottom_small'
        }));
    }

    get confirmDisabled() {
        return !this.selectedBomId;
    }

    handleCloseModal() {
        this.showBomModal = false;
    }

    async handleConfirmBom() {
        try {
            await assignBom({ sapId: this.modalSapId, bomHeaderId: this.selectedBomId });
            this.showBomModal = false;
            this.showToast('保存完了', 'BOMを設定しました。', 'success');
            await refreshApex(this._wiredResult);
        } catch (error) {
            this.showToast('エラー', error.body?.message || error.message, 'error');
        }
    }

    // ==========================================
    // 分割モーダル
    // ==========================================

    async handleSplit(event) {
        this.splitSapId = event.currentTarget.dataset.sapId;
        this.modalProductId = event.currentTarget.dataset.productId;
        const prod = this.products.find(p => p.sapId === this.splitSapId);
        this.modalProductName = prod ? prod.productName : '';
        this.splitSourceBom = prod ? prod.bomDisplay : '';
        this.splitSourceQty = prod && prod.monthlyQty ? Math.round(prod.monthlyQty) : 0;
        this.splitPercent = 40;
        this.splitNewBomId = null;
        this.showSplitModal = true;
        await this.loadCandidates();
    }

    get splitBomOptions() {
        const currentBomId = this.products.find(p => p.sapId === this.splitSapId)?.bomHeaderId;
        return this.bomCandidates
            .filter(c => c.bomHeaderId !== currentBomId && c.isApproved)
            .map(c => ({
                label: `${c.bomNumber} (${c.assemblySiteDisplay})`,
                value: c.bomHeaderId
            }));
    }

    get splitKeepPct() {
        return 100 - this.splitPercent;
    }

    get splitKeepQty() {
        return Math.round(this.splitSourceQty * (1 - this.splitPercent / 100));
    }

    get splitNewQty() {
        return this.splitSourceQty - this.splitKeepQty;
    }

    get splitValid() {
        return this.splitKeepQty + this.splitNewQty === this.splitSourceQty;
    }

    get splitConfirmDisabled() {
        return !this.splitNewBomId || !this.splitValid;
    }

    handleSplitPercentChange(event) {
        this.splitPercent = parseInt(event.detail.value, 10);
    }

    handleSplitBomChange(event) {
        this.splitNewBomId = event.detail.value;
    }

    handleCloseSplit() {
        this.showSplitModal = false;
    }

    async handleConfirmSplit() {
        try {
            const ratio = this.splitPercent / 100;
            await splitProduct({
                sapId: this.splitSapId,
                newBomHeaderId: this.splitNewBomId,
                splitRatio: ratio
            });
            this.showSplitModal = false;
            this.showToast('分割完了', '契約製品を分割しました。スケジュールも按分されています。', 'success');
            await refreshApex(this._wiredResult);
        } catch (error) {
            this.showToast('エラー', error.body?.message || error.message, 'error');
        }
    }

    // ==========================================
    // ユーティリティ
    // ==========================================

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
