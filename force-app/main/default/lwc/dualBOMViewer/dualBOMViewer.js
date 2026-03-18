import { LightningElement, api, wire, track } from 'lwc';
import getDualBOMData from '@salesforce/apex/DualBOMController.getDualBOMData';
import { NavigationMixin } from 'lightning/navigation';

export default class DualBOMViewer extends NavigationMixin(LightningElement) {
    @api recordId;
    @track _data = null;
    @track error = null;
    @track isLoading = true;

    // Track expanded state per pane
    _expandedBase = {};
    _expandedNew = {};

    @wire(getDualBOMData, { recordId: '$recordId' })
    wiredData({ data, error }) {
        this.isLoading = false;
        if (data) {
            this._data = data;
            this.error = null;
            // Auto-expand all base tree nodes
            if (data.baseTree) {
                this._autoExpand(data.baseTree, '_expandedBase');
            }
            if (data.newTree) {
                this._autoExpand(data.newTree, '_expandedNew');
            }
        } else if (error) {
            this.error = error?.body?.message ?? 'データの取得に失敗しました';
            this._data = null;
        }
    }

    _autoExpand(tree, field) {
        const expanded = {};
        if (tree.lines) {
            for (const line of tree.lines) {
                expanded[line.id] = true;
                if (line.subComponents) {
                    for (const sub of line.subComponents) {
                        expanded[sub.id] = true;
                    }
                }
            }
        }
        this[field] = expanded;
    }

    get hasData() { return this._data?.project != null; }

    // ── Project info ──
    get proj() { return this._data?.project || {}; }
    get hasBaseBOM() { return this.proj.baseBomName != null; }
    get hasNewBOM() { return this.proj.newBomName != null; }
    get baseTitle() {
        const p = this.proj;
        return p.baseProductName ? `${p.baseProductName} (${p.baseProductCode})` : 'ベース製品未設定';
    }
    get baseBomInfo() {
        const p = this.proj;
        if (!p.baseBomName) return '';
        return `${p.baseBomName} Rev ${p.baseBomRevision || '-'} ・ ${p.baseBomStatus || ''} ・ ${p.baseBomType || ''}`;
    }
    get newTitle() {
        const p = this.proj;
        return p.newProductName ? `${p.newProductName} (${p.newProductCode})` : '新製品未設定';
    }
    get newBomInfo() {
        const p = this.proj;
        if (!p.newBomName) return '';
        return `${p.newBomName} Rev ${p.newBomRevision || '-'} ・ ${p.newBomStatus || ''} ・ ${p.newBomType || ''}`;
    }

    // ── Base tree ──
    get baseLines() {
        return this._buildTreeRows(this._data?.baseTree?.lines || [], this._expandedBase, true);
    }
    get basePartCount() { return this._data?.baseTree?.partCount || 0; }
    get baseLineCount() { return this._data?.baseTree?.lineCount || 0; }

    // ── New tree ──
    get newLines() {
        return this._buildTreeRows(this._data?.newTree?.lines || [], this._expandedNew, false);
    }
    get newPartCount() { return this._data?.newTree?.partCount || 0; }
    get newLineCount() { return this._data?.newTree?.lineCount || 0; }
    get newTreeEmpty() { return (this._data?.newTree?.lineCount || 0) === 0; }

    _buildTreeRows(lines, expanded, showRisk) {
        const rows = [];
        for (const line of lines) {
            const lineExpanded = expanded[line.id] || false;
            rows.push({
                key: line.id,
                id: line.id,
                name: line.name,
                type: 'line',
                indent: 0,
                icon: lineExpanded ? '\u25BC' : '\u25B6',
                detail: line.componentType || '',
                hasRisk: showRisk && line.hasRisk,
                isLine: true,
                isSub: false,
                isPart: false,
                risks: [],
                riskTooltip: ''
            });

            if (lineExpanded && line.subComponents) {
                for (const sub of line.subComponents) {
                    const subExpanded = expanded[sub.id] || false;
                    rows.push({
                        key: sub.id,
                        id: sub.id,
                        name: sub.name,
                        type: 'sub',
                        indent: 1,
                        icon: subExpanded ? '\u25BC' : '\u25B6',
                        detail: sub.materialType || '',
                        hasRisk: showRisk && sub.hasRisk,
                        isLine: false,
                        isSub: true,
                        isPart: false,
                        risks: [],
                        riskTooltip: ''
                    });

                    if (subExpanded && sub.parts) {
                        for (const part of sub.parts) {
                            const riskList = (showRisk && part.risks) ? part.risks : [];
                            const tooltip = riskList.map(r => `${r.name}: ${r.category}`).join('\n');
                            rows.push({
                                key: part.id,
                                id: part.id,
                                name: part.name,
                                type: 'part',
                                indent: 2,
                                icon: '\u25CF',
                                detail: part.supplierName ? `[${part.supplierName}]` : '',
                                hasRisk: showRisk && part.hasRisk,
                                isLine: false,
                                isSub: false,
                                isPart: true,
                                risks: riskList,
                                riskTooltip: tooltip
                            });
                        }
                    }
                }
            }
        }
        return rows;
    }

    handleToggleBase(event) {
        const nodeId = event.currentTarget.dataset.id;
        this._expandedBase = { ...this._expandedBase, [nodeId]: !this._expandedBase[nodeId] };
    }

    handleToggleNew(event) {
        const nodeId = event.currentTarget.dataset.id;
        this._expandedNew = { ...this._expandedNew, [nodeId]: !this._expandedNew[nodeId] };
    }

    handleNavigateCA(event) {
        const caId = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: caId,
                actionName: 'view'
            }
        });
    }
}
