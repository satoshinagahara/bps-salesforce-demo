import { LightningElement, api, wire, track } from 'lwc';
import getEffortData from '@salesforce/apex/ActivityEffortController.getEffortData';

const COLORS = [
    '#0176d3', '#2e844a', '#fe9339', '#9050e9',
    '#16afd1', '#dd8f7a', '#ba0517', '#7f8c8d'
];

function fmtHours(minutes) {
    if (!minutes || minutes === 0) return '0h';
    const h = Math.floor(minutes / 60);
    const m = Math.round(minutes % 60);
    if (h === 0) return `${m}m`;
    if (m === 0) return `${h}h`;
    return `${h}h ${m}m`;
}

export default class ActivityEffortTracker extends LightningElement {
    @api recordId;
    @track _data = null;
    @track error = null;
    @track isLoading = true;

    @wire(getEffortData, { recordId: '$recordId' })
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

    // ── KPIs ──
    get totalHours()      { return fmtHours(this._data?.totalMinutes ?? 0); }
    get totalActivities() { return (this._data?.totalEvents ?? 0) + (this._data?.totalTasks ?? 0); }
    get totalEvents()     { return this._data?.totalEvents ?? 0; }
    get totalTasks()      { return this._data?.totalTasks ?? 0; }
    get memberCount()     { return this._data?.memberCount ?? 0; }
    get dateRange() {
        const e = this._data?.earliestDate;
        const l = this._data?.latestDate;
        if (!e) return '';
        if (e === l) return e;
        return `${e} - ${l}`;
    }

    get hasData() { return this.totalActivities > 0; }

    // ── Member bars ──
    get memberBars() {
        const members = this._data?.members;
        if (!members || members.length === 0) return [];
        const maxMin = Math.max(...members.map(m => m.minutes || 0), 1);
        return members.map((m, i) => {
            const mins = m.minutes || 0;
            const pct = Math.max(Math.round((mins / maxMin) * 100), 2);
            const color = COLORS[i % COLORS.length];
            return {
                key: m.userId,
                name: m.name,
                hours: fmtHours(mins),
                eventCount: m.eventCount || 0,
                taskCount: m.taskCount || 0,
                totalCount: (m.eventCount || 0) + (m.taskCount || 0),
                barStyle: `width:${pct}%;background-color:${color}`,
                dotStyle: `background-color:${color}`,
            };
        });
    }
}
