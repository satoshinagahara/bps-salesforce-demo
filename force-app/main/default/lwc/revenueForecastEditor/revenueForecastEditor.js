import { LightningElement, api, wire } from 'lwc';
import getForecasts from '@salesforce/apex/RevenueForecastEditorController.getForecasts';
import saveForecasts from '@salesforce/apex/RevenueForecastEditorController.saveForecasts';
import getDefaultPrice from '@salesforce/apex/RevenueForecastEditorController.getDefaultPrice';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const QUARTERS = ['Q1', 'Q2', 'Q3', 'Q4'];
const FISCAL_YEARS = ['FY2025', 'FY2026', 'FY2027', 'FY2028', 'FY2029', 'FY2030'];

export default class RevenueForecastEditor extends LightningElement {
    @api recordId;
    productOptions = [];
    yearOptions = FISCAL_YEARS.map(y => ({ label: y, value: y }));

    // Grid state: { productId -> { year -> { Q1: {id,qty,price}, Q2:..., Q3:..., Q4:... } } }
    gridData = {};
    productEntries = []; // [{productId, productName, years: [{year, quarters: [{q, qty, price, amount, id}]}]}]
    isDirty = false;
    isSaving = false;
    _wiredResult;
    _deleteIds = [];

    // Add row state
    addYear = 'FY2027';
    addProductId = '';

