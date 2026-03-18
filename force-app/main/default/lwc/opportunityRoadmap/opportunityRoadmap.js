import { LightningElement, api, wire } from 'lwc';
import getRoadmapData from '@salesforce/apex/OpportunityRoadmapController.getRoadmapData';
import { NavigationMixin } from 'lightning/navigation';

const STATUS_STYLE = {
    '起案': 'slds-badge badge-draft',
    '評価中': 'slds-badge badge-eval',
    '承認': 'slds-badge badge-approved',
    '実行中': 'slds-badge badge-active',
    '計画中': 'slds-badge badge-draft',
    '進行中': 'slds-badge badge-active',
    'レビュー中': 'slds-badge badge-eval'
};

const PRIORITY_ICON = { '高': '🔴', '中': '🟡', '低': '🟢' };

export default class OpportunityRoadmap extends NavigationMixin(LightningElement) {
    @api recordId;
    initiatives = [];
    designProjects = [];
    families = [];
    error;
    isLoading = true;

    @wire(getRoadmapData, { opportunityId: '$recordId' })
    wiredData({ error, data }) {
        this.isLoading = false;
        if (data) {
            this.families = data.families || [];
            this.initiatives = (data.initiatives || []).map(i => ({
                ...i,
                statusClass: STATUS_STYLE[i.status] || 'slds-badge',
                priorityIcon: PRIORITY_ICON[i.priority] || '',
                dateRange: this._formatDateRange(i.targetStart, i.targetRelease),
                url: `/${i.id}`
            }));
            this.designProjects = (data.designProjects || []).map(p => ({
                ...p,
                statusClass: STATUS_STYLE[p.status] || 'slds-badge',
                dateRange: this._formatDateRange(p.startDate, p.targetEndDate),
                hasInitiative: !!p.initiative,
                url: `/${p.id}`
            }));
            this.error = undefined;
        } else if (error) {
            this.error = error.body?.message || 'データ取得エラー';
            this.initiatives = [];
            this.designProjects = [];
        }
    }

    get hasData() {
        return this.initiatives.length > 0 || this.designProjects.length > 0;
    }

    get hasInitiatives() {
        return this.initiatives.length > 0;
    }

    get hasProjects() {
        return this.designProjects.length > 0;
    }

    get familyLabel() {
        return this.families.join(', ');
    }

    get initiativeCount() {
        return this.initiatives.length;
    }

    get projectCount() {
        return this.designProjects.length;
    }

    navigateToRecord(event) {
        const recId = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: recId, actionName: 'view' }
        });
    }

    _formatDateRange(start, end) {
        const s = start ? this._formatDate(start) : '';
        const e = end ? this._formatDate(end) : '';
        if (s && e) return `${s} → ${e}`;
        if (e) return `→ ${e}`;
        if (s) return `${s} →`;
        return '日程未定';
    }

    _formatDate(d) {
        if (!d) return '';
        const dt = new Date(d);
        return `${dt.getFullYear()}/${String(dt.getMonth()+1).padStart(2,'0')}`;
    }
}
