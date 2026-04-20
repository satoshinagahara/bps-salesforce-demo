import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getDashboard from '@salesforce/apex/SupplierPortalController.getDashboard';

/**
 * サプライヤーポータル ホームダッシュボード
 *
 * 設計書: docs/in-progress/supplier-portal-design.md セクション6
 * Wave 2: 個別レコードへのドリルダウン導線を廃止。
 *         KPIカード/サマリーからは対応する「一覧ページ」へナビゲートする。
 */
export default class SupplierPortalHome extends NavigationMixin(LightningElement) {
    @api recordId; // Account RecordPageに置かれた場合
    @api accountId; // デザインパネルからの指定値

    dashboard;
    error;

    @wire(getDashboard, { accountId: '$targetAccountId' })
    wiredDashboard({ data, error }) {
        if (data) {
            this.dashboard = data;
            this.error = undefined;
        } else if (error) {
            this.error = this.extractError(error);
            this.dashboard = undefined;
        }
    }

    get targetAccountId() {
        return this.accountId || this.recordId || null;
    }

    get isLoading() {
        return !this.dashboard && !this.error;
    }

    // ==== ヘッダ ====
    get supplierName() {
        return this.dashboard?.supplier?.name || '';
    }

    get greeting() {
        const h = new Date().getHours();
        if (h < 11) return 'おはようございます';
        if (h < 17) return 'こんにちは';
        return 'お疲れさまです';
    }

    get todayLabel() {
        const now = new Date();
        return `${now.getFullYear()}/${String(now.getMonth() + 1).padStart(2, '0')}/${String(now.getDate()).padStart(2, '0')}`;
    }

    // ==== KPIカード ====
    // destination: 相対URL (Experience Cloud サイト内の urlPrefix)
    get kpiCards() {
        const k = this.dashboard?.actionKpis;
        if (!k) return [];
        const defs = [
            {
                key: 'rfq',
                destination: 'rfq-list',
                icon: 'utility:quote',
                label: '未回答のRFQ',
                value: k.unansweredRfqCount ?? 0,
                unit: '件',
                sub: this.formatNearest(k.unansweredRfqNearestDue, '最短期限', '回答期限なし'),
                isAlert: (k.unansweredRfqCount ?? 0) > 0
            },
            {
                key: 'inv',
                destination: 'investigation-list',
                icon: 'utility:info_alt',
                label: '対応中の品質調査',
                value: k.ongoingInvestigationCount ?? 0,
                unit: '件',
                sub: this.formatNearest(k.investigationNearestDue, '最短期限', '期限なし'),
                isAlert: (k.ongoingInvestigationCount ?? 0) > 0
            },
            {
                key: 'cert',
                destination: 'certifications',
                icon: 'utility:check',
                label: '期限間近の認証',
                value: k.expiringCertificationCount ?? 0,
                unit: '件',
                sub: k.certNearestExpiryDays != null
                    ? `残 ${k.certNearestExpiryDays} 日`
                    : '期限間近なし',
                isAlert: (k.expiringCertificationCount ?? 0) > 0
            },
            {
                key: 'cap',
                destination: 'capacity',
                icon: 'utility:chart',
                label: 'キャパシティ未更新',
                value: k.outdatedCapacitySiteCount ?? 0,
                unit: '拠点',
                sub: k.capacityOldestUpdateDate
                    ? `最古更新: ${this.fmtDate(k.capacityOldestUpdateDate)}`
                    : '最新',
                isAlert: (k.outdatedCapacitySiteCount ?? 0) > 0
            }
        ];
        return defs.map(d => ({
            ...d,
            cardClass: d.isAlert ? 'spc-kpi spc-kpi--alert spc-kpi--clickable' : 'spc-kpi spc-kpi--clickable'
        }));
    }

    handleKpiClick(event) {
        const dest = event.currentTarget.dataset.destination;
        if (!dest) return;
        this.navigateToRelative(dest);
    }

    /**
     * Experience Cloud サイト内の相対ページへナビゲート。
     * Partner Central Enhanced Template では standard__webPage で相対URLを使う。
     */
    navigateToRelative(urlPrefix) {
        this[NavigationMixin.Navigate]({
            type: 'standard__webPage',
            attributes: { url: `/${urlPrefix}` }
        });
    }

    formatNearest(dateStr, prefix, fallback) {
        if (!dateStr) return fallback;
        return `${prefix}: ${this.fmtDate(dateStr)}`;
    }

    // ==== RFQ進行チャート ====
    get rfqChartData() {
        return this.buildChart(this.dashboard?.rfqStatusBreakdown, [
            '依頼中', '回答済', '辞退', '採用', '不採用'
        ]);
    }

    // ==== 調査バーチャート ====
    get investigationChartData() {
        return this.buildChart(this.dashboard?.investigationStatusBreakdown, [
            '依頼中', '調査中', '回答済', '対策実施中', '完了'
        ]);
    }

    buildChart(rows, order) {
        if (!rows) return { total: 0, items: [] };
        const map = new Map(rows.map(r => [r.status, r.count]));
        const total = rows.reduce((s, r) => s + (r.count ?? 0), 0);
        const palette = ['#FBEAEB', '#F2C0C2', '#E08488', '#D21D24', '#A61319'];
        const items = order.map((st, i) => {
            const c = map.get(st) ?? 0;
            const pct = total > 0 ? Math.round((c / total) * 100) : 0;
            return {
                label: st,
                count: c,
                percent: pct,
                color: palette[i % palette.length],
                barStyle: `width: ${pct}%; background: ${palette[i % palette.length]};`
            };
        });
        return { total, items };
    }

    // ==== キャパシティサマリー (表示のみ、個別レコードに遷移しない) ====
    get capacityRows() {
        const rows = this.dashboard?.capacitySummary;
        if (!rows) return [];
        return rows.map(r => ({
            ...r,
            totalLabel: this.fmtNumber(r.totalMonthlyCapacity),
            expiryLabel: r.earliestExpiryDate
                ? this.fmtDate(r.earliestExpiryDate)
                : '—',
            expiryClass: r.isExpiringSoon ? 'spc-capacity__expiry spc-capacity__expiry--warn' : 'spc-capacity__expiry'
        }));
    }

    get hasCapacity() {
        return (this.dashboard?.capacitySummary?.length ?? 0) > 0;
    }

    // クリックで製造拠点一覧へ
    handleCapacityCardClick() {
        this.navigateToRelative('capacity');
    }

    // ==== ユーティリティ ====
    fmtDate(d) {
        if (!d) return '';
        const dt = typeof d === 'string' ? new Date(d) : d;
        return `${dt.getFullYear()}/${String(dt.getMonth() + 1).padStart(2, '0')}/${String(dt.getDate()).padStart(2, '0')}`;
    }

    fmtNumber(n) {
        if (n == null) return '0';
        return new Intl.NumberFormat('ja-JP').format(n);
    }

    extractError(err) {
        if (err?.body?.message) return err.body.message;
        if (Array.isArray(err?.body)) return err.body.map(e => e.message).join(', ');
        return err?.message || 'エラーが発生しました';
    }
}