    @wire(getForecasts, { opportunityId: '$recordId' })
    wiredData(result) {
        this._wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.productOptions = (data.productOptions || []).map(o => ({
                label: o.label, value: o.value
            }));
            if (this.productOptions.length > 0 && !this.addProductId) {
                this.addProductId = this.productOptions[0].value;
            }
            this._buildGrid(data.records || []);
        } else if (error) {
            this._toast('エラー', error.body?.message || 'データ取得エラー', 'error');
        }
    }

    _buildGrid(records) {
        const grid = {};
        for (const r of records) {
            const pid = r.productId;
            const yr = r.fiscalYear;
            const q = r.quarter || 'Q1';
            if (!grid[pid]) grid[pid] = { name: r.productName, years: {} };
            if (!grid[pid].years[yr]) grid[pid].years[yr] = {};
            grid[pid].years[yr][q] = {
                id: r.id,
                qty: r.quantity || 0,
                price: r.unitPrice || 0,
                status: r.status
            };
        }
        this.gridData = grid;
        this._refreshEntries();
    }

    _refreshEntries() {
        const entries = [];
        for (const [pid, pdata] of Object.entries(this.gridData)) {
            const years = [];
            const sortedYears = Object.keys(pdata.years).sort();
            for (const yr of sortedYears) {
                const qdata = pdata.years[yr];
                // 共通単価を最初のQから取得
                let commonPrice = 0;
                for (const q of QUARTERS) {
                    if (qdata[q] && qdata[q].price) { commonPrice = qdata[q].price; break; }
                }
                const quarters = QUARTERS.map(q => {
                    const d = qdata[q] || { qty: 0, price: commonPrice, id: null };
                    const price = d.price || commonPrice;
                    return {
                        q,
                        qty: d.qty,
                        price: price,
                        amount: d.qty * price,
                        id: d.id,
                        key: `${pid}-${yr}-${q}`
                    };
                });
                const yearTotalRaw = quarters.reduce((s, x) => s + x.amount, 0);
                const yearQty = quarters.reduce((s, x) => s + x.qty, 0);
                // Format amounts for display
                for (const qr of quarters) {
                    qr.amountFmt = this.fmtCur(qr.amount);
                }
                years.push({
                    year: yr, quarters,
                    commonPrice: commonPrice,
                    yearTotal: this.fmtCur(yearTotalRaw),
                    yearQty: this.fmtNum(yearQty),
                    key: `${pid}-${yr}`
                });
            }
            entries.push({ productId: pid, productName: pdata.name, years, key: pid });
        }
        this.productEntries = entries;
    }

    get hasEntries() { return this.productEntries.length > 0; }
    get saveDisabled() { return this.isSaving || !this.isDirty; }
    get saveLabel() { return this.isSaving ? '保存中...' : '保存'; }

    // --- Handlers ---

    handleQtyChange(e) {
        const { product, year, quarter } = e.target.dataset;
        const val = parseInt(e.target.value, 10) || 0;
        this._ensureCell(product, year, quarter);
        this.gridData[product].years[year][quarter].qty = val;
        this.isDirty = true;
        this._refreshEntries();
    }

    handlePriceChange(e) {
        const { product, year } = e.target.dataset;
        const val = parseInt(e.target.value, 10) || 0;
        // 単価は年度内の全Qに適用
        if (this.gridData[product]?.years[year]) {
            for (const q of QUARTERS) {
                this._ensureCell(product, year, q);
                this.gridData[product].years[year][q].price = val;
            }
        }
        this.isDirty = true;
        this._refreshEntries();
    }

    handleAddYearChange(e) { this.addYear = e.detail.value; }
    handleAddProductChange(e) { this.addProductId = e.detail.value; }

    async handleAddRow() {
        const pid = this.addProductId;
        const yr = this.addYear;
        if (!pid || !yr) return;

        if (!this.gridData[pid]) {
            const popt = this.productOptions.find(o => o.value === pid);
            this.gridData[pid] = { name: popt ? popt.label : '', years: {} };
        }
        if (this.gridData[pid].years[yr]) {
            this._toast('情報', `${yr} は既に追加されています`, 'info');
            return;
        }

        // 既存年度から単価を引き継ぎ、なければ価格表から取得
        let defaultPrice = 0;
        const existingYears = Object.values(this.gridData[pid].years || {});
        for (const ydata of existingYears) {
            for (const q of QUARTERS) {
                if (ydata[q]?.price) { defaultPrice = ydata[q].price; break; }
            }
            if (defaultPrice) break;
        }
        if (!defaultPrice) {
            try {
                defaultPrice = await getDefaultPrice({ productId: pid }) || 0;
            } catch (_) { /* ignore */ }
        }

        this.gridData[pid].years[yr] = {};
        for (const q of QUARTERS) {
            this.gridData[pid].years[yr][q] = { id: null, qty: 0, price: defaultPrice };
        }
        this.isDirty = true;
        this._refreshEntries();
    }

    handleRemoveYear(e) {
        const { product, year } = e.currentTarget.dataset;
        if (this.gridData[product]?.years[year]) {
            // 既存レコードのIDを削除リストに追加
            for (const q of QUARTERS) {
                const cell = this.gridData[product].years[year][q];
                if (cell?.id) this._deleteIds.push(cell.id);
            }
            delete this.gridData[product].years[year];
            if (Object.keys(this.gridData[product].years).length === 0) {
                delete this.gridData[product];
            }
            this.isDirty = true;
            this._refreshEntries();
        }
    }

    async handleSave() {
        this.isSaving = true;
        try {
            const payload = [];
            // 削除分
            for (const id of this._deleteIds) {
                payload.push({ id, action: 'delete' });
            }
            // upsert分
            for (const [pid, pdata] of Object.entries(this.gridData)) {
                for (const [yr, qdata] of Object.entries(pdata.years)) {
                    for (const q of QUARTERS) {
                        const cell = qdata[q];
                        if (!cell) continue;
                        payload.push({
                            id: cell.id || '',
                            productId: pid,
                            fiscalYear: yr,
                            quarter: q,
                            quantity: cell.qty || 0,
                            unitPrice: cell.price || 0,
                            action: 'upsert'
                        });
                    }
                }
            }

            await saveForecasts({
                opportunityId: this.recordId,
                forecastsJson: JSON.stringify(payload)
            });
            this._deleteIds = [];
            this.isDirty = false;
            this._toast('保存完了', '受注予測を更新しました', 'success');
            await refreshApex(this._wiredResult);
        } catch (err) {
            this._toast('エラー', err.body?.message || err.message, 'error');
        } finally {
            this.isSaving = false;
        }
    }

    _ensureCell(product, year, quarter) {
        if (!this.gridData[product]) this.gridData[product] = { name: '', years: {} };
        if (!this.gridData[product].years[year]) this.gridData[product].years[year] = {};
        if (!this.gridData[product].years[year][quarter]) {
            this.gridData[product].years[year][quarter] = { id: null, qty: 0, price: 0 };
        }
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    fmtCur(v) { return v != null ? '¥' + Number(v).toLocaleString('ja-JP') : '¥0'; }
    fmtNum(v) { return v != null ? Number(v).toLocaleString('ja-JP') : '0'; }
}
