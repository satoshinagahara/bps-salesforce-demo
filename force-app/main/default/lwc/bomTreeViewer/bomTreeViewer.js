import { LightningElement, api, wire, track } from 'lwc';
import getBOMTree from '@salesforce/apex/BOMTreeController.getBOMTree';

// ── Column definitions ────────────────────────────────────────────────────
const COLUMNS = [
    {
        label: 'BOM ツリー',
        fieldName: 'displayLabel',
        type: 'text',
        initialWidth: 300,
        wrapText: false,
        cellAttributes: { class: { fieldName: 'labelClass' } }
    },
    {
        label: 'Lv',
        fieldName: 'level',
        type: 'text',
        initialWidth: 42,
        cellAttributes: { alignment: 'center', class: { fieldName: 'levelClass' } }
    },
    {
        label: '種別 / 工程',
        fieldName: 'typeLabel',
        type: 'text',
        initialWidth: 105,
        wrapText: false
    },
    {
        label: 'サプライヤー',
        fieldName: 'supplierUrl',
        type: 'url',
        initialWidth: 120,
        typeAttributes: { label: { fieldName: 'supplierName' }, target: '_self' }
    },
    {
        label: '製造拠点',
        fieldName: 'siteName',
        type: 'text',
        initialWidth: 130
    },
    {
        label: '数量',
        fieldName: 'quantity',
        type: 'number',
        initialWidth: 68,
        cellAttributes: { alignment: 'right' },
        typeAttributes: { minimumFractionDigits: 0, maximumFractionDigits: 4 }
    },
    {
        label: '単位',
        fieldName: 'uom',
        type: 'text',
        initialWidth: 48,
        cellAttributes: { alignment: 'center' }
    },
    {
        label: '単価',
        fieldName: 'unitCost',
        type: 'currency',
        initialWidth: 95,
        cellAttributes: { alignment: 'right' },
        typeAttributes: { currencyCode: 'JPY', minimumFractionDigits: 0, maximumFractionDigits: 0 }
    },
    {
        label: '小計 / 総原価',
        fieldName: 'extendedCost',
        type: 'currency',
        initialWidth: 110,
        cellAttributes: { alignment: 'right' },
        typeAttributes: { currencyCode: 'JPY', minimumFractionDigits: 0, maximumFractionDigits: 0 }
    },
    {
        label: '構成比',
        fieldName: 'costPercent',
        type: 'text',
        initialWidth: 68,
        cellAttributes: { alignment: 'right' }
    },
    {
        label: '補足',
        fieldName: 'note',
        type: 'text',
        wrapText: false
    }
];

// ── Level config ──────────────────────────────────────────────────────────
const LV_CLASS = {
    L1: 'lv1-label',
    L2: 'lv2-label',
    L3: 'lv3-label',
    L4: 'lv4-label'
};

const DEPTH_MAP = { L1: 1, L2: 2, L3: 3, L4: 4 };

// ── Helpers ───────────────────────────────────────────────────────────────
function join(...parts) {
    return parts.filter(v => v != null && v !== '').join(' · ');
}

function collectIds(nodes, ids = []) {
    if (!nodes) return ids;
    for (const n of nodes) {
        ids.push(n.id);
        if (n._children) collectIds(n._children, ids);
    }
    return ids;
}

