import { LightningElement, api, wire, track } from 'lwc';
import getDashboardData from '@salesforce/apex/AccountDashboardController.getDashboardData';

// SVG donut constants (r=54, stroke-width=12)
const R = 54;
const C = 2 * Math.PI * R; // ≈ 339.29

const COLORS = [
    '#0176d3', '#2e844a', '#fe9339', '#9050e9',
    '#16afd1', '#dd8f7a', '#ba0517', '#7f8c8d'
];
const PRIORITY_COLORS = { High: '#ba0517', Medium: '#fe9339', Low: '#2e844a' };

/** Format a numeric amount to Japanese-friendly string */
function fmtAmount(v) {
    if (!v || v === 0) return '¥0';
    if (v >= 100000000) return `¥${(v / 100000000).toFixed(1)}億`;
    if (v >= 10000)     return `¥${Math.round(v / 10000).toLocaleString()}万`;
    return `¥${Math.round(v).toLocaleString()}`;
}

/**
 * Build SVG donut segment descriptors.
 * Each circle is rotated to its start angle and shows only its own arc.
 */
function buildDonutSegments(countMap, colorMap) {
    if (!countMap) return [];
    const entries = Object.entries(countMap);
    const total = entries.reduce((s, [, v]) => s + v, 0);
    if (total === 0) return [];

    let cumAngle = -90; // start from 12-o'clock
    return entries.map(([label, count], i) => {
        const pct    = count / total;
        const color  = colorMap?.[label] ?? COLORS[i % COLORS.length];
        const segLen = pct * C;
        const rot    = cumAngle;
        cumAngle    += pct * 360;
        return {
            key:         label,
            label,
            count,
            pct:         Math.round(pct * 100),
            circleStyle: `stroke:${color};stroke-dasharray:${segLen.toFixed(2)} ${C.toFixed(2)};transform:rotate(${rot}deg);transform-origin:60px 60px`,
            dotStyle:    `background-color:${color}`,
        };
    });
}

/** Build horizontal bar descriptors (width relative to max value). */
function buildBarSegments(valueMap, colorMap, formatFn) {
    if (!valueMap) return [];
    const entries = Object.entries(valueMap).filter(([, v]) => v > 0);
    if (entries.length === 0) return [];
    const max = Math.max(...entries.map(([, v]) => v));
    return entries.map(([label, value], i) => {
        const color = colorMap?.[label] ?? COLORS[i % COLORS.length];
        const pct   = Math.round((value / max) * 100);
        return {
            key:             label,
            label,
            count:           value,
            amountFormatted: formatFn ? formatFn(value) : String(value),
            barStyle:        `width:${pct}%;background-color:${color}`,
        };
    });
}

export default class AccountDashboard extends LightningElement {
    @api recordId;
    @track _data    = null;
    @track error    = null;
    @track isLoading = true;

    @wire(getDashboardData, { accountId: '$recordId' })
    wiredData({ data, error }) {
        this.isLoading = false;
        if (data) {
            this._data = data;
            this.error = null;
        } else if (error) {
            this.error = error?.body?.message ?? 'データの取得に失敗しました';
            this._data = null;
        }
    }

    // ── Account meta chips ──────────────────────────────────────────────────
    get accountDetails() {
        const acc = this._data?.account;
        if (!acc) return [];
        return [
            acc.Industry    && { key: 'ind',   icon: 'utility:company',       value: acc.Industry },
            acc.Type        && { key: 'type',   icon: 'utility:record_lookup', value: acc.Type },
            acc.Phone       && { key: 'phone',  icon: 'utility:call',          value: acc.Phone },
            acc.BillingCity && { key: 'city',   icon: 'utility:location',      value: acc.BillingCity },
            acc.Owner?.Name && { key: 'owner',  icon: 'utility:user',          value: acc.Owner.Name },
            acc.Rating      && { key: 'rating', icon: 'utility:rating',        value: acc.Rating },
        ].filter(Boolean);
    }

    // ── KPI values ──────────────────────────────────────────────────────────
    get oppTotal()           { return this._data?.oppTotal    ?? 0; }
    get oppWon()             { return this._data?.oppWon      ?? 0; }
    get oppOpen()            { return this._data?.oppOpen     ?? 0; }
    get oppLost()            { return this._data?.oppLost     ?? 0; }
    get caseTotal()          { return this._data?.caseTotal   ?? 0; }
    get caseOpen()           { return this._data?.caseOpen    ?? 0; }
    get caseClosed()         { return this._data?.caseClosed  ?? 0; }
    get contactCount()       { return this._data?.contactCount ?? 0; }
    get recentTasks()        { return this._data?.recentTasks  ?? 0; }
    get oppAmountFormatted() { return fmtAmount(this._data?.oppAmount ?? 0); }

    // ── Guards ──────────────────────────────────────────────────────────────
    get hasOppData()  { return this.oppTotal > 0; }
    get hasCaseData() { return this.caseTotal > 0; }

    // ── Opportunity charts ──────────────────────────────────────────────────
    get oppStageSegments() {
        return buildDonutSegments(this._data?.stageCount, null);
    }

    get winRate()  { return this.oppTotal ? Math.round(this.oppWon  / this.oppTotal * 100) : 0; }
    get openRate() { return this.oppTotal ? Math.round(this.oppOpen / this.oppTotal * 100) : 0; }
    get lossRate() { return this.oppTotal ? Math.round(this.oppLost / this.oppTotal * 100) : 0; }

    get winBarStyle()  { return `width:${this.winRate}%;background-color:#2e844a`; }
    get openBarStyle() { return `width:${this.openRate}%;background-color:#0176d3`; }
    get lossBarStyle() { return `width:${this.lossRate}%;background-color:#ba0517`; }

    get stageAmountBars() {
        return buildBarSegments(this._data?.stageAmount, null, fmtAmount);
    }

    // ── Case charts ─────────────────────────────────────────────────────────
    get openCaseRate()   { return this.caseTotal ? Math.round(this.caseOpen   / this.caseTotal * 100) : 0; }
    get closedCaseRate() { return this.caseTotal ? Math.round(this.caseClosed / this.caseTotal * 100) : 0; }

    get openCaseBarStyle()   { return `width:${this.openCaseRate}%;background-color:#ba0517`; }
    get closedCaseBarStyle() { return `width:${this.closedCaseRate}%;background-color:#2e844a`; }

    get caseStatusBars() {
        return buildBarSegments(this._data?.caseByStatus, null, null);
    }

    get casePrioritySegments() {
        return buildDonutSegments(this._data?.caseByPriority, PRIORITY_COLORS);
    }
}
