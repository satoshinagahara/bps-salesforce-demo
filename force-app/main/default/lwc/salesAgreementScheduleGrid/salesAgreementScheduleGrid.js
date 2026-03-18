import { LightningElement, api, wire } from 'lwc';
import getScheduleData from '@salesforce/apex/SalesAgreementScheduleController.getScheduleData';
import saveSchedules from '@salesforce/apex/SalesAgreementScheduleController.saveSchedules';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class SalesAgreementScheduleGrid extends LightningElement {
    @api recordId;
    agreement = {};
    products = [];    // [{productName, unitPrice, months: [{id, label, planQty, planAmt, actualQty, actualAmt}]}]
    forecasts = [];   // reference forecasts
    isDirty = false;
    isSaving = false;
    showForecasts = false;
    _wiredResult;

    @wire(getScheduleData, { agreementId: '$recordId' })
    wiredData(result) {
        this._wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.agreement = data.agreement || {};
            this.forecasts = (data.forecasts || []);
            this._buildProducts(data.products || []);
            this.error = undefined;
        } else if (error) {
            this._toast('エラー', error.body?.message || 'データ取得エラー', 'error');
        }
    }

    _buildProducts(prods) {
        this.products = prods.map(p => {
            const months = (p.schedules || []).map(s => {
                const d = new Date(s.month + 'T00:00:00');
                const label = d.getFullYear() + '/' + String(d.getMonth() + 1).padStart(2, '0');
                const unitPrice = p.unitPrice || 0;
                return {
                    id: s.id,
                    month: s.month,
                    label,
                    planQty: s.planQty,
                    planAmt: s.planAmt,
                    actualQty: s.actualQty,
                    actualAmt: s.actualAmt,
                    planAmtFmt: this._fmtCur(s.planAmt),
                    actualAmtFmt: this._fmtCur(s.actualAmt),
                    variance: this._calcVariance(s.planQty, s.actualQty),
                    varianceClass: this._varianceClass(s.planQty, s.actualQty),
                    key: s.id,
                    unitPrice
                };
            });
            const totalPlanQty = months.reduce((s, m) => s + (m.planQty || 0), 0);
            const totalActualQty = months.reduce((s, m) => s + (m.actualQty || 0), 0);
            const totalPlanAmt = months.reduce((s, m) => s + (m.planAmt || 0), 0);
            const totalActualAmt = months.reduce((s, m) => s + (m.actualAmt || 0), 0);
            return {
                id: p.id,
                productName: p.productName,
                unitPrice: p.unitPrice,
                unitPriceFmt: this._fmtCur(p.unitPrice),
                months,
                totalPlanQty: this._fmtNum(totalPlanQty),
                totalActualQty: this._fmtNum(totalActualQty),
                totalPlanAmt: this._fmtCur(totalPlanAmt),
                totalActualAmt: this._fmtCur(totalActualAmt),
                key: p.id
            };
        });
    }

    get hasProducts() { return this.products.length > 0; }
    get saveLabel() { return this.isSaving ? '保存中...' : '保存'; }
    get saveDisabled() { return this.isSaving || !this.isDirty; }
    get hasForecasts() { return this.forecasts.length > 0; }
    get forecastToggleLabel() { return this.showForecasts ? '予測を非表示' : '参考: 受注予測を表示'; }

    get forecastLines() {
        // Group by product
        const grouped = {};
        for (const f of this.forecasts) {
            if (!grouped[f.productName]) grouped[f.productName] = [];
            grouped[f.productName].push(f.period + '=' + this._fmtNum(f.quantity));
        }
        return Object.entries(grouped).map(([name, items]) => ({
            key: name,
            text: name + ': ' + items.join(', ')
        }));
    }

    handleToggleForecasts() {
        this.showForecasts = !this.showForecasts;
    }

    handlePlanQtyChange(e) {
        const { product: prodId, month } = e.target.dataset;
        const val = e.target.value !== '' ? parseInt(e.target.value, 10) : null;
        this._updateCell(prodId, month, 'planQty', val);
    }

    handleActualQtyChange(e) {
        const { product: prodId, month } = e.target.dataset;
        const val = e.target.value !== '' ? parseInt(e.target.value, 10) : null;
        this._updateCell(prodId, month, 'actualQty', val);
    }

    _updateCell(prodId, month, field, val) {
        this.products = this.products.map(p => {
            if (p.id !== prodId) return p;
            const months = p.months.map(m => {
                if (m.month !== month) return m;
                const updated = { ...m, [field]: val };
                // Recalc amounts
                if (field === 'planQty') {
                    updated.planAmt = (val || 0) * m.unitPrice;
                    updated.planAmtFmt = this._fmtCur(updated.planAmt);
                } else if (field === 'actualQty') {
                    updated.actualAmt = val != null ? val * m.unitPrice : null;
                    updated.actualAmtFmt = this._fmtCur(updated.actualAmt);
                }
                updated.variance = this._calcVariance(updated.planQty, updated.actualQty);
                updated.varianceClass = this._varianceClass(updated.planQty, updated.actualQty);
                return updated;
            });
            const totalPlanQty = months.reduce((s, m) => s + (m.planQty || 0), 0);
            const totalActualQty = months.reduce((s, m) => s + (m.actualQty || 0), 0);
            const totalPlanAmt = months.reduce((s, m) => s + (m.planAmt || 0), 0);
            const totalActualAmt = months.reduce((s, m) => s + (m.actualAmt || 0), 0);
            return {
                ...p, months,
                totalPlanQty: this._fmtNum(totalPlanQty),
                totalActualQty: this._fmtNum(totalActualQty),
                totalPlanAmt: this._fmtCur(totalPlanAmt),
                totalActualAmt: this._fmtCur(totalActualAmt)
            };
        });
        this.isDirty = true;
    }

    async handleSave() {
        this.isSaving = true;
        try {
            const payload = [];
            for (const p of this.products) {
                for (const m of p.months) {
                    payload.push({
                        id: m.id,
                        planQty: m.planQty,
                        planAmt: m.planAmt,
                        actualQty: m.actualQty,
                        actualAmt: m.actualAmt
                    });
                }
            }
            await saveSchedules({ schedulesJson: JSON.stringify(payload) });
            this.isDirty = false;
            this._toast('保存完了', 'スケジュールを更新しました', 'success');
            await refreshApex(this._wiredResult);
        } catch (err) {
            this._toast('エラー', err.body?.message || err.message, 'error');
        } finally {
            this.isSaving = false;
        }
    }

    _calcVariance(plan, actual) {
        if (plan == null || actual == null || plan === 0) return '';
        const pct = ((actual - plan) / plan * 100).toFixed(1);
        return (pct >= 0 ? '+' : '') + pct + '%';
    }

    _varianceClass(plan, actual) {
        if (plan == null || actual == null) return 'var-cell';
        const ratio = actual / (plan || 1);
        if (ratio >= 0.95) return 'var-cell var-good';
        if (ratio >= 0.85) return 'var-cell var-warn';
        return 'var-cell var-bad';
    }

    _fmtNum(v) { return v != null ? Number(v).toLocaleString('ja-JP') : '−'; }
    _fmtCur(v) {
        if (v == null) return '−';
        const n = Number(v);
        if (Math.abs(n) >= 100000000) return '¥' + (n / 100000000).toFixed(1) + '億';
        if (Math.abs(n) >= 10000) return '¥' + Math.round(n / 10000).toLocaleString('ja-JP') + '万';
        return '¥' + n.toLocaleString('ja-JP');
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
