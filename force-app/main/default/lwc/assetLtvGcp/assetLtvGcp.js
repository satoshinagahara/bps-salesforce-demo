import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getLtv from '@salesforce/apex/AssetLtvController.getLtv';

export default class AssetLtvGcp extends LightningElement {
    @api recordId;
    data;
    error;
    _wired;

    @wire(getLtv, { assetId: '$recordId' })
    wired(result) {
        this._wired = result;
        if (result.data) {
            this.data = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error.body?.message || 'LTV取得エラー';
        }
    }

    get hasData() { return !!this.data; }
    get hasError() { return !!this.error; }
    get hasNextEvent() { return this.data && this.data.nextMajorEvent; }

    // 4要素スタックバーの幅計算
    get stackSegments() {
        if (!this.data) return [];
        const b = this.data.breakdown;
        const total = this.data.projectedLtv || 1;
        const segs = [
            { key: 'initial', label: '初期納入', amount: b.initialSale, formatted: this.data.initialSaleFormatted, cls: 'seg seg-initial' },
            { key: 'realized', label: '保守実績', amount: b.realizedService, formatted: this.data.realizedServiceFormatted, cls: 'seg seg-realized' },
            { key: 'planned', label: '保守予定', amount: b.plannedService, formatted: this.data.plannedServiceFormatted, cls: 'seg seg-planned' },
            { key: 'alert', label: 'アラート見込', amount: b.alertOpportunity, formatted: this.data.alertOpportunityFormatted, cls: 'seg seg-alert' }
        ];
        return segs.map(s => ({
            ...s,
            style: `width:${((s.amount || 0) / total * 100).toFixed(2)}%;`,
            visible: s.amount && s.amount > 0
        }));
    }

    // 年次累積グラフ用の座標計算（SVG）
    get chartData() {
        if (!this.data || !this.data.yearlySeries || !this.data.yearlySeries.length) return null;
        const series = this.data.yearlySeries;
        const W = 600, H = 120, PAD_L = 4, PAD_R = 4, PAD_T = 8, PAD_B = 20;
        const maxVal = Math.max(...series.map(p => p.cumulative)) || 1;
        const n = series.length;
        const stepX = n > 1 ? (W - PAD_L - PAD_R) / (n - 1) : 0;
        const points = series.map((p, i) => {
            const x = PAD_L + stepX * i;
            const y = H - PAD_B - ((p.cumulative / maxVal) * (H - PAD_T - PAD_B));
            return {
                x, y,
                year: p.year,
                cumulative: p.cumulative,
                isFuture: p.isFuture,
                fill: p.isFuture ? '#ffb75d' : '#1589ee'
            };
        });
        const linePath = points.map((pt, i) => (i === 0 ? `M${pt.x},${pt.y}` : `L${pt.x},${pt.y}`)).join(' ');
        const areaPath = `${linePath} L${points[points.length-1].x},${H-PAD_B} L${points[0].x},${H-PAD_B} Z`;

        // 本日位置を示す縦ライン
        const today = new Date().getFullYear();
        const todayIdx = series.findIndex(p => p.year === today);
        const todayX = todayIdx >= 0 ? PAD_L + stepX * todayIdx : null;

        return {
            viewBox: `0 0 ${W} ${H}`,
            linePath,
            areaPath,
            points,
            todayX,
            todayY1: PAD_T,
            todayY2: H - PAD_B,
            axisY: H - PAD_B,
            maxFormatted: this._fmt(maxVal)
        };
    }

    get multipleBadgeClass() {
        if (!this.data) return 'multiple-badge';
        if (this.data.ltvMultiple >= 1.3) return 'multiple-badge multiple-high';
        if (this.data.ltvMultiple >= 1.1) return 'multiple-badge multiple-mid';
        return 'multiple-badge multiple-low';
    }

    _fmt(v) {
        if (v == null) return '¥0';
        if (v >= 100000000) return `¥${(v/100000000).toFixed(2)}億`;
        if (v >= 10000) return `¥${Math.round(v/10000)}万`;
        return `¥${Math.round(v)}`;
    }

    handleRefresh() {
        if (this._wired) refreshApex(this._wired);
    }
}
