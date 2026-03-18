import { LightningElement, api, wire } from 'lwc';
import getCandidateNeeds from '@salesforce/apex/InitiativeNeedsMatcherController.getCandidateNeeds';
import analyzeRelevance from '@salesforce/apex/InitiativeNeedsMatcherController.analyzeRelevance';
import linkNeeds from '@salesforce/apex/InitiativeNeedsMatcherController.linkNeeds';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class InitiativeNeedsMatcher extends LightningElement {
    @api recordId;
    initiative = {};
    candidates = [];
    linkedCount = 0;
    error;
    isLoading = true;
    isAnalyzing = false;
    isLinking = false;
    hasAnalysis = false;
    analysisLines = [];
    selectedIds = new Set();
    _wiredResult;

    @wire(getCandidateNeeds, { initiativeId: '$recordId' })
    wiredData(result) {
        this._wiredResult = result;
        const { data, error } = result;
        this.isLoading = false;
        if (data) {
            this.initiative = data.initiative || {};
            this.linkedCount = data.linkedCount || 0;
            this.candidates = (data.candidates || []).map(c => ({
                ...c,
                selected: false,
                impactFormatted: c.impact ? this._formatCurrency(c.impact) : '',
                priorityClass: 'priority-' + (c.priority === '高' ? 'high' : (c.priority === '中' ? 'mid' : 'low')),
                priorityLabel: '優先度: ' + (c.priority || '−'),
                relevanceClass: 'relevance-' + (c.relevance === '高' ? 'high' : 'mid'),
                relevanceLabel: '関連度: ' + (c.relevance || '−'),
                cardClass: 'need-card'
            }));
            this.selectedIds = new Set();
            this.error = undefined;
        } else if (error) {
            this.error = error.body?.message || 'データ取得エラー';
        }
    }

    get hasCandidate() {
        return this.candidates.length > 0;
    }

    get candidateCount() {
        return this.candidates.length;
    }

    get selectedCount() {
        return this.selectedIds.size;
    }

    get hasSelection() {
        return this.selectedIds.size > 0;
    }

    get linkButtonLabel() {
        return `選択した ${this.selectedIds.size} 件を紐付け`;
    }

    get headerSubtext() {
        const parts = [];
        if (this.initiative.product) parts.push(this.initiative.product);
        if (this.initiative.family) parts.push(this.initiative.family);
        return parts.join(' / ');
    }

    get linkedLabel() {
        return `紐付け済み: ${this.linkedCount}件`;
    }

    handleCardClick(event) {
        const cardId = event.currentTarget.dataset.id;
        if (this.selectedIds.has(cardId)) {
            this.selectedIds.delete(cardId);
        } else {
            this.selectedIds.add(cardId);
        }
        // Force reactivity
        this.candidates = this.candidates.map(c => ({
            ...c,
            selected: this.selectedIds.has(c.id),
            cardClass: this.selectedIds.has(c.id) ? 'need-card need-card--selected' : 'need-card'
        }));
    }

    handleSelectAll() {
        const allSelected = this.selectedIds.size === this.candidates.length;
        if (allSelected) {
            this.selectedIds = new Set();
        } else {
            this.selectedIds = new Set(this.candidates.map(c => c.id));
        }
        this.candidates = this.candidates.map(c => ({
            ...c,
            selected: this.selectedIds.has(c.id),
            cardClass: this.selectedIds.has(c.id) ? 'need-card need-card--selected' : 'need-card'
        }));
    }

    get selectAllLabel() {
        return this.selectedIds.size === this.candidates.length ? '全解除' : '全選択';
    }

    handleAnalyze() {
        this.isAnalyzing = true;
        this.hasAnalysis = false;
        this.analysisLines = [];

        analyzeRelevance({ initiativeId: this.recordId })
            .then(result => {
                this.parseAnalysis(result);
                this.isAnalyzing = false;
                this.hasAnalysis = true;
            })
            .catch(err => {
                this.analysisLines = [{
                    key: 'err',
                    text: err.body?.message || err.message,
                    className: 'analysis-error'
                }];
                this.isAnalyzing = false;
                this.hasAnalysis = true;
            });
    }

    parseAnalysis(text) {
        if (!text) { this.analysisLines = []; return; }
        const lines = text.split('\n').filter(l => l.trim().length > 0);
        this.analysisLines = lines.map((line, idx) => {
            let className = 'analysis-line';
            const trimmed = line.trim();
            if (trimmed.startsWith('##') || trimmed.startsWith('**')) className = 'analysis-heading';
            else if (trimmed.startsWith('- ') || trimmed.startsWith('・')) className = 'analysis-bullet';
            else if (trimmed.includes('高関連')) className = 'analysis-high';
            return { key: 'a-' + idx, text: trimmed, className };
        });
    }

    handleCloseAnalysis() {
        this.hasAnalysis = false;
    }

    async handleLink() {
        if (this.selectedIds.size === 0) return;
        this.isLinking = true;
        try {
            await linkNeeds({
                initiativeId: this.recordId,
                needsCardIds: [...this.selectedIds]
            });
            this.dispatchEvent(new ShowToastEvent({
                title: '紐付け完了',
                message: `${this.selectedIds.size}件のニーズカードを紐付けました`,
                variant: 'success'
            }));
            this.selectedIds = new Set();
            this.hasAnalysis = false;
            await refreshApex(this._wiredResult);
        } catch (err) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'エラー',
                message: err.body?.message || err.message,
                variant: 'error'
            }));
        } finally {
            this.isLinking = false;
        }
    }

    _formatCurrency(val) {
        if (val >= 100000000) return '¥' + (val / 100000000).toFixed(1) + '億';
        if (val >= 10000) return '¥' + Math.round(val / 10000).toLocaleString() + '万';
        return '¥' + val.toLocaleString();
    }
}