function transformNode(raw, totalCost) {
    const n = { ...raw };
    n.levelClass = LV_CLASS[raw.level] ?? '';
    n.labelClass = LV_CLASS[raw.level] ?? '';
    n.supplierName = '';
    n.supplierUrl = null;
    n.costPercent = '';

    switch (raw.level) {
        case 'L1':
            totalCost = raw.extendedCost || 0;
            n.displayLabel = join(
                raw.bomNumber,
                raw.assemblySite ? `@${raw.assemblySite}` : null,
                raw.revision ? `Rev.${raw.revision}` : null
            ) || '(無題)';
            n.typeLabel = join(raw.bomType, raw.status);
            n.costPercent = totalCost > 0 ? '100%' : '';
            n.note = raw.effectiveFrom
                ? `${raw.effectiveFrom}${raw.effectiveTo ? ' 〜 ' + raw.effectiveTo : ''}`
                : '';
            break;

        case 'L2':
            n.displayLabel = join(
                raw.lineNumber != null ? `行${raw.lineNumber}` : null,
                raw.componentName,
                raw.isPhantom ? '[ファントム]' : null
            ) || '(未設定)';
            n.typeLabel = raw.componentType ?? '';
            n.note = '';
            if (totalCost > 0 && raw.extendedCost != null) {
                n.costPercent = ((raw.extendedCost / totalCost) * 100).toFixed(1) + '%';
            }
            break;

        case 'L3':
            n.displayLabel = join(
                raw.sequence != null ? `工程${raw.sequence}` : null,
                raw.componentName
            ) || '(未設定)';
            n.typeLabel = join(raw.processType, raw.materialType);
            n.note = raw.required ? '製造必須' : '';
            if (totalCost > 0 && raw.extendedCost != null) {
                n.costPercent = ((raw.extendedCost / totalCost) * 100).toFixed(1) + '%';
            }
            break;

        case 'L4': {
            const label = join(raw.partNumber, raw.componentName) || '(未設定)';
            n.displayLabel = raw.isShared
                ? `★ ${label} (${raw.sharedProductCount}製品共通)`
                : label;
            n.typeLabel = join(raw.makeOrBuy, raw.materialType);
            n.supplierName = raw.supplierName ?? '';
            n.supplierUrl = raw.supplierId
                ? '/lightning/r/Account/' + raw.supplierId + '/view'
                : null;
            n.siteName = raw.siteName ?? '';
            n.note = raw.manufacturer ?? '';
            if (totalCost > 0 && raw.extendedCost != null) {
                const pct = (raw.extendedCost / totalCost) * 100;
                n.costPercent = pct >= 0.1 ? pct.toFixed(1) + '%' : '<0.1%';
            }
            if (raw.isShared) {
                n.labelClass = (LV_CLASS[raw.level] ?? '') + ' shared-part';
            }
            break;
        }

        default:
            n.displayLabel = raw.id;
            n.typeLabel = '';
            n.note = '';
    }

    if (raw._children) {
        n._children = raw._children.map(child => transformNode(child, totalCost));
    }
    return n;
}

function filterTree(nodes, searchTerm, maxDepth) {
    if (!nodes) return [];
    const result = [];
    for (const node of nodes) {
        const nodeDepth = DEPTH_MAP[node.level] || 4;
        if (maxDepth && nodeDepth > maxDepth) continue;

        let matchesSelf = true;
        if (searchTerm) {
            const term = searchTerm.toLowerCase();
            matchesSelf = (
                (node.displayLabel && node.displayLabel.toLowerCase().includes(term)) ||
                (node.supplierName && node.supplierName.toLowerCase().includes(term)) ||
                (node.typeLabel && node.typeLabel.toLowerCase().includes(term)) ||
                (node.note && node.note.toLowerCase().includes(term))
            );
        }

        let filteredChildren = node._children
            ? filterTree(node._children, searchTerm, maxDepth)
            : [];

        if (matchesSelf || filteredChildren.length > 0) {
            const copy = { ...node };
            if (filteredChildren.length > 0) {
                copy._children = filteredChildren;
            } else {
                delete copy._children;
            }
            result.push(copy);
        }
    }
    return result;
}

function collectSummary(nodes) {
    const stats = {
        bomCosts: [],
        bomCount: 0,
        partCount: 0,
        suppliers: new Set(),
        sharedParts: 0,
        lineCount: 0,
        subCount: 0
    };
    function walk(list) {
        if (!list) return;
        for (const n of list) {
            if (n.level === 'L1') {
                stats.bomCount++;
                stats.bomCosts.push(n.extendedCost || 0);
            }
            else if (n.level === 'L2') stats.lineCount++;
            else if (n.level === 'L3') stats.subCount++;
            else if (n.level === 'L4') {
                stats.partCount++;
                if (n.supplierName) stats.suppliers.add(n.supplierName);
                if (n.isShared) stats.sharedParts++;
            }
            if (n._children) walk(n._children);
        }
    }
    walk(nodes);
    return stats;
}

