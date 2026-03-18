import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAnalysisData from '@salesforce/apex/NeedsAnalysisController.getAnalysisData';
import analyzeSegment from '@salesforce/apex/NeedsAnalysisController.analyzeSegment';
import suggestInitiative from '@salesforce/apex/NeedsAnalysisController.suggestInitiative';
import createInitiativeFromDashboard from '@salesforce/apex/NeedsAnalysisController.createInitiativeFromDashboard';

const NEED_TYPE_COLORS = {
    '製品ニーズ': '#3498db',
    'サービスニーズ': '#27ae60',
    '新規案件': '#9b59b6',
    '改善要望': '#f39c12',
    'クレーム': '#e74c3c',
    '未分類': '#95a5a6'
};

const FAMILY_COLORS = ['#2563eb', '#dc2626', '#059669', '#d97706', '#7c3aed', '#0891b2', '#be185d', '#4b5563'];
const INDUSTRY_COLORS = ['#2e86de', '#e74c3c', '#27ae60', '#f39c12', '#8e44ad', '#1abc9c', '#e67e22', '#95a5a6'];
const FRESHNESS = { fresh: '#10b981', aging: '#f59e0b', stale: '#9ca3af' };

export default class NeedsAnalysisDashboard extends NavigationMixin(LightningElement) {
    // Data
    totalCount = 0;
    highPriorityCount = 0;
    totalImpactFormatted = '';
    freshCount = 0;
    agingCount = 0;
    staleCount = 0;

    // Chart data
    productFamilyItems = [];
    productNeedTypeMatrix = { rows: [], headers: [] };
    productIndustryMatrix = { rows: [], headers: [] };
    industryNeedTypeMatrix = { rows: [], headers: [] };
    accountItems = [];

    // Raw data for metric toggle
    _rawData = null;

    // State
    error;
    isLoading = true;
    isAnalyzing = false;
    hasInsight = false;
    insightTitle = '';
    insightLines = [];

    // Initiative modal state
    showInitiativeModal = false;
    isSuggesting = false;
    isCreating = false;
    initTitle = '';
    initWhat = '';
    initWhy = '';
    initPriority = '中';
    initProductId = '';
    initProductOptions = [];
    initCardIds = [];
    initCardCount = 0;
    _lastFilterType = '';
    _lastFilterValue = '';

    // Controls
    activeChart = 'productFamily';
    metric = 'count'; // 'count' or 'impact'
    monthsBack = 0;   // 0=all, 3, 6, 12
    segment = 'all';  // 初回は全体で取得→セグメント一覧確定後にデフォルト設定
    _segments = [];    // Apexから動的に取得
    _defaultSet = false;

    get segmentOptions() {
        const opts = this._segments.map(s => ({
            label: s,
            value: s,
            cls: this.segment === s ? 'seg-btn seg-btn--active-dynamic' : 'seg-btn'
        }));
        // 2つ以上のセグメントがある場合のみ「全体」を表示
        if (this._segments.length > 1) {
            opts.push({
                label: '全体',
                value: 'all',
                cls: this.segment === 'all' ? 'seg-btn seg-btn--all' : 'seg-btn'
            });
        }
        return opts;
    }

    // Time filter options
    get timeFilterOptions() {
        return [
            { label: '全期間', value: 0, cls: this.monthsBack === 0 ? 'filter-btn filter-btn--active' : 'filter-btn' },
            { label: '3ヶ月', value: 3, cls: this.monthsBack === 3 ? 'filter-btn filter-btn--active' : 'filter-btn' },
            { label: '6ヶ月', value: 6, cls: this.monthsBack === 6 ? 'filter-btn filter-btn--active' : 'filter-btn' },
            { label: '1年', value: 12, cls: this.monthsBack === 12 ? 'filter-btn filter-btn--active' : 'filter-btn' }
        ];
    }

    get metricCountClass() { return this.metric === 'count' ? 'filter-btn filter-btn--active' : 'filter-btn'; }
    get metricImpactClass() { return this.metric === 'impact' ? 'filter-btn filter-btn--active' : 'filter-btn'; }

