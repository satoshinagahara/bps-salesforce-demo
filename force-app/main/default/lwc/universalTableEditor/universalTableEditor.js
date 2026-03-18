import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getObjectList  from '@salesforce/apex/UniversalTableEditorController.getObjectList';
import getObjectSchema from '@salesforce/apex/UniversalTableEditorController.getObjectSchema';
import getRecords     from '@salesforce/apex/UniversalTableEditorController.getRecords';
import updateRecords  from '@salesforce/apex/UniversalTableEditorController.updateRecords';

const DEFAULT_LIMIT       = 50;
const DEFAULT_FIELD_COUNT = 8;

// datatable の typeAttributes デフォルト
const TYPE_ATTRS = {
    currency:     { currencyCode: 'JPY', minimumFractionDigits: 0, maximumFractionDigits: 0 },
    percent:      { minimumFractionDigits: 0, maximumFractionDigits: 2 },
    date:         { year: 'numeric', month: '2-digit', day: '2-digit',
                    hour: '2-digit', minute: '2-digit' },
    'date-local': { year: 'numeric', month: '2-digit', day: '2-digit' }
};

export default class UniversalTableEditor extends LightningElement {

    // ── State ────────────────────────────────────────────────────────────
    @track objectOptions     = [];
    @track selectedObject    = '';
    @track schemaFields      = [];       // Apex から取得した全フィールドメタ
    @track visibleFieldNames = [];       // 表示中フィールドの API 名リスト（順序付き）
    @track tableData         = [];
    @track draftValues       = [];
    @track pendingChanges    = {};       // { [recordId]: { Id, ...変更フィールド } }

    @track isLoadingObjects  = true;
    @track isLoadingData     = false;
    @track isSaving          = false;
    @track errorMessage      = null;
    @track showFieldSelector = false;

    @track sortField         = '';
    @track sortDirection     = 'asc';

    recordLimit = DEFAULT_LIMIT;

    // ── Lifecycle ────────────────────────────────────────────────────────
    connectedCallback() {
        this._loadObjectList();
    }

    // ── Computed ─────────────────────────────────────────────────────────
    get hasSchema()          { return this.schemaFields.length > 0; }
    get hasData()            { return !this.isLoadingData && !this.errorMessage && this.tableData.length > 0; }
    get isEmpty()            { return !this.isLoadingData && !this.errorMessage && !!this.selectedObject && this.tableData.length === 0; }
    get hasPending()         { return Object.keys(this.pendingChanges).length > 0; }
    get isRefreshDisabled()  { return !this.selectedObject || this.isLoadingData; }

    get pendingBadgeLabel() {
        return `${Object.keys(this.pendingChanges).length} 件 未保存`;
    }
    get fieldSelectorLabel() {
        return `フィールド選択 (${this.visibleFieldNames.length} / ${this.schemaFields.length})`;
    }
    get recordCountLabel() {
        return `${this.tableData.length} 件表示（最大 ${this.recordLimit} 件 / 新着順）`;
    }

    // schemaFields に visible フラグ・バッジ情報を付加して返す
    get schemaFieldsDisplay() {
        return this.schemaFields.map(f => ({
            ...f,
            visible:       this.visibleFieldNames.includes(f.fieldName),
            editBadge:     f.editable ? '🖊' : '👁',
            editBadgeClass: f.editable ? 'badge badge-edit' : 'badge badge-ro'
        }));
    }

    // lightning-datatable 用カラム定義
    get tableColumns() {
        const schemaMap = new Map(this.schemaFields.map(f => [f.fieldName, f]));
        return this.visibleFieldNames
            .filter(fn => schemaMap.has(fn))
            .map(fn => {
                const f = schemaMap.get(fn);
                const col = {
                    label:        f.label,
                    fieldName:    f.fieldName,
                    type:         f.type,
                    editable:     f.editable && !this.isSaving,
                    sortable:     true,
                    wrapText:     false,
                    initialWidth: f.isNameField ? 200 : undefined
                };
                // typeAttributes
                const defaultAttrs = TYPE_ATTRS[f.type];
                if (defaultAttrs) {
                    col.typeAttributes = { ...defaultAttrs };
                }
                if (f.type === 'number') {
                    col.typeAttributes = {
                        minimumFractionDigits: 0,
                        maximumFractionDigits: f.scale || 2
                    };
                }
                return col;
            });
    }

    // ── Data Loading ─────────────────────────────────────────────────────
    async _loadObjectList() {
        try {
            const list = await getObjectList();
            this.objectOptions = [...list].sort((a, b) =>
                a.label.localeCompare(b.label, 'ja')
            );
        } catch (e) {
            this.errorMessage = e?.body?.message ?? 'オブジェクト一覧の取得に失敗しました';
        } finally {
            this.isLoadingObjects = false;
        }
    }

