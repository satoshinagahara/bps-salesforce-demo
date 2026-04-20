import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCapacities from '@salesforce/apex/SupplierPortalController.getCapacities';
import saveCapacity from '@salesforce/apex/SupplierPortalController.saveCapacity';
import deleteCapacity from '@salesforce/apex/SupplierPortalController.deleteCapacity';

/**
 * サプライヤー キャパシティ管理LWC
 * - 拠点タブで切り替え、各拠点のキャパシティを編集・追加
 */
export default class SupplierCapacityManager extends LightningElement {
    @api recordId; // Account RecordPage配置時
    @api accountId;

    sites = [];
    error;
    wiredResult;
    @track selectedSiteId;

    // 編集モーダル状態
    showEditModal = false;
    editMode = 'new'; // 'new' | 'edit'
    @track editForm = {
        id: null,
        siteId: null,
        partNumber: '',
        partName: '',
        monthlyCapacity: null,
        effectiveFrom: null,
        effectiveTo: null,
        notes: ''
    };
    isSaving = false;

    // 削除確認
    showDeleteConfirm = false;
    deleteTargetId;
    deleteTargetPart;

    @wire(getCapacities, { accountId: '$targetAccountId' })
    wiredCapacities(result) {
        this.wiredResult = result;
        if (result.data) {
            this.sites = result.data;
            this.error = undefined;
            if (!this.selectedSiteId && this.sites.length > 0) {
                this.selectedSiteId = this.sites[0].siteId;
            }
        } else if (result.error) {
            this.error = this.extractError(result.error);
            this.sites = [];
        }
    }

    get targetAccountId() {
        return this.accountId || this.recordId || null;
    }

    get isLoading() {
        return !this.sites.length && !this.error;
    }

    get hasSites() {
        return this.sites.length > 0;
    }

    get siteTabs() {
        return this.sites.map(s => ({
            ...s,
            tabClass: s.siteId === this.selectedSiteId
                ? 'scm-tab scm-tab--active'
                : 'scm-tab'
        }));
    }

    get selectedSite() {
        return this.sites.find(s => s.siteId === this.selectedSiteId);
    }

    get selectedItems() {
        const site = this.selectedSite;
        if (!site) return [];
        return site.items.map(i => ({
            ...i,
            rowClass: i.isExpiringSoon ? 'scm-row scm-row--warn' : 'scm-row',
            monthlyCapacityLabel: this.fmtNumber(i.monthlyCapacity),
            effectiveFromLabel: this.fmtDate(i.effectiveFrom),
            effectiveToLabel: this.fmtDate(i.effectiveTo),
            lastModifiedLabel: this.fmtDateTime(i.lastModified)
        }));
    }

    get summaryLabel() {
        const s = this.selectedSite;
        if (!s) return '';
        return `品目 ${s.itemCount} 件 / 月産合計 ${this.fmtNumber(s.totalMonthlyCapacity)}`;
    }

    get hasExpiring() {
        return (this.selectedSite?.expiringCount ?? 0) > 0;
    }

    get expiringLabel() {
        return `期限間近 ${this.selectedSite?.expiringCount ?? 0} 件`;
    }

    get hasItems() {
        return (this.selectedSite?.items?.length ?? 0) > 0;
    }

    get modalTitle() {
        return this.editMode === 'new' ? 'キャパシティを追加' : 'キャパシティを編集';
    }

    // ==== タブ切替 ====
    handleTabClick(event) {
        this.selectedSiteId = event.currentTarget.dataset.siteId;
    }

    // ==== 編集モーダル開く ====
    openNewModal() {
        if (!this.selectedSiteId) return;
        this.editMode = 'new';
        this.editForm = {
            id: null,
            siteId: this.selectedSiteId,
            partNumber: '',
            partName: '',
            monthlyCapacity: null,
            effectiveFrom: null,
            effectiveTo: null,
            notes: ''
        };
        this.showEditModal = true;
    }

    openEditModal(event) {
        const id = event.currentTarget.dataset.itemId;
        const item = this.selectedSite?.items?.find(i => i.id === id);
        if (!item) return;
        this.editMode = 'edit';
        this.editForm = {
            id: item.id,
            siteId: item.siteId,
            partNumber: item.partNumber || '',
            partName: item.partName || '',
            monthlyCapacity: item.monthlyCapacity,
            effectiveFrom: item.effectiveFrom,
            effectiveTo: item.effectiveTo,
            notes: item.notes || ''
        };
        this.showEditModal = true;
    }

    closeModal() {
        this.showEditModal = false;
    }

    // ==== 編集フィールド変更 ====
    handleFieldChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.value;
        this.editForm = { ...this.editForm, [field]: value };
    }

    // ==== 保存 ====
    async handleSave() {
        const form = this.editForm;
        if (!form.partNumber) {
            this.showToast('入力不足', '品番は必須です。', 'warning');
            return;
        }
        if (form.monthlyCapacity == null || form.monthlyCapacity === '') {
            this.showToast('入力不足', '月産能力は必須です。', 'warning');
            return;
        }
        this.isSaving = true;
        try {
            await saveCapacity({
                id: form.id,
                siteId: form.siteId,
                partNumber: form.partNumber,
                partName: form.partName || null,
                monthlyCapacity: Number(form.monthlyCapacity),
                effectiveFrom: form.effectiveFrom || null,
                effectiveTo: form.effectiveTo || null,
                notes: form.notes || null
            });
            const msg = this.editMode === 'new' ? '追加しました' : '更新しました';
            this.showToast('保存完了', msg, 'success');
            this.showEditModal = false;
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.showToast('エラー', this.extractError(err), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    // ==== 削除 ====
    openDeleteConfirm(event) {
        this.deleteTargetId = event.currentTarget.dataset.itemId;
        this.deleteTargetPart = event.currentTarget.dataset.itemPart;
        this.showDeleteConfirm = true;
    }

    closeDeleteConfirm() {
        this.showDeleteConfirm = false;
        this.deleteTargetId = null;
    }

    async handleDeleteConfirm() {
        this.isSaving = true;
        try {
            await deleteCapacity({ id: this.deleteTargetId });
            this.showToast('削除完了', '削除しました。', 'success');
            this.showDeleteConfirm = false;
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.showToast('エラー', this.extractError(err), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    // ==== ユーティリティ ====
    fmtDate(d) {
        if (!d) return '—';
        const dt = typeof d === 'string' ? new Date(d) : d;
        return `${dt.getFullYear()}/${String(dt.getMonth() + 1).padStart(2, '0')}/${String(dt.getDate()).padStart(2, '0')}`;
    }

    fmtDateTime(d) {
        if (!d) return '—';
        const dt = typeof d === 'string' ? new Date(d) : d;
        return `${dt.getFullYear()}/${String(dt.getMonth() + 1).padStart(2, '0')}/${String(dt.getDate()).padStart(2, '0')} ${String(dt.getHours()).padStart(2, '0')}:${String(dt.getMinutes()).padStart(2, '0')}`;
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
