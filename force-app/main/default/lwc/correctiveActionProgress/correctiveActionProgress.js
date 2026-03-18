import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getCorrectiveActionsForCase from '@salesforce/apex/CorrectiveActionProgressController.getCorrectiveActionsForCase';

const PHASES = [
    { label: 'D1', full: 'チーム編成' },
    { label: 'D2', full: '問題定義' },
    { label: 'D3', full: '暫定対応' },
    { label: 'D4', full: '原因分析' },
    { label: 'D5', full: '恒久対策立案' },
    { label: 'D6', full: '実施・検証' },
    { label: 'D7', full: '再発防止' },
    { label: 'D8', full: '完了' }
];

export default class CorrectiveActionProgress extends NavigationMixin(LightningElement) {
    @api recordId;
    correctiveActions = [];
    error;
    isLoading = true;

    @wire(getCorrectiveActionsForCase, { caseId: '$recordId' })
    wiredCAs({ error, data }) {
        this.isLoading = false;
        if (data) {
            this.correctiveActions = data.map(ca => this.enrichCA(ca));
            this.error = undefined;
        } else if (error) {
            this.error = error;
            this.correctiveActions = [];
        }
    }

    enrichCA(ca) {
        const phases = PHASES.map((p, idx) => {
            const phaseNum = idx + 1;
            let stepClass = 'phase-step';
            if (phaseNum < ca.phaseIndex) {
                stepClass += ' phase-completed';
            } else if (phaseNum === ca.phaseIndex) {
                stepClass += ' phase-current';
            } else {
                stepClass += ' phase-future';
            }
            return {
                key: p.label,
                label: p.label,
                full: p.full,
                stepClass
            };
        });

        const investigations = (ca.investigations || []).map(si => ({
            ...si,
            supplierName: si.record.Supplier__r ? si.record.Supplier__r.Name : '',
            statusBadgeClass: 'si-badge ' + si.statusClass,
            overdueLabel: si.isOverdue ? '期限超過' : ''
        }));

        return {
            ...ca,
            id: ca.record.Id,
            name: ca.record.Name,
            title: ca.record.Title__c,
            phase: ca.record.Phase__c,
            severity: ca.record.Severity__c,
            category: ca.record.Category__c,
            productName: ca.record.Product__r ? ca.record.Product__r.Name : '',
            partName: ca.record.BOM_Part__r
                ? ca.record.BOM_Part__r.Part_Number__c + ' ' + ca.record.BOM_Part__r.Part_Name__c
                : '',
            supplierName: ca.record.Supplier__r ? ca.record.Supplier__r.Name : '',
            teamLeadName: ca.record.Team_Lead__r ? ca.record.Team_Lead__r.Name : '',
            targetCloseDate: ca.record.Target_Close_Date__c,
            actualCloseDate: ca.record.Actual_Close_Date__c,
            impactScope: ca.record.Impact_Scope__c,
            phases,
            investigations,
            hasInvestigations: investigations.length > 0,
            isCompleted: ca.phaseIndex === 8,
            progressBarStyle: 'width:' + ca.progressPercent + '%',
            severityBadgeClass: 'severity-badge ' + ca.severityClass
        };
    }

    get hasData() {
        return this.correctiveActions.length > 0;
    }

    get cardTitle() {
        const count = this.correctiveActions.length;
        return '是正処置（8D） — ' + count + '件';
    }

    handleNavigateToCA(event) {
        const caId = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: caId,
                objectApiName: 'Corrective_Action__c',
                actionName: 'view'
            }
        });
    }

    handleNavigateToSI(event) {
        const siId = event.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: siId,
                objectApiName: 'Supplier_Investigation__c',
                actionName: 'view'
            }
        });
    }
}
