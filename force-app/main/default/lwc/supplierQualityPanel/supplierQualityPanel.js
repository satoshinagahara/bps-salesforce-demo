import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getSupplierQualityData from '@salesforce/apex/SupplierQualityController.getSupplierQualityData';

export default class SupplierQualityPanel extends NavigationMixin(LightningElement) {
    @api recordId;

    data = null;
    isLoading = true;
    activeTab = 'audit';

    @wire(getSupplierQualityData, { accountId: '$recordId' })
    wiredData(result) {
        this.isLoading = false;
        const { data, error } = result;
        if (data) {
            this.data = data;
        } else if (error) {
            console.error('Error loading supplier quality data', error);
        }
    }

    get hasAudits() {
        return this.data && this.data.audits && this.data.audits.length > 0;
    }

    get hasCerts() {
        return this.data && this.data.certifications && this.data.certifications.length > 0;
    }

    get auditStats() {
        if (!this.data) return {};
        const s = this.data;
        return {
            auditCount: s.totalAudits || 0,
            avgScore: s.avgAuditScore != null ? s.avgAuditScore : '—',
            passRate: s.passRate != null ? s.passRate + '%' : '—',
            passRateClass: s.passRate >= 80 ? 'stat-value good' : s.passRate >= 50 ? 'stat-value warn' : 'stat-value danger'
        };
    }

    get certStats() {
        if (!this.data) return {};
        const s = this.data;
        return {
            activeCerts: s.activeCerts || 0,
            expiringSoon: s.expiringSoonCerts || 0,
            expired: s.expiredCerts || 0,
            activeCertsClass: 'stat-value good',
            expiringSoonClass: s.expiringSoonCerts > 0 ? 'stat-value warn' : 'stat-value',
            expiredClass: s.expiredCerts > 0 ? 'stat-value danger' : 'stat-value'
        };
    }

    get audits() {
        if (!this.data || !this.data.audits) return [];
        return this.data.audits.map(a => ({
            ...a,
            id: a.Id,
            auditNumber: a.Name,
            resultBadgeClass: 'result-badge ' + this.getAuditResultClass(a.result),
            findingCount: a.findingsCount,
            criticalFindingCount: a.criticalFindings,
            correctiveStatus: a.correctiveActionStatus,
            auditScope: a.scope
        }));
    }

    getAuditResultClass(result) {
        const map = {
            '合格': 'good',
            '条件付合格': 'warn',
            '不合格': 'danger',
            '保留': 'neutral'
        };
        return map[result] || 'neutral';
    }

    get certs() {
        if (!this.data || !this.data.certifications) return [];
        return this.data.certifications.map(c => {
            const expiryWarning = c.status === '有効' && c.daysToExpiry != null && c.daysToExpiry <= 90;
            return {
                ...c,
                id: c.Id,
                certBody: c.issuingBody,
                statusBadgeClass: 'status-badge ' + this.getCertStatusClass(c.status),
                expiryWarning,
                expiryDateClass: expiryWarning ? 'expiry-warning' : ''
            };
        });
    }

    getCertStatusClass(status) {
        const map = {
            '有効': 'good',
            '更新中': 'warn',
            '期限切れ': 'danger',
            '失効': 'danger'
        };
        return map[status] || 'neutral';
    }

    get isAuditTab() {
        return this.activeTab === 'audit';
    }

    get isCertTab() {
        return this.activeTab === 'cert';
    }

    get auditTabClass() {
        return this.activeTab === 'audit' ? 'tab-btn active' : 'tab-btn';
    }

    get certTabClass() {
        return this.activeTab === 'cert' ? 'tab-btn active' : 'tab-btn';
    }

    handleTabClick(event) {
        this.activeTab = event.target.dataset.tab;
    }
}