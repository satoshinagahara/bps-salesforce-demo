import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getAnalysisData from '@salesforce/apex/NeedsAnalysisV3Controller.getAnalysisData';
import getOrAnalyze from '@salesforce/apex/NeedsAnalysisV3Controller.getOrAnalyze';
import createInitiativeFromDashboard from '@salesforce/apex/NeedsAnalysisV3Controller.createInitiativeFromDashboard';

const NEED_TYPE_COLORS = {
    '製品ニーズ': '#3498db',
    'サービスニーズ': '#27ae60',
    '新規案件': '#9b59b6',
    '改善要望': '#f39c12',
    'クレーム': '#e74c3c',
    '未分類': '#95a5a6'
};

const FAMILY_COLORS = ['#2563eb'];
const INDUSTRY_COLORS = ['#2563eb'];

const INDUSTRY_JP = {
    'Utilities': '電力・ガス',
    'Electronics': '電子機器',
    'Trading': '商社',
    'Government': '官公庁・自治体',
    'Chemicals': '化学',
    'Financial Services': '金融',
    'Energy': 'エネルギー'
};
const FRESHNESS = { fresh: '#10b981', aging: '#f59e0b', stale: '#9ca3af' };

export default class NeedsAnalysisDashboardV3 extends NavigationMixin(LightningElement) {
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

    // Drill-down state
    _productToFamily = {};
    _drillFamily = null;

    get isDrilled() { return this._drillFamily !== null; }
    get drillBreadcrumb() { return this._drillFamily; }
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

    // Cache info
    cachedAt = null;
    fromCache = false;

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
    activeChart = 'productIndustry';
    metric = 'count';
    monthsBack = 0;
    segment = 'all';
    _segments = [];
    _defaultSet = false;

    get segmentOptions() {
        const ORDER = ['顧客', 'サプライヤー'];
        const opts = [];
        for (const s of ORDER) {
            if (this._segments.includes(s)) {
                opts.push({
                    label: s,
                    value: s,
                    cls: this.segment === s ? 'seg-btn seg-btn--active-dynamic' : 'seg-btn'
                });
            }
        }
        const others = this._segments.filter(s => !ORDER.includes(s));
        if (others.length > 0) {
            const otherValue = others[0];
            opts.push({
                label: 'その他',
                value: otherValue,
                cls: this.segment === otherValue ? 'seg-btn seg-btn--active-dynamic' : 'seg-btn'
            });
        }
        if (this._segments.length > 1) {
            opts.push({
                label: '全体',
                value: 'all',
                cls: this.segment === 'all' ? 'seg-btn seg-btn--all' : 'seg-btn'
            });
        }
        return opts;
    }

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
        if (data.segments) {
            this._segments = data.segments;
        }
        if (!this._defaultSet && this._segments.length > 1) {
            const defaultSeg = this._segments.includes('顧客') ? '顧客' : this._segments[0];
            if (defaultSeg && this.segment === 'all') {
                this._defaultSet = true;
                this.segment = defaultSeg;
                return;
            }
        }
        this._defaultSet = true;

        this.totalCount = data.totalCount || 0;
        this.highPriorityCount = data.highPriorityCount || 0;
        this.totalImpactFormatted = this.formatCurrency(data.totalImpact || 0);
        this.freshCount = data.freshCount || 0;
        this.agingCount = data.agingCount || 0;
        this.staleCount = data.staleCount || 0;

        this._productToFamily = data.productToFamily || {};

        const useImpact = this.metric === 'impact';