    @wire(getAnalysisData, { monthsBack: '$monthsBack', segment: '$segment' })
    wiredData({ data, error }) {
        if (data) {
            this.isLoading = false;
            this.error = undefined;
            this._rawData = data;
            this.processData(data);
        } else if (error) {
            this.isLoading = false;
            this.error = error.body ? error.body.message : 'データ取得エラー';
        }
    }

    processData(data) {
        // 動的セグメント一覧
        if (data.segments) {
            this._segments = data.segments;
        }
        // 初回ロード時: セグメントが複数あれば最初の非サプライヤー値をデフォルトに
        if (!this._defaultSet && this._segments.length > 1) {
            const nonSupplier = this._segments.find(s => s !== 'サプライヤー');
            if (nonSupplier && this.segment === 'all') {
                this._defaultSet = true;
                this.segment = nonSupplier; // reactive → wire再発火
                return; // 再発火されるのでここでは処理しない
            }
        }
        this._defaultSet = true;

        this.totalCount = data.totalCount || 0;
        this.highPriorityCount = data.highPriorityCount || 0;
        this.totalImpactFormatted = this.formatCurrency(data.totalImpact || 0);
        this.freshCount = data.freshCount || 0;
        this.agingCount = data.agingCount || 0;
        this.staleCount = data.staleCount || 0;

        const useImpact = this.metric === 'impact';

        this.processProductFamily(
            data.byProductFamily || {},
            useImpact ? (data.impactByProductFamily || {}) : null,
            data.productFamilyFreshness || {}
        );
        this.productNeedTypeMatrix = this.buildMatrix(
            data.byProductNeedType || {},
            useImpact ? (data.impactByProductNeedType || {}) : null,
            'productNeedType', FAMILY_COLORS, Object.keys(NEED_TYPE_COLORS)
        );
        this.productIndustryMatrix = this.buildMatrix(
            data.byProductIndustry || {},
            useImpact ? (data.impactByProductIndustry || {}) : null,
            'productIndustry', FAMILY_COLORS, null
        );
        this.industryNeedTypeMatrix = this.buildMatrix(
            data.byIndustryNeedType || {},
            useImpact ? (data.impactByIndustryNeedType || {}) : null,
            'industryNeedType', INDUSTRY_COLORS, Object.keys(NEED_TYPE_COLORS)
        );
        this.processAccounts(
            data.byAccount || {},
            useImpact ? (data.impactByAccount || {}) : null,
            data.accountFreshness || {}
        );
    }

    processProductFamily(countMap, impactMap, freshnessMap) {
        const useImpact = impactMap !== null;
        const valueMap = useImpact ? impactMap : countMap;
        const max = Math.max(...Object.values(valueMap), 1);

        this.productFamilyItems = Object.entries(countMap)
            .sort((a, b) => {
                const va = useImpact ? (impactMap[a[0]] || 0) : a[1];
                const vb = useImpact ? (impactMap[b[0]] || 0) : b[1];
                return vb - va;
            })
            .map(([label, count], idx) => {
                const impact = impactMap ? (impactMap[label] || 0) : 0;
                const displayVal = useImpact ? impact : count;
                const fb = this.getFreshnessBreakdown(label, freshnessMap, count);
                return {
                    key: label,
                    label: label.length > 14 ? label.substring(0, 14) + '…' : label,
                    fullLabel: label,
                    displayValue: useImpact ? this.formatCurrency(impact) : String(count),
                    pct: this.totalCount > 0 ? Math.round((count / this.totalCount) * 100) : 0,
                    barStyle: `width:${Math.max((displayVal / max) * 100, 4)}%`,
                    color: FAMILY_COLORS[idx % FAMILY_COLORS.length],
                    freshStyle: `width:${fb.freshPct}%;background:${FRESHNESS.fresh}`,
                    agingStyle: `width:${fb.agingPct}%;background:${FRESHNESS.aging}`,
                    staleStyle: `width:${fb.stalePct}%;background:${FRESHNESS.stale}`,
                    freshnessTitle: `Fresh:${fb.fresh} Aging:${fb.aging} Stale:${fb.stale}`,
                    showPct: !useImpact
                };
            });
    }

