import { LightningElement, api, wire } from 'lwc';
import getScorecard from '@salesforce/apex/SupplierScorecardController.getScorecard';

export default class SupplierScorecard extends LightningElement {
    @api recordId;
    data;
    stats;
    isLoaded = false;
    hasError = false;
    errorMessage = '';

    @wire(getScorecard, { accountId: '$recordId' })
    wiredScorecard({ error, data }) {
        if (data) {
            this.data = this.processData(data);
            this.stats = data.stats;
            this.isLoaded = true;
            this.hasError = false;
        } else if (error) {
            this.hasError = true;
            this.errorMessage = error.body?.message || 'データの取得に失敗しました';
            this.isLoaded = true;
        }
    }

    processData(raw) {
        const d = JSON.parse(JSON.stringify(raw));

        // Process alerts
        d.alerts = (d.alerts || []).map(a => ({
            ...a,
            cssClass: `alert-item alert-${a.severity}`,
            iconClass: `alert-icon alert-icon-${a.severity}`
        }));

        // Process supply parts
        d.supplyParts = (d.supplyParts || []).map(p => ({
            ...p,
            formattedCost: p.unitCost != null ? '¥' + Number(p.unitCost).toLocaleString() : '-'
        }));

        // Process CAs
        d.correctiveActions = (d.correctiveActions || []).map(ca => ({
            ...ca,
            rowClass: ca.isOpen ? 'row-highlight' : '',
            phaseBadgeClass: ca.isOpen ? 'badge badge-phase-open' : 'badge badge-phase-done',
            severityClass: `badge badge-severity-${this.severityKey(ca.severity)}`
        }));

        // Process RFQ quotes
        d.rfqQuotes = (d.rfqQuotes || []).map(q => ({
            ...q,
            formattedPrice: q.unitPrice != null ? '¥' + Number(q.unitPrice).toLocaleString() : '-',
            statusClass: `badge badge-rfq-${this.rfqStatusKey(q.status)}`
        }));

        // Process certifications
        d.certifications = (d.certifications || []).map(c => ({
            ...c,
            formattedIssueDate: this.formatDate(c.issueDate),
            formattedExpiryDate: this.formatDate(c.expiryDate),
            rowClass: c.isExpired ? 'row-danger' : c.isExpiring ? 'row-warning' : '',
            statusClass: c.isExpired ? 'badge badge-danger' : c.isExpiring ? 'badge badge-warning' : 'badge badge-ok'
        }));

        // Process audits
        d.audits = (d.audits || []).map(a => ({
            ...a,
            formattedDate: this.formatDate(a.auditDate),
            resultClass: `badge badge-audit-${this.auditResultKey(a.result)}`
        }));

        // Process risks
        d.risks = (d.risks || []).map(r => ({
            ...r,
            cardClass: `risk-card risk-card-${r.level}`,
            iconClass: `risk-icon risk-icon-${r.level}`,
            levelBadge: `badge badge-risk-${r.level}`,
            levelLabel: r.level === 'high' ? '高' : r.level === 'medium' ? '中' : '低'
        }));

        // Process tasks
        d.tasks = (d.tasks || []).map(t => ({
            ...t,
            formattedDate: this.formatDate(t.activityDate)
        }));

        // Process events
        d.events = (d.events || []).map(e => ({
            ...e,
            formattedStart: this.formatDateTime(e.startDateTime)
        }));

        return d;
    }

    severityKey(s) {
        if (s === '重大') return 'critical';
        if (s === '重要') return 'major';
        return 'minor';
    }

    rfqStatusKey(s) {
        if (s === '採用') return 'adopted';
        if (s === '不採用') return 'rejected';
        return 'pending';
    }

    auditResultKey(r) {
        if (r === '合格') return 'pass';
        if (r === '条件付合格') return 'conditional';
        if (r === '不合格') return 'fail';
        return 'pending';
    }

    formatDate(d) {
        if (!d) return '-';
        const dt = new Date(d);
        return `${dt.getFullYear()}/${String(dt.getMonth() + 1).padStart(2, '0')}/${String(dt.getDate()).padStart(2, '0')}`;
    }

    formatDateTime(d) {
        if (!d) return '-';
        const dt = new Date(d);
        return `${dt.getFullYear()}/${String(dt.getMonth() + 1).padStart(2, '0')}/${String(dt.getDate()).padStart(2, '0')} ${String(dt.getHours()).padStart(2, '0')}:${String(dt.getMinutes()).padStart(2, '0')}`;
    }

    scoreClass(score) {
        if (score >= 90) return 'score-card score-a';
        if (score >= 70) return 'score-card score-b';
        if (score >= 50) return 'score-card score-c';
        return 'score-card score-d';
    }

    get overallScoreClass() { return this.data ? this.scoreClass(this.data.overallScore) : 'score-card'; }
    get qualityScoreClass() { return this.data ? this.scoreClass(this.data.qualityScore) : 'score-card'; }
    get costScoreClass() { return this.data ? this.scoreClass(this.data.costScore) : 'score-card'; }
    get complianceScoreClass() { return this.data ? this.scoreClass(this.data.complianceScore) : 'score-card'; }

    get hasAlerts() { return this.data?.alerts?.length > 0; }
    get hasSupplyParts() { return this.data?.supplyParts?.length > 0; }
    get hasCorrectiveActions() { return this.data?.correctiveActions?.length > 0; }
    get hasRfqQuotes() { return this.data?.rfqQuotes?.length > 0; }
    get hasCertifications() { return this.data?.certifications?.length > 0; }
    get hasAudits() { return this.data?.audits?.length > 0; }
    get hasTasks() { return this.data?.tasks?.length > 0; }
    get hasEvents() { return this.data?.events?.length > 0; }
    get noActivities() { return !this.hasTasks && !this.hasEvents; }

    get supplyPartsLabel() { return `供給部品 (${this.data?.supplyParts?.length || 0})`; }
    get qualityLabel() { return `品質 (${this.data?.correctiveActions?.length || 0})`; }
    get procurementLabel() { return `調達 (${this.data?.rfqQuotes?.length || 0})`; }
    get complianceLabel() { return '認証/監査'; }
    get riskLabel() { return `リスク (${this.data?.risks?.length || 0})`; }
    get activityLabel() { return '活動'; }
}
