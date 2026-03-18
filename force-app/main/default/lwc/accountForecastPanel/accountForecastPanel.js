import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getForecastData from '@salesforce/apex/AccountForecastController.getForecastData';

export default class AccountForecastPanel extends NavigationMixin(LightningElement) {
    @api recordId;
    rawData;
    error;
    activeTab = 'agreements';
    selectedYear = 'ALL';

    get yearOptions() {
        const now = new Date();
        // Japanese FY: April-March. Month is 0-indexed in JS
        const currentFY = now.getMonth() >= 3 ? now.getFullYear() : now.getFullYear() - 1;
        const opts = [{ label: '全期間', value: 'ALL' }];
        for (let i = 0; i < 5; i++) {
            const fy = `FY${currentFY + i}`;
            opts.push({ label: fy, value: fy });
        }
        return opts;
    }

    @wire(getForecastData, { accountId: '$recordId' })
    wiredData({ data, error }) {
        if (data) {
            this.rawData = data;
            this.error = undefined;
        } else if (error) {
            this.error = error.body?.message || 'Error';
        }
    }

    // ── Filtered & formatted data ──
    get data() {
        if (!this.rawData) return null;
        const fy = this.selectedYear;
        const isAll = fy === 'ALL';

        // --- Agreements ---
        let filteredAgreements = [];
        let sumPlan = 0, sumActual = 0;
        for (const a of (this.rawData.agreements || [])) {
            let agPlan, agActual;
            let products;
            if (isAll) {
                agPlan = a.totalPlanAmt || 0;
                agActual = a.totalActualAmt || 0;
                products = (a.products || []).map(p => ({
                    ...p,
                    key: a.id + p.productName,
                    dPlanQty: p.totalPlanQty, dActualQty: p.totalActualQty,
                    dPlanAmt: p.totalPlanAmt, dActualAmt: p.totalActualAmt
                }));
            } else {
                const fyData = (a.fyAmounts || []).find(f => f.fiscalYear === fy);
                if (!fyData) continue;
                agPlan = fyData.planAmt || 0;
                agActual = fyData.actualAmt || 0;
                products = (a.products || []).map(p => {
                    const pfy = (p.fyAmounts || []).find(f => f.fiscalYear === fy);
                    if (!pfy) return null;
                    return {
                        ...p, key: a.id + p.productName,
                        dPlanQty: pfy.planQty, dActualQty: pfy.actualQty,
                        dPlanAmt: pfy.planAmt, dActualAmt: pfy.actualAmt
                    };
                }).filter(Boolean);
            }
            const achvRate = agPlan > 0 ? (agActual / agPlan * 100) : 0;
            filteredAgreements.push({
                ...a,
                contractPeriod: `${a.contractStart || ''} 〜 ${a.contractEnd || ''}`,
                totalPlanAmtFmt: this.fmtCur(agPlan),
                totalActualAmtFmt: this.fmtCur(agActual),
                achievementClass: this.achvClass(achvRate),
                achievementFmt: `${achvRate.toFixed(1)}%`,
                statusClass: `status-badge status-${a.status === '有効' ? 'active' : 'negotiating'}`,
                products: products.map(p => ({
                    ...p,
                    totalPlanQtyFmt: this.fmtNum(p.dPlanQty),
                    totalActualQtyFmt: this.fmtNum(p.dActualQty),
                    totalPlanAmtFmt: this.fmtCur(p.dPlanAmt),
                    achievementFmt: `${(p.dPlanAmt > 0 ? (p.dActualAmt / p.dPlanAmt * 100) : 0).toFixed(1)}%`,
                    achievementClass: this.achvClass(p.dPlanAmt > 0 ? (p.dActualAmt / p.dPlanAmt * 100) : 0)
                }))
            });
            sumPlan += agPlan;
            sumActual += agActual;
        }

        // --- DW Pipeline ---
        let filteredPipeline = [];
        let sumWeighted = 0;
        for (const p of (this.rawData.pipeline || [])) {
            const forecasts = isAll
                ? p.forecasts
                : (p.forecasts || []).filter(f => f.fiscalYear === fy);
            if (forecasts.length === 0) continue;
            const oppWeighted = forecasts.reduce((s, f) => s + (f.weightedAmount || 0), 0);
            filteredPipeline.push({
                ...p,
                probFmt: `${p.probability}%`,
                totalWeightedFmt: this.fmtCur(oppWeighted),
                stageLabel: this.stageLabel(p.stageName),
                stageClass: `stage-badge stage-${p.stageName}`,
                forecasts: forecasts.map(f => ({
                    ...f,
                    key: p.oppId + f.fiscalYear + (f.quarter || '') + f.productName,
                    periodLabel: f.fiscalYear + (f.quarter ? ' ' + f.quarter : ''),
                    quantityFmt: this.fmtNum(f.quantity),
                    amountFmt: this.fmtCur(f.amount),
                    weightedFmt: this.fmtCur(f.weightedAmount)
                }))
            });
            sumWeighted += oppWeighted;
        }

        // --- Standard Pipeline ---
        const stdOpps = isAll
            ? (this.rawData.standardPipeline || [])
            : (this.rawData.standardPipeline || []).filter(o => o.fiscalYear === fy);
        let sumStdAmt = 0, sumStdWeighted = 0;
        const sgMap = {};
        const formattedStd = stdOpps.map(o => {
            const amt = o.amount || 0;
            const exp = o.expectedRevenue || 0;
            sumStdAmt += amt;
            sumStdWeighted += exp;
            const stage = o.stageName;
            if (!sgMap[stage]) sgMap[stage] = { stageName: stage, count: 0, totalAmount: 0, totalWeighted: 0 };
            sgMap[stage].count++;
            sgMap[stage].totalAmount += amt;
            sgMap[stage].totalWeighted += exp;
            return {
                ...o, key: o.oppId,
                amountFmt: this.fmtCur(o.amount),
                expectedRevenueFmt: this.fmtCur(o.expectedRevenue),
                probFmt: o.probability != null ? `${o.probability}%` : '-',
                closeDateFmt: o.closeDate || '-'
            };
        });
        const stageGroups = Object.values(sgMap).map((sg, i) => ({
            ...sg, key: 'sg' + i,
            totalAmountFmt: this.fmtCur(sg.totalAmount),
            totalWeightedFmt: this.fmtCur(sg.totalWeighted),
            barStyle: `width: ${sumStdAmt > 0 ? Math.max(4, Math.round(sg.totalAmount / sumStdAmt * 100)) : 0}%`
        }));

        return {
            totalPlanAmtFmt: this.fmtCur(sumPlan),
            totalActualAmtFmt: this.fmtCur(sumActual),
            totalWeightedFmt: this.fmtCur(sumWeighted),
            totalStdAmountFmt: this.fmtCur(sumStdAmt),
            totalStdWeightedFmt: this.fmtCur(sumStdWeighted),
            agreements: filteredAgreements,
            pipeline: filteredPipeline,
            standardPipeline: formattedStd,
            stageGroups
        };
    }