    buildMatrix(countMap, impactMap, filterType, rowColors, fixedCols) {
        const useImpact = impactMap !== null;
        const rowSet = new Set();
        const colSet = new Set();
        const dataMap = {};
        const impactDataMap = {};

        for (const [key, count] of Object.entries(countMap)) {
            const [row, col] = key.split('|');
            rowSet.add(row);
            colSet.add(col);
            dataMap[key] = count;
        }
        if (impactMap) {
            for (const [key, val] of Object.entries(impactMap)) {
                impactDataMap[key] = val;
            }
        }

        const rowList = [...rowSet].sort();
        const colList = fixedCols
            ? fixedCols.filter(c => colSet.has(c)).concat([...colSet].filter(c => !fixedCols.includes(c)).sort())
            : [...colSet].sort();

        // Find max for color intensity
        let maxVal = 1;
        for (const key of Object.keys(dataMap)) {
            const v = useImpact ? (impactDataMap[key] || 0) : dataMap[key];
            if (v > maxVal) maxVal = v;
        }

        const headers = colList.map(col => ({
            key: col,
            label: col.length > 8 ? col.substring(0, 8) + '…' : col,
            fullLabel: col
        }));

        const rows = rowList.map((row, rowIdx) => {
            const cells = colList.map(col => {
                const key = row + '|' + col;
                const count = dataMap[key] || 0;
                const impact = impactDataMap[key] || 0;
                const val = useImpact ? impact : count;
                const displayText = count > 0
                    ? (useImpact ? this.formatCurrencyShort(impact) : String(count))
                    : '';
                const intensity = val > 0 ? Math.min(0.25 + (val / maxVal) * 0.75, 1) : 0;
                const baseColor = rowColors[rowIdx % rowColors.length];
                return {
                    key,
                    count,
                    displayText,
                    hasData: count > 0,
                    cellClass: count > 0 ? 'cross-cell cross-cell--active' : 'cross-cell',
                    cellStyle: count > 0
                        ? `background-color:${baseColor};opacity:${intensity}`
                        : '',
                    filterType
                };
            });
            return {
                key: row,
                rowLabel: row.length > 12 ? row.substring(0, 12) + '…' : row,
                fullRowLabel: row,
                cells
            };
        });

        return { headers, rows };
    }

    processAccounts(countMap, impactMap, freshnessMap) {
        const useImpact = impactMap !== null;
        const entries = Object.entries(countMap)
            .sort((a, b) => {
                const va = useImpact ? (impactMap[a[0]] || 0) : a[1];
                const vb = useImpact ? (impactMap[b[0]] || 0) : b[1];
                return vb - va;
            })
            .slice(0, 10); // Top 10

        const max = entries.length > 0
            ? Math.max(...entries.map(([k]) => useImpact ? (impactMap[k] || 0) : countMap[k]), 1)
            : 1;

        this.accountItems = entries.map(([label, count], idx) => {
            const impact = impactMap ? (impactMap[label] || 0) : 0;
            const displayVal = useImpact ? impact : count;
            const fb = this.getFreshnessBreakdown(label, freshnessMap, count);
            return {
                key: label,
                label: label.length > 14 ? label.substring(0, 14) + '…' : label,
                fullLabel: label,
                displayValue: useImpact ? this.formatCurrency(impact) : String(count),
                pct: this.totalCount > 0 ? Math.round((count / this.totalCount) * 100) : 0,
                barStyle: `width:${Math.max((displayVal / max) * 100, 4)}%`,
                color: INDUSTRY_COLORS[idx % INDUSTRY_COLORS.length],
                freshStyle: `width:${fb.freshPct}%;background:${FRESHNESS.fresh}`,
                agingStyle: `width:${fb.agingPct}%;background:${FRESHNESS.aging}`,
                staleStyle: `width:${fb.stalePct}%;background:${FRESHNESS.stale}`,
                freshnessTitle: `Fresh:${fb.fresh} Aging:${fb.aging} Stale:${fb.stale}`,
                showPct: !useImpact
            };
        });
    }