// ── Component ─────────────────────────────────────────────────────────────
export default class BomTreeViewer extends LightningElement {
    @api recordId;

    @track _treeData    = null;
    @track error        = null;
    @track isLoading    = true;
    @track expandedRows = [];
    @track searchTerm   = '';
    @track maxDepth     = 4;

    columns  = COLUMNS;
    _summary = null;

    @wire(getBOMTree, { productId: '$recordId' })
    wiredTree({ data, error }) {
        this.isLoading = false;
        if (data) {
            this._treeData = data.map(node => transformNode(node, 0));
            this._summary  = collectSummary(data);
            this.expandedRows = this._treeData.map(n => n.id);
            this.error = null;
        } else if (error) {
            this.error = error?.body?.message ?? 'データの取得に失敗しました';
            this._treeData = null;
            this._summary  = null;
        }
    }

    get treeData() {
        if (!this._treeData) return [];
        if (!this.searchTerm && this.maxDepth >= 4) return this._treeData;
        return filterTree(this._treeData, this.searchTerm, this.maxDepth);
    }

    get hasData()   { return this._treeData && this._treeData.length > 0; }
    get isEmpty()   { return !this.isLoading && !this.error && !this.hasData; }

    get noSearchResults() {
        return this.hasData && (this.searchTerm || this.maxDepth < 4) &&
               this.treeData.length === 0;
    }
    get hasTreeRows() {
        return this.treeData.length > 0;
    }

    // ── Summary ──────────────────────────────────────────────────────────
    get summaryBomCount()  { return this._summary?.bomCount ?? 0; }
    get summaryTotalCost() {
        if (!this._summary || this._summary.bomCosts.length === 0) return '¥0';
        if (this._summary.bomCosts.length === 1) {
            return '¥' + this._summary.bomCosts[0].toLocaleString();
        }
        // Multiple BOMs: show each separately
        return this._summary.bomCosts.map(c => '¥' + c.toLocaleString()).join(' / ');
    }
    get hasMultipleBoms()        { return (this._summary?.bomCount ?? 0) > 1; }
    get summaryPartCount()       { return this._summary?.partCount ?? 0; }
    get summarySupplierCount()   { return this._summary?.suppliers.size ?? 0; }
    get summarySharedPartCount() { return this._summary?.sharedParts ?? 0; }

    // ── Depth filter ─────────────────────────────────────────────────────
    get depthL2Variant() { return this.maxDepth === 2 ? 'brand' : 'neutral'; }
    get depthL3Variant() { return this.maxDepth === 3 ? 'brand' : 'neutral'; }
    get depthL4Variant() { return this.maxDepth === 4 ? 'brand' : 'neutral'; }

    handleDepthChange(event) {
        this.maxDepth = Number(event.target.dataset.depth);
        const filtered = this.treeData;
        if (filtered.length > 0) {
            this.expandedRows = collectIds(filtered);
        }
    }

    // ── Search ───────────────────────────────────────────────────────────
    handleSearch(event) {
        this.searchTerm = event.target.value;
        if (this.searchTerm) {
            const filtered = this.treeData;
            if (filtered.length > 0) {
                this.expandedRows = collectIds(filtered);
            }
        }
    }

    // ── Expand / Collapse ────────────────────────────────────────────────
    handleExpandAll() {
        const data = this.treeData;
        if (data.length > 0) {
            this.expandedRows = collectIds(data);
        }
    }

    handleCollapseAll() {
        this.expandedRows = [];
    }

    handleRowAction() {
        // Future
    }
}
