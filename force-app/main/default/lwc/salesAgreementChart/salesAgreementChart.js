import { LightningElement, api, wire } from 'lwc';
import getScheduleData from '@salesforce/apex/SalesAgreementChartController.getScheduleData';

export default class SalesAgreementChart extends LightningElement {
    @api recordId;
    products = [];
    error;
    selectedProductIndex = 0;

    @wire(getScheduleData, { agreementId: '$recordId' })
    wiredData({ data, error }) {
        if (data) {
            this.products = data.map((p, idx) => {
                const maxQty = p.maxQty || 1;
                const schedules = p.schedules.map(s => {
                    const monthStr = new Date(s.month + 'T00:00:00').toLocaleDateString('ja-JP', { month: 'short' });
                    const planPct = (s.planQty / maxQty) * 100;
                    const actualPct = (s.actualQty / maxQty) * 100;
                    let variancePct = 0;
                    let varianceClass = 'variance-neutral';
                    if (s.hasActual && s.planQty > 0) {
                        variancePct = ((s.actualQty - s.planQty) / s.planQty * 100).toFixed(0);
                        varianceClass = variancePct > 0 ? 'variance-over' : variancePct < -10 ? 'variance-critical' : 'variance-under';
                    }
                    return {
                        key: s.month,
                        monthLabel: monthStr,
                        planQty: s.planQty,
                        actualQty: s.actualQty,
                        planStyle: `height:${planPct}%`,
                        actualStyle: `height:${actualPct}%`,
                        hasActual: s.hasActual,
                        variancePct: s.hasActual ? `${variancePct > 0 ? '+' : ''}${variancePct}%` : '',
                        varianceClass,
                        planAmtFormatted: this.formatCurrency(s.planAmt),
                        actualAmtFormatted: s.hasActual ? this.formatCurrency(s.actualAmt) : '-'
                    };
                });
                return {
                    ...p,
                    index: idx,
                    tabClass: idx === 0 ? 'tab active' : 'tab',
                    isSelected: idx === 0,
                    schedules,
                    achievementFormatted: `${p.achievementRate}%`,
                    achievementClass: p.achievementRate >= 100 ? 'badge-success' : p.achievementRate >= 90 ? 'badge-warning' : 'badge-danger',
                    totalPlanFormatted: this.formatNumber(p.totalPlanQty),
                    totalActualFormatted: this.formatNumber(p.totalActualQty)
                };
            });
            this.error = undefined;
        } else if (error) {
            this.error = error.body?.message || 'Error loading data';
        }
    }

    get hasData() { return this.products.length > 0; }
    get hasMultipleProducts() { return this.products.length > 1; }
    get selectedProduct() { return this.products[this.selectedProductIndex]; }

    handleTabClick(event) {
        const idx = parseInt(event.currentTarget.dataset.index, 10);
        this.selectedProductIndex = idx;
        this.products = this.products.map((p, i) => ({
            ...p,
            tabClass: i === idx ? 'tab active' : 'tab',
            isSelected: i === idx
        }));
    }

    formatNumber(val) {
        return val != null ? Number(val).toLocaleString('ja-JP') : '0';
    }
    formatCurrency(val) {
        return val != null ? '¥' + Number(val).toLocaleString('ja-JP') : '¥0';
    }
}