    getFreshnessBreakdown(key, freshnessMap, total) {
        const f = freshnessMap[key + '|fresh'] || 0;
        const a = freshnessMap[key + '|aging'] || 0;
        const s = freshnessMap[key + '|stale'] || 0;
        if (total === 0) return { freshPct: 0, agingPct: 0, stalePct: 0, fresh: 0, aging: 0, stale: 0 };
        return {
            freshPct: (f / total) * 100,
            agingPct: (a / total) * 100,
            stalePct: (s / total) * 100,
            fresh: f, aging: a, stale: s
        };
    }

    // --- Tab getters ---
    get isProductFamilyChart() { return this.activeChart === 'productFamily'; }
    get isProductNeedTypeChart() { return this.activeChart === 'productNeedType'; }
    get isProductIndustryChart() { return this.activeChart === 'productIndustry'; }
    get isIndustryNeedTypeChart() { return this.activeChart === 'industryNeedType'; }
    get isAccountChart() { return this.activeChart === 'account'; }

    tabClass(name) { return this.activeChart === name ? 'tab-btn tab-btn--active' : 'tab-btn'; }
    get productFamilyTabClass() { return this.tabClass('productFamily'); }
    get productNeedTypeTabClass() { return this.tabClass('productNeedType'); }
    get productIndustryTabClass() { return this.tabClass('productIndustry'); }
    get industryNeedTypeTabClass() { return this.tabClass('industryNeedType'); }
    get accountTabClass() { return this.tabClass('account'); }

    // Show cross hint only on matrix tabs
    get isMatrixTab() {
        return ['productNeedType', 'productIndustry', 'industryNeedType'].includes(this.activeChart);
    }

    // --- Event handlers ---
    handleTabClick(event) {
        this.activeChart = event.currentTarget.dataset.tab;
    }

    handleTimeFilter(event) {
        const val = parseInt(event.currentTarget.dataset.value, 10);
        if (val === this.monthsBack) return; // 同じ値の再クリックは無視
        this.monthsBack = val;
        this.isLoading = true;
    }

    handleSegmentToggle(event) {
        const val = event.currentTarget.dataset.value;
        if (val === this.segment) return; // 同じセグメント再クリックは無視
        this.segment = val;
        this.isLoading = true;
    }

    handleMetricToggle(event) {
        this.metric = event.currentTarget.dataset.metric;
        if (this._rawData) {
            this.processData(this._rawData);
        }
    }

    handleBarClick(event) {
        const filterType = event.currentTarget.dataset.type;
        const filterValue = event.currentTarget.dataset.value;
        this.runAnalysis(filterType, filterValue);
    }

    handleCellClick(event) {
        const key = event.currentTarget.dataset.key;
        const filterType = event.currentTarget.dataset.filtertype;
        if (event.currentTarget.dataset.count === '0') return;
        this.runAnalysis(filterType, key);
    }

    runAnalysis(filterType, filterValue) {
        this.isAnalyzing = true;
        this.hasInsight = false;
        this.insightLines = [];
        this._lastFilterType = filterType;
        this._lastFilterValue = filterValue;

        const typeLabels = {
            productFamily: '製品ファミリー',
            productNeedType: '製品×種別',
            productIndustry: '製品×業種',
            industryNeedType: '業種×種別',
            account: '顧客'
        };
        const displayValue = filterValue.includes('|') ? filterValue.replace('|', ' × ') : filterValue;
        this.insightTitle = (typeLabels[filterType] || '') + '「' + displayValue + '」の分析';

        analyzeSegment({ filterType, filterValue })
            .then(result => {
                this.parseInsight(result);
                this.isAnalyzing = false;
                this.hasInsight = true;
            })
            .catch(err => {
                this.insightLines = [{
                    key: 'err',
                    text: err.body ? err.body.message : err.message,
                    className: 'insight-error'
                }];
                this.isAnalyzing = false;
                this.hasInsight = true;
            });
    }

    parseInsight(text) {
        if (!text) { this.insightLines = []; return; }
        const lines = text.split('\n').filter(l => l.trim().length > 0);
        this.insightLines = lines.map((line, idx) => {
            let className = 'insight-line';
            const trimmed = line.trim();
            if (trimmed.startsWith('##') || trimmed.startsWith('**')) className = 'insight-heading';
            else if (trimmed.startsWith('- ') || trimmed.startsWith('・')) className = 'insight-bullet';
            else if (trimmed.includes('リスク') || trimmed.includes('懸念') || trimmed.includes('警告')) className = 'insight-risk';
            return { key: 'l-' + idx, text: trimmed, className };
        });
    }

