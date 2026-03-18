import { LightningElement, api, wire, track } from 'lwc';
import getGanttData from '@salesforce/apex/DesignPhaseGanttController.getGanttData';

const STATUS_COLORS = {
    '完了': '#2e844a',
    '進行中': '#0176d3',
    '未着手': '#b0adab',
    '遅延': '#ba0517'
};

const GATE_ICONS = {
    '合格': { symbol: '\u2713', color: '#2e844a' },
    '条件付合格': { symbol: '\u25B3', color: '#fe9339' },
    '差戻し': { symbol: '\u2717', color: '#ba0517' },
    '未実施': { symbol: '\u2015', color: '#b0adab' }
};

function toEpoch(dateStr) {
    if (!dateStr) return null;
    return new Date(dateStr).getTime();
}

function fmtDate(dateStr) {
    if (!dateStr) return '';
    const d = new Date(dateStr);
    return `${d.getFullYear()}/${String(d.getMonth() + 1).padStart(2, '0')}/${String(d.getDate()).padStart(2, '0')}`;
}

function monthsBetween(start, end) {
    const months = [];
    const d = new Date(start);
    d.setDate(1);
    const endTime = new Date(end).getTime();
    while (d.getTime() <= endTime) {
        months.push({
            key: `${d.getFullYear()}-${d.getMonth()}`,
            label: `${d.getFullYear()}/${String(d.getMonth() + 1).padStart(2, '0')}`,
            time: d.getTime()
        });
        d.setMonth(d.getMonth() + 1);
    }
    return months;
}

export default class DesignPhaseGantt extends LightningElement {
    @api recordId;
    @track _data = null;
    @track error = null;
    @track isLoading = true;

    @wire(getGanttData, { recordId: '$recordId' })
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

    get hasData() {
        return this._data?.phases?.length > 0;
    }

    // ── KPIs ──
    get totalPhases() { return this._data?.totalPhases ?? 0; }
    get completedPhases() { return this._data?.completedPhases ?? 0; }
    get delayedPhases() { return this._data?.delayedPhases ?? 0; }
    get progressPct() {
        const t = this.totalPhases;
        return t > 0 ? Math.round((this.completedPhases / t) * 100) : 0;
    }
    get progressBarStyle() {
        return `width:${this.progressPct}%`;
    }
    get nextGateDate() {
        return fmtDate(this._data?.nextGateDate);
    }
    get hasDelay() {
        return this.delayedPhases > 0;
    }

    // ── Timeline ──
    get timelineStart() {
        return toEpoch(this._data?.timelineStart);
    }
    get timelineEnd() {
        return toEpoch(this._data?.timelineEnd);
    }
    get timelineSpan() {
        const s = this.timelineStart;
        const e = this.timelineEnd;
        if (!s || !e || e <= s) return 1;
        return e - s;
    }
    get todayPct() {
        const t = toEpoch(this._data?.today);
        if (!t) return -1;
        const s = this.timelineStart;
        const span = this.timelineSpan;
        const pct = ((t - s) / span) * 100;
        if (pct < 0 || pct > 100) return -1;
        return pct;
    }
    get showTodayLine() {
        return this.todayPct >= 0 && this.todayPct <= 100;
    }
    get todayLineStyle() {
        return `left:${this.todayPct}%`;
    }

    // ── Month headers ──
    get monthHeaders() {
        if (!this._data?.timelineStart || !this._data?.timelineEnd) return [];
        const months = monthsBetween(this._data.timelineStart, this._data.timelineEnd);
        const s = this.timelineStart;
        const span = this.timelineSpan;
        return months.map((m, i, arr) => {
            const left = ((m.time - s) / span) * 100;
            const nextTime = i < arr.length - 1 ? arr[i + 1].time : this.timelineEnd;
            const width = ((nextTime - m.time) / span) * 100;
            return {
                key: m.key,
                label: m.label,
                style: `left:${left}%;width:${width}%`
            };
        });
    }

    // ── Phase rows ──
    get phaseRows() {
        const phases = this._data?.phases;
        if (!phases) return [];
        const s = this.timelineStart;
        const span = this.timelineSpan;

        return phases.map(ph => {
            const ps = toEpoch(ph.plannedStart);
            const pe = toEpoch(ph.plannedEnd);
            const as_ = toEpoch(ph.actualStart);
            const ae = toEpoch(ph.actualEnd) || (ph.status === '進行中' ? toEpoch(this._data.today) : null);

            const statusColor = STATUS_COLORS[ph.status] || '#b0adab';
            const gate = GATE_ICONS[ph.gateResult] || GATE_ICONS['未実施'];

            // Planned bar
            let plannedStyle = 'display:none';
            if (ps && pe) {
                const left = ((ps - s) / span) * 100;
                const width = ((pe - ps) / span) * 100;
                plannedStyle = `left:${left}%;width:${Math.max(width, 0.5)}%;background-color:${statusColor};opacity:0.25`;
            }

            // Actual bar
            let actualStyle = 'display:none';
            if (as_) {
                const end = ae || as_;
                const left = ((as_ - s) / span) * 100;
                const width = ((end - as_) / span) * 100;
                actualStyle = `left:${left}%;width:${Math.max(width, 0.5)}%;background-color:${statusColor}`;
            }

            return {
                key: ph.id,
                name: ph.name,
                ownerName: ph.ownerName || '',
                status: ph.status,
                statusColor,
                statusStyle: `background-color:${statusColor}`,
                gateSymbol: gate.symbol,
                gateColor: gate.color,
                gateStyle: `color:${gate.color}`,
                gateResult: ph.gateResult || '',
                plannedDates: ps && pe ? `${fmtDate(ph.plannedStart)} - ${fmtDate(ph.plannedEnd)}` : '',
                actualDates: as_ ? `${fmtDate(ph.actualStart)}${ae ? ' - ' + fmtDate(ph.actualEnd) : ' -'}` : '',
                plannedBarStyle: plannedStyle,
                actualBarStyle: actualStyle
            };
        });
    }
}