    async _loadSchema() {
        try {
            const fields = await getObjectSchema({ objectApiName: this.selectedObject });
            this.schemaFields = fields;

            // デフォルト表示フィールドを選定
            // Name フィールド → 編集可フィールド → 参照専用フィールド の順
            const nameField = fields.find(f => f.isNameField);
            const editables = fields.filter(f => !f.isNameField && f.editable);
            const readOnly  = fields.filter(f => !f.isNameField && !f.editable);

            const defaults = [];
            if (nameField) defaults.push(nameField.fieldName);
            for (const f of [...editables, ...readOnly]) {
                if (defaults.length >= DEFAULT_FIELD_COUNT) break;
                defaults.push(f.fieldName);
            }
            this.visibleFieldNames = defaults;
        } catch (e) {
            this.errorMessage = e?.body?.message ?? 'スキーマ取得に失敗しました';
        }
    }

    async _loadRecords() {
        if (!this.selectedObject || this.visibleFieldNames.length === 0) return;
        this.isLoadingData = true;
        this.errorMessage  = null;
        try {
            this.tableData = await getRecords({
                objectApiName: this.selectedObject,
                fieldsCsv:     this.visibleFieldNames.join(','),
                limitSize:     this.recordLimit
            });
            // ソート状態をリセット
            this.sortField     = '';
            this.sortDirection = 'asc';
        } catch (e) {
            this.errorMessage = e?.body?.message ?? 'レコード取得に失敗しました';
            this.tableData    = [];
        } finally {
            this.isLoadingData = false;
        }
    }

    // ── Event Handlers ───────────────────────────────────────────────────
    async handleObjectChange(event) {
        const obj = event.detail.value;
        if (obj === this.selectedObject) return;

        this.selectedObject    = obj;
        this.schemaFields      = [];
        this.visibleFieldNames = [];
        this.tableData         = [];
        this.draftValues       = [];
        this.pendingChanges    = {};
        this.errorMessage      = null;
        this.showFieldSelector = false;
        this.sortField         = '';

        if (!obj) return;
        await this._loadSchema();
        await this._loadRecords();
    }

    handleLimitChange(event) {
        const v = parseInt(event.detail.value, 10);
        this.recordLimit = (v >= 1 && v <= 200) ? v : DEFAULT_LIMIT;
    }

    async handleRefresh() {
        this.draftValues    = [];
        this.pendingChanges = {};
        await this._loadRecords();
    }

    toggleFieldSelector() {
        this.showFieldSelector = !this.showFieldSelector;
    }

    async handleFieldToggle(event) {
        const field   = event.target.dataset.field;
        const checked = event.target.checked;
        this.visibleFieldNames = checked
            ? [...this.visibleFieldNames, field]
            : this.visibleFieldNames.filter(f => f !== field);
        await this._loadRecords();
    }

    async handleSelectAllFields() {
        this.visibleFieldNames = this.schemaFields.map(f => f.fieldName);
        await this._loadRecords();
    }

    async handleClearFields() {
        const nameField = this.schemaFields.find(f => f.isNameField);
        this.visibleFieldNames = nameField ? [nameField.fieldName] : [];
        await this._loadRecords();
    }

    // datatable のセル確定イベント（各セルの ✓ ボタン）
    handleCellSave(event) {
        const pending = { ...this.pendingChanges };
        for (const row of event.detail.draftValues) {
            pending[row.Id] = Object.assign({}, pending[row.Id] ?? { Id: row.Id }, row);
        }
        this.pendingChanges = pending;
        this.draftValues    = Object.values(pending);
    }

    // クライアントサイドソート
    handleSort(event) {
        const { fieldName, sortDirection } = event.detail;
        this.sortField     = fieldName;
        this.sortDirection = sortDirection;
        this.tableData     = [...this.tableData].sort((a, b) => {
            const av = a[fieldName] ?? '';
            const bv = b[fieldName] ?? '';
            const cmp = av < bv ? -1 : av > bv ? 1 : 0;
            return sortDirection === 'asc' ? cmp : -cmp;
        });
    }

    async handleSaveAll() {
        if (!this.hasPending || this.isSaving) return;
        this.isSaving = true;
        try {
            await updateRecords({
                objectApiName: this.selectedObject,
                changedRows:   Object.values(this.pendingChanges)
            });
            const count = Object.keys(this.pendingChanges).length;
            this._toast('保存完了', `${count} 件のレコードを保存しました`, 'success');
            this.pendingChanges = {};
            this.draftValues    = [];
            await this._loadRecords();
        } catch (e) {
            this._toast('保存エラー', e?.body?.message ?? '保存に失敗しました', 'error', 'sticky');
        } finally {
            this.isSaving = false;
        }
    }

    handleDiscard() {
        this.pendingChanges = {};
        this.draftValues    = [];
        this._toast('変更を破棄しました', '', 'info');
    }

    // ── Utils ────────────────────────────────────────────────────────────
    _toast(title, message, variant, mode = 'dismissable') {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
    }
}