    handleCloseInsight() {
        this.hasInsight = false;
        this.isAnalyzing = false;
    }

    // --- Initiative creation from dashboard ---

    handleCreateInitiative() {
        this.isSuggesting = true;
        this.showInitiativeModal = true;
        this.initTitle = '';
        this.initWhat = '';
        this.initWhy = '';
        this.initPriority = '中';
        this.initProductId = '';
        this.initProductOptions = [];
        this.initCardIds = [];

        suggestInitiative({
            filterType: this._lastFilterType,
            filterValue: this._lastFilterValue
        })
            .then(result => {
                this.initTitle = result.suggestedTitle || '';
                this.initWhat = result.suggestedWhat || '';
                this.initWhy = result.suggestedWhy || '';
                this.initProductId = result.defaultProductId || '';
                this.initCardIds = result.cardIds || [];
                this.initCardCount = result.cardCount || 0;
                this.initProductOptions = (result.products || []).map(p => ({
                    label: p.label,
                    value: p.value
                }));
                this.isSuggesting = false;
            })
            .catch(err => {
                this.isSuggesting = false;
                this.initTitle = this._lastFilterValue.replace('|', ' ');
            });
    }

    handleInitTitleChange(e) { this.initTitle = e.target.value; }
    handleInitWhatChange(e) { this.initWhat = e.target.value; }
    handleInitWhyChange(e) { this.initWhy = e.target.value; }
    handleInitPriorityChange(e) { this.initPriority = e.detail.value; }
    handleInitProductChange(e) { this.initProductId = e.detail.value; }

    get priorityOptions() {
        return [
            { label: '高', value: '高' },
            { label: '中', value: '中' },
            { label: '低', value: '低' }
        ];
    }

    get initCardLabel() {
        return `${this.initCardCount}件のニーズカードが自動紐付けされます`;
    }

    handleCloseModal() {
        this.showInitiativeModal = false;
    }

    async handleSaveInitiative() {
        if (!this.initTitle) return;
        this.isCreating = true;
        try {
            const recordId = await createInitiativeFromDashboard({
                title: this.initTitle,
                whatDesc: this.initWhat,
                whyRationale: this.initWhy,
                productId: this.initProductId,
                priority: this.initPriority,
                needsCardIds: this.initCardIds
            });
            this.showInitiativeModal = false;
            this.dispatchEvent(new ShowToastEvent({
                title: '施策を作成しました',
                message: `${this.initCardCount}件のニーズカードを紐付けました`,
                variant: 'success'
            }));
            // Navigate to the new record
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId, actionName: 'view' }
            });
        } catch (err) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'エラー',
                message: err.body?.message || err.message,
                variant: 'error'
            }));
        } finally {
            this.isCreating = false;
        }
    }

    // --- Formatters ---
    formatCurrency(val) {
        if (val >= 100000000) return '¥' + (val / 100000000).toFixed(1) + '億';
        if (val >= 10000) return '¥' + Math.round(val / 10000).toLocaleString() + '万';
        return '¥' + val.toLocaleString();
    }

    formatCurrencyShort(val) {
        if (val >= 100000000) return (val / 100000000).toFixed(1) + '億';
        if (val >= 10000000) return Math.round(val / 10000000) + '千万';
        if (val >= 10000) return Math.round(val / 10000) + '万';
        return String(val);
    }

    get freshnessBarStyle() {
        if (this.totalCount === 0) return '';
        const fp = (this.freshCount / this.totalCount) * 100;
        const ap = (this.agingCount / this.totalCount) * 100;
        return `background:linear-gradient(to right, ${FRESHNESS.fresh} ${fp}%, ${FRESHNESS.aging} ${fp}%, ${FRESHNESS.aging} ${fp + ap}%, ${FRESHNESS.stale} ${fp + ap}%)`;
    }
}
