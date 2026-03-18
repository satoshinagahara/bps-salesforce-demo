import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getSupplierDemand from '@salesforce/apex/SupplierDemandController.getSupplierDemand';

export default class SupplierDemandOutlook extends NavigationMixin(LightningElement) {
    @api recordId;
    rawData;
    error;
    activeTab = 'confirmed';

    @wire(getSupplierDemand, { accountId: '$recordId' })
    wiredData({ data, error }) {
        if (data) {
            this.rawData = data;
            this.error = undefined;
        } else if (error) {
            this.error = error.body?.message || 'Error';
        }
    }

    get hasData() {
        return this.rawData && this.rawData.totalParts > 0;
    }

    // ── Summary ──
    get totalPartsFmt() { return this.rawData ? `${this.rawData.totalParts}品目` : '0品目'; }
    get totalProductsFmt() { return this.rawData ? `${this.rawData.totalProducts}製品` : '0製品'; }
    get confirmedPartQtyFmt() { return this.fmtNum(this.rawData?.totalConfirmedPartQty); }
    get confirmedCustomersFmt() { return this.rawData ? `${this.rawData.totalCustomers}社` : '0社'; }
    get pipelinePartQtyFmt() {
        if (!this.rawData?.pipeline) return '0';
        let total = 0;
        for (const ppd of this.rawData.pipeline) {
            for (const po of (ppd.opportunities || [])) {
                total += po.totalPartDemandQty || 0;
            }
        }
        return this.fmtNum(total);
    }
    get pipelineOppsFmt() { return this.rawData ? `${this.rawData.totalPipelineOpps}件` : '0件'; }

    // ── Tabs ──
    get isConfirmedTab() { return this.activeTab === 'confirmed'; }
    get isPipelineTab() { return this.activeTab === 'pipeline'; }
    get confirmedTabClass() { return this.activeTab === 'confirmed' ? 'tab active' : 'tab'; }
    get pipelineTabClass() { return this.activeTab === 'pipeline' ? 'tab active' : 'tab'; }

    get hasConfirmed() { return this.rawData?.confirmed?.length > 0; }
    get hasPipeline() { return this.rawData?.pipeline?.length > 0; }

    get capacityAlertCount() {
        if (!this.rawData?.parts) return 0;
        return this.rawData.parts.filter(p => p.utilizationPct && p.utilizationPct > 80).length;
    }
    get hasCapacityAlerts() { return this.capacityAlertCount > 0; }

    // ── Confirmed data ──
    get confirmedProducts() {
        if (!this.rawData?.confirmed) return [];
        return this.rawData.confirmed.map(cpd => ({
            key: cpd.productId,
            productName: cpd.productName,
            partsLabel: (cpd.parts || []).map(p => {
                const partInfo = (this.rawData?.parts || []).find(sp => sp.partNumber === p.partNumber);
                const capStr = partInfo?.utilizationPct ? ` [${partInfo.utilizationPct}%]` : '';
                return `${p.partName}(×${p.qtyPerUnit})${capStr}`;
            }).join('、'),
            totalPlanQtyFmt: this.fmtNum(cpd.totalPlanQty),
            totalPartDemandFmt: this.fmtNum(cpd.totalPartDemandQty),
            customers: (cpd.customers || []).map(cd => ({
                key: cd.agreementId,
                customerName: cd.customerName,
                customerId: cd.customerId,
                agreementId: cd.agreementId,
                agreementName: cd.agreementName,
                status: cd.status,
                statusClass: `status-badge status-${cd.status === '有効' ? 'active' : 'other'}`,
                totalPlanQtyFmt: this.fmtNum(cd.totalPlanQty),
                totalActualQtyFmt: this.fmtNum(cd.totalActualQty),
                totalPartDemandFmt: this.fmtNum(cd.totalPartDemandQty),
                achievementPct: cd.totalPlanQty > 0
                    ? `${(cd.totalActualQty / cd.totalPlanQty * 100).toFixed(1)}%` : '-'
            }))
        }));
    }

    // ── Pipeline data ──
    get pipelineProducts() {
        if (!this.rawData?.pipeline) return [];
        return this.rawData.pipeline.map(ppd => {
            let prodPartDemand = 0;
            for (const po of (ppd.opportunities || [])) {
                prodPartDemand += po.totalPartDemandQty || 0;
            }
            return {
                key: ppd.productId,
                productName: ppd.productName,
                partsLabel: (ppd.parts || []).map(p => `${p.partName}(×${p.qtyPerUnit})`).join('、'),
                totalPartDemandFmt: this.fmtNum(prodPartDemand),
                opportunities: (ppd.opportunities || []).map(po => ({
                    key: po.oppId,
                    oppId: po.oppId,
                    oppName: po.oppName,
                    customerId: po.customerId,
                    customerName: po.customerName,
                    stageName: this.stageLabel(po.stageName),
                    probFmt: `${po.probability}%`,
                    totalForecastQtyFmt: this.fmtNum(po.totalForecastQty),
                    totalPartDemandFmt: this.fmtNum(po.totalPartDemandQty),
                    periodSummary: (po.forecasts || []).map(f =>
                        `${f.fiscalYear} ${f.quarter || ''}: ${this.fmtNum(f.forecastQty)}`
                    ).join(' / ')
                }))
            };
        });
    }

    handleTab(e) { this.activeTab = e.currentTarget.dataset.tab; }

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
            'DW_Qualification': '品質認定', 'DW_FinalNegotiation': '最終交渉'
        };
        return map[stage] || stage;
    }

    fmtNum(v) { return v != null ? Number(v).toLocaleString('ja-JP') : '0'; }
}
