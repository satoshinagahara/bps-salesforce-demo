import { LightningElement, api, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getCertifications from '@salesforce/apex/SupplierPortalController.getCertifications';
import saveCertification from '@salesforce/apex/SupplierPortalController.saveCertification';
import deleteCertification from '@salesforce/apex/SupplierPortalController.deleteCertification';

const CERT_TYPES = [
    { label: 'ISO9001', value: 'ISO9001' },
    { label: 'ISO14001', value: 'ISO14001' },
    { label: 'IATF16949', value: 'IATF16949' },
    { label: 'ISO45001', value: 'ISO45001' },
    { label: 'RoHS', value: 'RoHS' },
    { label: 'REACH', value: 'REACH' },
    { label: 'UL', value: 'UL' },
    { label: 'その他', value: 'その他' }
];

const STATUS_OPTIONS = [
    { label: '有効', value: '有効' },
    { label: '更新中', value: '更新中' },
    { label: '期限切れ', value: '期限切れ' },
    { label: '失効', value: '失効' }
];

const FILTERS = [
    { key: 'all',      label: 'すべて' },
    { key: 'valid',    label: '有効' },
    { key: 'expiring', label: '期限間近' },
    { key: 'expired',  label: '期限切れ' }
];

export default class SupplierCertificationList extends LightningElement {
    @api recordId;
    @api accountId;

    data;
    error;
    wiredResult;

    @track selectedFilter = 'all';

    // Modal state
    showEditModal = false;
    editMode = 'new';
    @track editForm = this.emptyForm();

    showDeleteConfirm = false;
    deleteTargetId;
    deleteTargetLabel;

    isSaving = false;

    certTypeOptions = CERT_TYPES;
    statusOptions = STATUS_OPTIONS;

    @wire(getCertifications, { accountId: '$targetAccountId' })
    wiredCerts(result) {
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

    get summary() {
        const d = this.data;
        if (!d) return {};
        return d;
    }

    get filters() {
        const d = this.data;
        return FILTERS.map(f => {
            let count = 0;
            if (!d) count = 0;
            else if (f.key === 'all')      count = d.totalCount;
            else if (f.key === 'valid')    count = d.validCount;
            else if (f.key === 'expiring') count = d.expiringCount;
            else if (f.key === 'expired')  count = d.expiredCount;
            return {
                ...f,
                count,
                cssClass: f.key === this.selectedFilter
                    ? 'scl-filter scl-filter--active'
                    : 'scl-filter'
            };
        });
    }

    get filteredItems() {
        if (!this.data) return [];
        return this.data.items
            .filter(i => {
                if (this.selectedFilter === 'all') return true;
                if (this.selectedFilter === 'valid')    return i.derivedStatus === 'VALID';
                if (this.selectedFilter === 'expiring') return i.derivedStatus === 'EXPIRING_SOON';
                if (this.selectedFilter === 'expired')  return i.derivedStatus === 'EXPIRED';
                return true;
            })
            .map(i => ({
                ...i,
                cardClass: this.cardClass(i),
                badgeClass: this.badgeClass(i),
                badgeLabel: this.badgeLabel(i),
                issueDateLabel: this.fmtDate(i.issueDate),
                expiryDateLabel: this.fmtDate(i.expiryDate),
                nextSurveyLabel: this.fmtDate(i.nextSurveillanceDate),
                countdownLabel: this.countdownLabel(i),
                countdownClass: this.countdownClass(i),
                typeIconClass: this.typeIconClass(i.certType)
            }));
    }

    get hasFilteredItems() {
        return this.filteredItems.length > 0;
    }

    get modalTitle() {
        return this.editMode === 'new' ? '認証を追加' : '認証を編集';
    }

    // === Helpers ===
    cardClass(i) {
        if (i.derivedStatus === 'EXPIRED') return 'scl-card scl-card--expired';
        if (i.derivedStatus === 'EXPIRING_SOON') return 'scl-card scl-card--warn';
        return 'scl-card';
    }

    badgeClass(i) {
        if (i.derivedStatus === 'EXPIRED') return 'scl-badge scl-badge--expired';
        if (i.derivedStatus === 'EXPIRING_SOON') return 'scl-badge scl-badge--warn';
        if (i.derivedStatus === 'VALID') return 'scl-badge scl-badge--ok';
        return 'scl-badge scl-badge--muted';
    }

    badgeLabel(i) {
        if (i.derivedStatus === 'EXPIRED') return '期限切れ';
        if (i.derivedStatus === 'EXPIRING_SOON') return '期限間近';
        if (i.derivedStatus === 'VALID') return '有効';
        return '不明';
    }

    countdownLabel(i) {
        if (i.daysToExpiry == null) return '';
        if (i.daysToExpiry < 0) return `期限超過 ${Math.abs(i.daysToExpiry)} 日`;
        if (i.daysToExpiry === 0) return '本日期限';
        return `残り ${i.daysToExpiry} 日`;
    }

    countdownClass(i) {
        if (i.daysToExpiry == null) return 'scl-countdown';
        if (i.daysToExpiry < 0) return 'scl-countdown scl-countdown--expired';
        if (i.daysToExpiry <= 30) return 'scl-countdown scl-countdown--warn';
        return 'scl-countdown';
    }

    typeIconClass(certType) {
        // CSS class color based on cert family
        if (certType === 'ISO9001' || certType === 'IATF16949') return 'scl-type-icon scl-type-icon--quality';
        if (certType === 'ISO14001') return 'scl-type-icon scl-type-icon--env';
        if (certType === 'ISO45001') return 'scl-type-icon scl-type-icon--safety';
        if (certType === 'RoHS' || certType === 'REACH') return 'scl-type-icon scl-type-icon--compliance';
        if (certType === 'UL') return 'scl-type-icon scl-type-icon--product';
        return 'scl-type-icon scl-type-icon--other';
    }

    emptyForm() {
        return {
            id: null,
            certType: null,
            status: '有効',
            issuingBody: '',
            issueDate: null,
            expiryDate: null,
            lastSurveillanceDate: null,
            nextSurveillanceDate: null,
            scope: '',
            notes: ''
        };
    }

    // === Events ===
    handleFilterClick(event) {
        this.selectedFilter = event.currentTarget.dataset.key;
    }

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
            certType: item.certType,
            status: item.status || '有効',
            issuingBody: item.issuingBody || '',
            issueDate: item.issueDate,
            expiryDate: item.expiryDate,
            lastSurveillanceDate: item.lastSurveillanceDate,
            nextSurveillanceDate: item.nextSurveillanceDate,
            scope: item.scope || '',
            notes: item.notes || ''
        };
        this.showEditModal = true;
    }

    closeModal() {
        this.showEditModal = false;
    }

    handleFieldChange(event) {
        const field = event.target.dataset.field;
        this.editForm = { ...this.editForm, [field]: event.target.value };
    }

    async handleSave() {
        const f = this.editForm;
        if (!f.certType) return this.showToast('入力不足', '認証種別は必須です。', 'warning');
        if (!f.issuingBody) return this.showToast('入力不足', '認証機関は必須です。', 'warning');
        if (!f.expiryDate) return this.showToast('入力不足', '有効期限は必須です。', 'warning');

        this.isSaving = true;
        try {
            await saveCertification({
                id: f.id,
                accountId: this.targetAccountId,
                certType: f.certType,
                status: f.status || '有効',
                issuingBody: f.issuingBody,
                issueDate: f.issueDate || null,
                expiryDate: f.expiryDate,
                lastSurveillanceDate: f.lastSurveillanceDate || null,
                nextSurveillanceDate: f.nextSurveillanceDate || null,
                scope: f.scope || null,
                notes: f.notes || null
            });
            this.showToast('保存完了', this.editMode === 'new' ? '認証を追加しました。' : '認証を更新しました。', 'success');
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
        this.deleteTargetLabel = `${item.certType} / ${item.name}`;
        this.showDeleteConfirm = true;
    }

    closeDeleteConfirm() {
        this.showDeleteConfirm = false;
        this.deleteTargetId = null;
    }

    async handleDeleteConfirm() {
        this.isSaving = true;
        try {
            await deleteCertification({ id: this.deleteTargetId });
            this.showToast('削除完了', '認証を削除しました。', 'success');
            this.showDeleteConfirm = false;
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.showToast('エラー', this.extractError(err), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    // === Utils ===
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
