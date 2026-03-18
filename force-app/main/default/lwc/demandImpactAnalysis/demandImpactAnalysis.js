import { LightningElement, api, wire } from 'lwc';
import getImpactData from '@salesforce/apex/DemandImpactController.getImpactData';
import simulateWhatIf from '@salesforce/apex/DemandImpactController.simulateWhatIf';

export default class DemandImpactAnalysis extends LightningElement {
    @api recordId;
    data;
    error;
    activeTab = 'actual';

    // What-If state
    scenarioInputs = [];
    whatIfResult = null;
    whatIfLoading = false;
    whatIfError = '';

    @wire(getImpactData, { agreementId: '$recordId' })
    wiredData({ data, error }) {
        if (data) {
            this.data = {
                products: (data.products || []).map(p => ({
                    ...p,
                    key: p.productId,
                    totalVarianceQtyFmt: this.fmtSigned(p.totalVarianceQty),
                    totalVariancePctFmt: `${p.totalVariancePct > 0 ? '+' : ''}${p.totalVariancePct}%`,
                    varianceClass: p.totalVariancePct > 0 ? 'var-over' : p.totalVariancePct < -10 ? 'var-critical' : 'var-under',
                    hasMonths: p.months && p.months.length > 0,
                    hasSuppliers: p.suppliers && p.suppliers.length > 0,
                    months: (p.months || []).map(m => ({
                        ...m,
                        key: m.month,
                        monthLabel: this.fmtMonth(m.month),
                        planFmt: this.fmtNum(m.planQty),
                        actualFmt: this.fmtNum(m.actualQty),
                        varianceFmt: this.fmtSigned(m.varianceQty),
                        variancePctFmt: `${m.variancePct > 0 ? '+' : ''}${m.variancePct}%`,
                        rowClass: m.variancePct < -10 ? 'row-critical' : m.variancePct < 0 ? 'row-under' : 'row-over'
                    })),
                    suppliers: this.formatSuppliers(p.suppliers)
                }))
            };
            this.scenarioInputs = (data.products || []).map(p => ({
                productId: p.productId,
                productName: p.productName,
                changePct: 0,
                key: p.productId
            }));
            this.error = undefined;
        } else if (error) {
            this.error = error.body?.message || 'Error';
        }
    }

    formatSuppliers(suppliers) {
        return (suppliers || []).map(s => ({
            ...s,
            key: s.supplierId,
            totalImpactFmt: this.fmtSigned(s.totalImpactQty),
            impactClass: s.totalImpactQty < 0 ? 'impact-decrease' : 'impact-increase',
            hasCapacities: s.capacities && s.capacities.length > 0,
            capacities: (s.capacities || []).map(c => ({
                ...c,
                key: s.supplierId + c.partNumber + c.siteId,
                capacityFmt: this.fmtNum(c.monthlyCapacity),
                demandFmt: this.fmtNum(Math.max(c.totalDemandQty || 0, c.simulatedDemandQty || 0)),
                utilizationFmt: (c.utilizationPct || 0) + '%',
                utilizationClass: c.utilizationPct > 100 ? 'util-over' : c.utilizationPct > 80 ? 'util-warning' : 'util-ok',
                barWidth: 'width:' + Math.min(c.utilizationPct || 0, 100) + '%',
                barClass: 'util-bar-fill' + (c.utilizationPct > 100 ? ' over' : c.utilizationPct > 80 ? ' warning' : ''),
                isOverCapacity: c.utilizationPct > 100,
                hasAlternatives: c.alternatives && c.alternatives.length > 0,
                alternatives: (c.alternatives || []).map(a => ({
                    ...a,
                    key: a.siteId,
                    spareCapacityFmt: this.fmtNum(a.spareCapacity)
                }))
            })),
            parts: (s.parts || []).map(pt => ({
                ...pt,
                key: s.supplierId + pt.partNumber,
                qtyPerUnitFmt: this.fmtNum(pt.qtyPerUnit),
                impactFmt: this.fmtSigned(pt.impactQty)
            }))
        }));
    }