    get hasAgreements() { return this.data?.agreements?.length > 0; }
    get hasPipeline() { return this.data?.pipeline?.length > 0; }
    get hasStandardPipeline() { return this.data?.standardPipeline?.length > 0; }
    get hasStageGroups() { return this.data?.stageGroups?.length > 0; }
    get isAgreementsTab() { return this.activeTab === 'agreements'; }
    get isPipelineTab() { return this.activeTab === 'pipeline'; }
    get isStandardTab() { return this.activeTab === 'standard'; }
    get agreementsTabClass() { return this.activeTab === 'agreements' ? 'tab active' : 'tab'; }
    get pipelineTabClass() { return this.activeTab === 'pipeline' ? 'tab active' : 'tab'; }
    get standardTabClass() { return this.activeTab === 'standard' ? 'tab active' : 'tab'; }

    handleTab(e) { this.activeTab = e.currentTarget.dataset.tab; }
    handleYearChange(e) { this.selectedYear = e.detail.value; }

    handleNavigate(e) {
        e.preventDefault();
        const recId = e.currentTarget.dataset.id;
        if (recId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: { recordId: recId, actionName: 'view' }
            });
        }
    }

    stageLabel(stage) {
        const map = {
            'DW_Inquiry': '引合い', 'DW_Proposal': '提案', 'DW_Prototype': '試作・評価',
            'DW_Qualification': '品質認定', 'DW_FinalNegotiation': '最終交渉',
            'Design_Win': 'Design Win', 'DW_Lost': '失注'
        };
        return map[stage] || stage;
    }
    achvClass(rate) {
        if (rate >= 100) return 'achv-badge achv-good';
        if (rate >= 90) return 'achv-badge achv-warn';
        return 'achv-badge achv-bad';
    }
    fmtNum(v) { return v != null ? Number(v).toLocaleString('ja-JP') : '0'; }
    fmtCur(v) { return v != null ? '¥' + Number(v).toLocaleString('ja-JP') : '¥0'; }
}
