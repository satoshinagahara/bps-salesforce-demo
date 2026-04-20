import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getSites from '@salesforce/apex/SupplierPortalController.getManufacturingSites';
import saveSite from '@salesforce/apex/SupplierPortalController.saveManufacturingSite';
import deleteSite from '@salesforce/apex/SupplierPortalController.deleteManufacturingSite';

export default class ManufacturingSiteManager extends LightningElement {
    @api recordId;
    @api accountId;

    data;
    error;
    wiredResult;

    showEditModal = false;
    editMode = 'new';
    @track editForm = this.emptyForm();

    showDeleteConfirm = false;
    deleteTargetId;
    deleteTargetLabel;

    isSaving = false;

    @wire(getSites, { accountId: '$targetAccountId' })
    wiredSites(result) {
        this.wiredResult = result;
        if (result.data) {
            this.data = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = this.extractError(result.error);
            this.data = undefined;
        }
    }

    get targetAccountId() {
        return this.accountId || this.recordId || null;
    }

    get isLoading() {
        return !this.data && !this.error;
    }

    get hasItems() {
        return this.data && this.data.items.length > 0;
    }

    get mapMarkers() {
        if (!this.data) return [];
        return this.data.items
            .filter(s => s.latitude != null && s.longitude != null)
            .map(s => ({
                location: {
                    Latitude: s.latitude,
                    Longitude: s.longitude
                },
                title: s.name,
                description: `${s.prefecture ?? ''} ${s.address ?? ''}`,
                icon: s.isOwnSite ? 'standard:account' : 'standard:partners'
            }));
    }

    get hasMap() {
        return this.mapMarkers.length > 0;
    }

    get displayItems() {
        if (!this.data) return [];
        return this.data.items.map(s => ({
            ...s,
            badgeClass: s.isOwnSite ? 'msm-badge msm-badge--own' : 'msm-badge msm-badge--sub',
            badgeLabel: s.isOwnSite ? '自社拠点' : '協力会社',
            cardClass: s.isOwnSite ? 'msm-card msm-card--own' : 'msm-card',
            coordLabel: (s.latitude != null && s.longitude != null)
                ? `${Number(s.latitude).toFixed(4)}, ${Number(s.longitude).toFixed(4)}`
                : '—',
            capacityLabel: `${s.capacityItemCount ?? 0} 品目`
        }));
    }

    get modalTitle() {
        return this.editMode === 'new' ? '拠点を追加' : '拠点を編集';
    }

    emptyForm() {
        return {
            id: null,
            name: '',
            isOwnSite: false,
            prefecture: '',
            address: '',
            latitude: null,
            longitude: null,
            description: ''
        };
    }

    // === events ===
    openNewModal() {
        this.editMode = 'new';
        this.editForm = this.emptyForm();
        this.showEditModal = true;
    }

    openEditModal(event) {
        const id = event.currentTarget.dataset.itemId;
        const item = this.data.items.find(i => i.id === id);
        if (!item) return;
        this.editMode = 'edit';
        this.editForm = {
            id: item.id,
            name: item.name || '',
            isOwnSite: item.isOwnSite === true,
            prefecture: item.prefecture || '',
            address: item.address || '',
            latitude: item.latitude,
            longitude: item.longitude,
            description: item.description || ''
        };
        this.showEditModal = true;
    }

    closeModal() {
        this.showEditModal = false;
    }

    handleFieldChange(event) {
        const field = event.target.dataset.field;
        const value = event.target.type === 'checkbox'
            ? event.target.checked
            : event.target.value;
        this.editForm = { ...this.editForm, [field]: value };
    }

    async handleSave() {
        const f = this.editForm;
        if (!f.name) {
            this.showToast('入力不足', '拠点名は必須です。', 'warning');
            return;
        }
        this.isSaving = true;
        try {
            await saveSite({
                id: f.id,
                accountId: this.targetAccountId,
                name: f.name,
                isOwnSite: f.isOwnSite,
                prefecture: f.prefecture || null,
                address: f.address || null,
                latitude: f.latitude != null && f.latitude !== '' ? Number(f.latitude) : null,
                longitude: f.longitude != null && f.longitude !== '' ? Number(f.longitude) : null,
                description: f.description || null
            });
            this.showToast('保存完了', this.editMode === 'new' ? '拠点を追加しました。' : '拠点を更新しました。', 'success');
            this.showEditModal = false;
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.showToast('エラー', this.extractError(err), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    openDeleteConfirm(event) {
        const id = event.currentTarget.dataset.itemId;
        const item = this.data.items.find(i => i.id === id);
        if (!item) return;
        this.deleteTargetId = id;
        this.deleteTargetLabel = item.name;
        this.showDeleteConfirm = true;
    }

    closeDeleteConfirm() {
        this.showDeleteConfirm = false;
        this.deleteTargetId = null;
    }

    async handleDeleteConfirm() {
        this.isSaving = true;
        try {
            await deleteSite({ id: this.deleteTargetId });
            this.showToast('削除完了', '拠点を削除しました。', 'success');
            this.showDeleteConfirm = false;
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.showToast('エラー', this.extractError(err), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    // === utils ===
    extractError(err) {
        if (err?.body?.message) return err.body.message;
        if (Array.isArray(err?.body)) return err.body.map(e => e.message).join(', ');
        return err?.message || 'エラーが発生しました';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