    // Tab getters
    get isActualTab() { return this.activeTab === 'actual'; }
    get isWhatIfTab() { return this.activeTab === 'whatif'; }
    get actualTabClass() { return this.activeTab === 'actual' ? 'tab active' : 'tab'; }
    get whatifTabClass() { return this.activeTab === 'whatif' ? 'tab active' : 'tab'; }

    get hasData() { return this.data?.products?.length > 0; }
    get hasScenarioInputs() { return this.scenarioInputs.length > 0; }
    get hasWhatIfResult() { return this.whatIfResult != null; }
    get hasWhatIfProducts() { return this.whatIfResult?.products?.length > 0; }
    get simulateDisabled() { return this.whatIfLoading || !this.hasAnyChange; }
    get hasAnyChange() { return this.scenarioInputs.some(s => s.changePct !== 0); }

    get whatIfProducts() {
        if (!this.whatIfResult) return [];
        return this.whatIfResult.products.map(p => ({
            ...p,
            key: p.productId,
            changePctFmt: `${p.changePct > 0 ? '+' : ''}${p.changePct}%`,
            changeClass: p.changePct > 0 ? 'change-up' : 'change-down',
            totalPlanFmt: this.fmtNum(p.totalPlanQty),
            totalSimFmt: this.fmtNum(p.totalSimulatedQty),
            totalDeltaFmt: this.fmtSigned(p.totalDeltaQty),
            hasMonths: p.months && p.months.length > 0,
            hasSuppliers: p.suppliers && p.suppliers.length > 0,
            months: (p.months || []).map(m => ({
                ...m,
                key: String(m.month),
                monthLabel: this.fmtMonth(m.month),
                planFmt: this.fmtNum(m.planQty),
                actualFmt: m.actualQty != null ? this.fmtNum(m.actualQty) : '-',
                simFmt: this.fmtNum(m.simulatedQty),
                deltaFmt: this.fmtSigned(m.simulatedQty - m.planQty)
            })),
            suppliers: this.formatSuppliers(p.suppliers)
        }));
    }

    handleTab(e) { this.activeTab = e.currentTarget.dataset.tab; }

    handleChangePct(e) {
        const productId = e.target.dataset.productId;
        const val = parseFloat(e.target.value) || 0;
        this.scenarioInputs = this.scenarioInputs.map(s =>
            s.productId === productId ? { ...s, changePct: val } : s
        );
    }

    handlePreset(e) {
        const pct = parseInt(e.currentTarget.dataset.pct, 10);
        this.scenarioInputs = this.scenarioInputs.map(s => ({ ...s, changePct: pct }));
    }

    handleReset() {
        this.scenarioInputs = this.scenarioInputs.map(s => ({ ...s, changePct: 0 }));
        this.whatIfResult = null;
        this.whatIfError = '';
    }

    async handleSimulate() {
        this.whatIfLoading = true;
        this.whatIfError = '';
        this.whatIfResult = null;
        try {
            const scenarioJson = JSON.stringify(
                this.scenarioInputs.filter(s => s.changePct !== 0).map(s => ({
                    productId: s.productId,
                    changePct: s.changePct
                }))
            );
            this.whatIfResult = await simulateWhatIf({
                agreementId: this.recordId,
                scenarioJson
            });
        } catch (err) {
            this.whatIfError = err.body?.message || err.message || 'シミュレーションに失敗しました';
        } finally {
            this.whatIfLoading = false;
        }
    }

    fmtMonth(m) {
        return new Date(m + 'T00:00:00').toLocaleDateString('ja-JP', { year: 'numeric', month: 'short' });
    }
    fmtNum(v) { return v != null ? Number(v).toLocaleString('ja-JP') : '0'; }
    fmtSigned(v) {
        if (v == null) return '0';
        const n = Number(v);
        return (n > 0 ? '+' : '') + n.toLocaleString('ja-JP');
    }
}
