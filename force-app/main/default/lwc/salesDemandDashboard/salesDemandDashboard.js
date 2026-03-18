import { LightningElement, wire } from 'lwc';
import getDashboardData from '@salesforce/apex/SalesDemandDashboardController.getDashboardData';

export default class SalesDemandDashboard extends LightningElement {
    data;
    error;
    activeTab = 'revenue';

    @wire(getDashboardData)
    wiredData({ data, error }) {
        if (data) {
            this.data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error.body?.message || 'データ取得エラー';
        }
    }

    get hasData() { return !!this.data; }

    // ── Summary ──
    get confirmedFmt() { return this.fmtCur(this.data?.confirmedRevenue); }
    get dwPipelineFmt() { return this.fmtCur(this.data?.dwPipelineWeighted); }
    get stdPipelineFmt() { return this.fmtCur(this.data?.stdPipelineWeighted); }
    get closeThisMonthFmt() { return this.fmtCur(this.data?.closeThisMonth); }

    // ── Tabs ──
    get isRevenueTab() { return this.activeTab === 'revenue'; }
    get isStageTab() { return this.activeTab === 'stage'; }
    get isProductTab() { return this.activeTab === 'product'; }
    get revenueTabClass() { return this.activeTab === 'revenue' ? 'tab active' : 'tab'; }
    get stageTabClass() { return this.activeTab === 'stage' ? 'tab active' : 'tab'; }
    get productTabClass() { return this.activeTab === 'product' ? 'tab active' : 'tab'; }

    handleTab(e) { this.activeTab = e.currentTarget.dataset.tab; }

    // ── Tab 1: FY Revenue Chart ──
    get fyChartData() {
        if (!this.data?.fyRevenues) return [];
        const maxTotal = Math.max(...this.data.fyRevenues.map(f => f.totalAmount || 0), 1);
        return this.data.fyRevenues.map(f => ({
            key: f.fiscalYear,
            fiscalYear: f.fiscalYear,
            confirmed: f.confirmedAmount || 0,
            dw: f.dwWeightedAmount || 0,
            std: f.stdWeightedAmount || 0,
            total: f.totalAmount || 0,
            totalFmt: this.fmtCur(f.totalAmount),
            confirmedWidth: `width: ${((f.confirmedAmount || 0) / maxTotal * 100)}%`,
            dwWidth: `width: ${((f.dwWeightedAmount || 0) / maxTotal * 100)}%`,
            stdWidth: `width: ${((f.stdWeightedAmount || 0) / maxTotal * 100)}%`,
            hasBar: (f.totalAmount || 0) > 0
        }));
    }

    // ── Tab 2: Pipeline Stages ──
    get dwStageItems() {
        if (!this.data?.dwStages) return [];
        const max = Math.max(...this.data.dwStages.map(s => s.totalWeighted || 0), 1);
        return this.data.dwStages.map(s => ({
            key: s.stageName,
            label: s.stageLabel,
            count: s.count,
            amountFmt: this.fmtCur(s.totalWeighted),
            barWidth: `width: ${((s.totalWeighted || 0) / max * 100)}%`
        }));
    }
    get hasDWStages() { return this.dwStageItems.length > 0; }

    get stdStageItems() {
        if (!this.data?.stdStages) return [];
        const max = Math.max(...this.data.stdStages.map(s => s.totalWeighted || 0), 1);
        return this.data.stdStages.map(s => ({
            key: s.stageName,
            label: s.stageLabel,
            count: s.count,
            amountFmt: this.fmtCur(s.totalWeighted),
            barWidth: `width: ${((s.totalWeighted || 0) / max * 100)}%`
        }));
    }
    get hasStdStages() { return this.stdStageItems.length > 0; }

    // ── Tab 3: Product Demand ──
    get productItems() {
        if (!this.data?.productDemands) return [];
        return this.data.productDemands
            .map(p => ({
                key: p.productName,
                productName: p.productName,
                productFamily: p.productFamily || '-',
                saQtyFmt: this.fmtNum(p.saQuantity),
                dwQtyFmt: this.fmtNum(p.dwQuantity),
                totalQty: (p.saQuantity || 0) + (p.dwQuantity || 0),
                totalQtyFmt: this.fmtNum((p.saQuantity || 0) + (p.dwQuantity || 0)),
                hasSA: (p.saQuantity || 0) > 0,
                hasDW: (p.dwQuantity || 0) > 0
            }))
            .sort((a, b) => b.totalQty - a.totalQty);
    }
    get hasProducts() { return this.productItems.length > 0; }

    // ── Helpers ──
    fmtCur(v) { return v != null ? '¥' + Number(v).toLocaleString('ja-JP') : '¥0'; }
    fmtNum(v) { return v != null ? Number(v).toLocaleString('ja-JP') : '0'; }
}