        this.processProductFamily(
            data.byProduct || {},
            useImpact ? (data.impactByProduct || {}) : null,
            data.productFreshness || {}
        );
        this.productNeedTypeMatrix = this._buildProductMatrix(
            data.byProductNeedType || {},
            useImpact ? (data.impactByProductNeedType || {}) : null,
            'productNeedType', FAMILY_COLORS, Object.keys(NEED_TYPE_COLORS)
        );
        this.productIndustryMatrix = this._buildProductMatrix(
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
                    color: `rgba(37,99,235,${Math.max(0.3, 1 - idx * 0.08)})`,
                    freshStyle: `width:${fb.freshPct}%;background:${FRESHNESS.fresh}`,
                    agingStyle: `width:${fb.agingPct}%;background:${FRESHNESS.aging}`,
                    staleStyle: `width:${fb.stalePct}%;background:${FRESHNESS.stale}`,
                    freshnessTitle: `Fresh:${fb.fresh} Aging:${fb.aging} Stale:${fb.stale}`,
                    showPct: !useImpact
                };
            });
    }

    _buildProductMatrix(countMap, impactMap, filterType, rowColors, fixedCols) {
        if (this._drillFamily) {
            const filtered = {};
            const filteredImpact = {};
            for (const [key, val] of Object.entries(countMap)) {
                const productName = key.split('|')[0];
                const family = this._productToFamily[productName];
                if (family === this._drillFamily) {
                    filtered[key] = val;
                    if (impactMap && impactMap[key]) filteredImpact[key] = impactMap[key];
                }
            }
            return this.buildMatrix(filtered, impactMap ? filteredImpact : null, filterType, rowColors, fixedCols);
        }
        const familyCount = {};
        const familyImpact = {};
        for (const [key, val] of Object.entries(countMap)) {
            const [productName, ...rest] = key.split('|');
            const family = this._productToFamily[productName] || productName;
            const newKey = family + '|' + rest.join('|');
            familyCount[newKey] = (familyCount[newKey] || 0) + val;
            if (impactMap && impactMap[key]) {
                familyImpact[newKey] = (familyImpact[newKey] || 0) + impactMap[key];
            }
        }
        const result = this.buildMatrix(familyCount, impactMap ? familyImpact : null, filterType, rowColors, fixedCols);
        result.rows = result.rows.map(row => ({
            ...row,
            isDrillable: true,
            rowLabel: row.rowLabel + ' ▸'
        }));
        return result;
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

        let maxVal = 1;
        for (const key of Object.keys(dataMap)) {
            const v = useImpact ? (impactDataMap[key] || 0) : dataMap[key];
            if (v > maxVal) maxVal = v;
        }

        const headers = colList.map(col => {
            const jp = INDUSTRY_JP[col] || col;
            return { key: col, label: jp, fullLabel: jp };
        });

        const rows = rowList.map((row) => {
            const cells = colList.map(col => {
                const key = row + '|' + col;
                const count = dataMap[key] || 0;
                const impact = impactDataMap[key] || 0;
                const val = useImpact ? impact : count;
                const displayText = count > 0
                    ? (useImpact ? this.formatCurrencyShort(impact) : String(count))
                    : '';
                const ratio = maxVal > 0 && val > 0 ? val / maxVal : 0;
                const alpha = ratio > 0 ? Math.round(15 + ratio * 85) / 100 : 0;
                return {
                    key,
                    count,
                    displayText,
                    hasData: count > 0,
                    cellClass: count > 0 ? 'cross-cell cross-cell--active' : 'cross-cell',
                    cellStyle: count > 0
                        ? `background-color:rgba(37,99,235,${alpha}); color:${alpha > 0.55 ? '#fff' : '#1e293b'}`
                        : '',
                    filterType
                };
            });
            const rowJp = INDUSTRY_JP[row] || row;
            return { key: row, rowLabel: rowJp, fullRowLabel: rowJp, cells };
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
            .slice(0, 10);

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
                color: `rgba(37,99,235,${Math.max(0.3, 1 - idx * 0.08)})`,
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

    get isMatrixTab() {
        return ['productNeedType', 'productIndustry', 'industryNeedType'].includes(this.activeChart);
    }

    // --- Event handlers ---
    handleTabClick(event) {
        this.activeChart = event.currentTarget.dataset.tab;
        this._drillFamily = null;
        if (this._rawData) this.processData(this._rawData);
    }

    handleRowLabelClick(event) {
        const rowKey = event.currentTarget.dataset.family;
        if (!rowKey || this._drillFamily) return;
        this._drillFamily = rowKey;
        if (this._rawData) this.processData(this._rawData);
    }

    handleDrillBack() {
        this._drillFamily = null;
        if (this._rawData) this.processData(this._rawData);
    }

    handleTimeFilter(event) {
        const val = parseInt(event.currentTarget.dataset.value, 10);
        if (val === this.monthsBack) return;
        this.monthsBack = val;
        this.isLoading = true;
    }

    handleSegmentToggle(event) {
        const val = event.currentTarget.dataset.value;
        if (val === this.segment) return;
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
        const count = event.currentTarget.dataset.count || '';
        this.runAnalysis(filterType, filterValue, count, false);
    }

    handleCellClick(event) {
        const key = event.currentTarget.dataset.key;
        const filterType = event.currentTarget.dataset.filtertype;
        const count = event.currentTarget.dataset.count || '0';
        if (count === '0') return;
        this.runAnalysis(filterType, key, count, false);
    }

    // V3: リロードボタン — キャッシュを無視して再取得
    handleRefreshAnalysis() {
        if (!this._lastFilterType || !this._lastFilterValue) return;
        this.runAnalysis(this._lastFilterType, this._lastFilterValue, this._lastCardCount || '?', true);
    }

    // 分析中サマリ
    analysisSummary = null;

    // 分析フェーズ管理
    analysisPhase = 0; // 0=idle, 1=analyzing, 3=done

    get isPhaseAnalyzing() { return this.analysisPhase === 1; }
    get isPhaseComplete() { return this.analysisPhase === 3; }
    get initiativeReady() { return this.isPhaseComplete && !!this.initTitle; }

    // V3: cachedAt の表示用フォーマット
    get cachedAtFormatted() {
        if (!this.cachedAt) return '';
        try {
            const d = new Date(this.cachedAt);
            const mm = String(d.getMonth() + 1).padStart(2, '0');
            const dd = String(d.getDate()).padStart(2, '0');
            const hh = String(d.getHours()).padStart(2, '0');
            const mi = String(d.getMinutes()).padStart(2, '0');
            return `${mm}/${dd} ${hh}:${mi}`;
        } catch {
            return '';
        }
    }

    // V3: 統合された分析実行
    runAnalysis(filterType, filterValue, cardCount, forceRefresh) {
        this.isAnalyzing = true;
        this.analysisPhase = 1;
        this.hasInsight = false;
        this.insightLines = [];
        this._lastFilterType = filterType;
        this._lastFilterValue = filterValue;
        this._lastCardCount = cardCount;
        this.fromCache = false;
        this.cachedAt = null;

        // 施策ドラフトをリセット
        this.initTitle = '';
        this.initWhat = '';
        this.initWhy = '';

        const displayValue = filterValue.includes('|') ? filterValue.replace('|', ' × ') : filterValue;
        this.analysisSummary = {
            target: displayValue,
            cardCount: cardCount || '?'
        };

        const typeLabels = {
            productFamily: '製品',
            productNeedType: '製品×種別',
            productIndustry: '製品×業種',
            industryNeedType: '業種×種別',
            account: '顧客'
        };
        this.insightTitle = (typeLabels[filterType] || '') + '「' + displayValue + '」の分析';

        getOrAnalyze({ filterType, filterValue, forceRefresh: forceRefresh === true })
            .then(result => {
                // 分析テキスト
                this.parseInsight(result.analysisText || '');
                this.isAnalyzing = false;
                this.hasInsight = true;

                // 施策ドラフト
                this.initTitle = result.suggestedTitle || '';
                this.initWhat = result.suggestedWhat || '';
                this.initWhy = result.suggestedWhy || '';
                this.initProductId = result.defaultProductId || '';
                this.initCardIds = result.cardIds || [];
                this.initCardCount = result.cardCount || 0;
                this.initProductOptions = (result.products || []).map(p => ({
                    label: p.label, value: p.value
                }));

                // キャッシュ情報
                this.fromCache = result.fromCache === true;
                this.cachedAt = result.cachedAt || null;

                this.analysisPhase = 3;
            })
            .catch(err => {
                this.insightLines = [{
                    key: 'err',
                    text: err.body ? err.body.message : err.message,
                    className: 'insight-error'
                }];
                this.isAnalyzing = false;
                this.hasInsight = true;
                this.analysisPhase = 0;
            });
    }

    parseInsight(text) {
        if (!text) { this.insightLines = []; return; }
        const lines = text.split('\n').filter(l => l.trim().length > 0);
        const riskPattern = /リスク|懸念|警告/;
        let inRiskSection = false;
        this.insightLines = lines.map((line, idx) => {
            const trimmed = line.trim();
            let className = 'insight-line';
            let displayText = trimmed;
            if (trimmed.startsWith('##') || trimmed.startsWith('**')) {
                className = 'insight-heading';
                inRiskSection = riskPattern.test(trimmed);
                displayText = trimmed.replace(/^#{1,6}\s*/, '').replace(/^\*\*|\*\*$/g, '');
            } else if (trimmed.startsWith('- ') || trimmed.startsWith('・')) {
                className = inRiskSection ? 'insight-risk' : 'insight-bullet';
            } else if (riskPattern.test(trimmed)) {
                className = 'insight-risk';
            }
            return { key: 'l-' + idx, text: displayText, className };
        });
    }

    handleCloseInsight() {
        this.hasInsight = false;
        this.isAnalyzing = false;
    }

    // --- Initiative creation from dashboard ---

    handleCreateInitiative() {
        this.isSuggesting = false;
        this.showInitiativeModal = true;
        this.initPriority = '中';
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
