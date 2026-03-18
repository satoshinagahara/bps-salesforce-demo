import { LightningElement, wire } from 'lwc';
import getKPIData from '@salesforce/apex/QualityKPIController.getKPIData';

export default class QualityKpiPanel extends LightningElement {
    kpiData;
    error;

    totalOpen = 0;
    totalClosed = 0;
    overdueCount = 0;
    dueThisMonth = 0;

    severityItems = [];
    phaseItems = [];
    categoryItems = [];

    @wire(getKPIData)
    wiredKPI({ data, error }) {
        if (data) {
            this.kpiData = data;
            this.error = undefined;
            this.totalOpen = data.totalOpen || 0;
            this.totalClosed = data.totalClosed || 0;
            this.overdueCount = data.overdueCount || 0;
            this.dueThisMonth = data.dueThisMonth || 0;
            this.processSeverity(data.bySeverity || {});
            this.processPhases(data.byPhase || {});
            this.processCategories(data.byCategory || {});
        } else if (error) {
            this.error = error;
        }
    }

    processSeverity(bySeverity) {
        const colorMap = { '重大': '#e74c3c', '重要': '#f39c12', '軽微': '#3498db' };
        this.severityItems = Object.entries(bySeverity).map(([key, value]) => ({
            label: key,
            count: value,
            color: colorMap[key] || '#95a5a6',
            style: `background-color: ${colorMap[key] || '#95a5a6'}`
        }));
    }

    processPhases(byPhase) {
        const totalAll = (this.totalOpen || 0) + (this.totalClosed || 0);
        const phaseOrder = [
            'D1 チーム編成', 'D2 問題定義', 'D3 暫定対応', 'D4 原因分析',
            'D5 恒久対策立案', 'D6 実施・検証', 'D7 再発防止', 'D8 完了'
        ];
        this.phaseItems = phaseOrder.map((phase, idx) => {
            const count = byPhase[phase] || 0;
            const pct = totalAll > 0 ? Math.round((count / totalAll) * 100) : 0;
            const isComplete = phase === 'D8 完了';
            return {
                key: `phase-${idx}`,
                label: phase.substring(0, 2),
                fullLabel: phase,
                count,
                pct,
                barStyle: `width: ${Math.max(pct, 4)}%; background-color: ${isComplete ? '#27ae60' : '#3498db'}`,
                hasItems: count > 0
            };
        });
    }

    processCategories(byCategory) {
        const colorMap = {
            '材料起因': '#e74c3c', '部品不良': '#f39c12', '設計起因': '#9b59b6',
            '製造工程': '#3498db', '外注加工': '#1abc9c', 'その他': '#95a5a6'
        };
        this.categoryItems = Object.entries(byCategory)
            .sort((a, b) => b[1] - a[1])
            .map(([key, value]) => ({
                label: key,
                count: value,
                style: `background-color: ${colorMap[key] || '#95a5a6'}`
            }));
    }

    get hasOverdue() {
        return this.overdueCount > 0;
    }

    get overdueClass() {
        return this.overdueCount > 0 ? 'kpi-card kpi-card--danger' : 'kpi-card';
    }

    get hasCategories() {
        return this.categoryItems.length > 0;
    }
}
