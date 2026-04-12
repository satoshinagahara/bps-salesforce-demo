import { LightningElement, api, wire } from 'lwc';
import getPreviewData from '@salesforce/apex/DesignSuggestionGcpController.getPreviewData';
import generateDesignSuggestion from '@salesforce/apex/DesignSuggestionGcpController.generateDesignSuggestion';

const STEPS = [
    { key: 1, label: 'Salesforce → GCP へ施策・ニーズ情報を送信' },
    { key: 2, label: 'Cloud Storage から仕様書PDF・図面を取得' },
    { key: 3, label: 'Vertex AI Gemini マルチモーダル処理中' },
    { key: 4, label: '製品改善提案を Salesforce へ書き戻し' }
];

export default class DesignSuggestionGcp extends LightningElement {
    @api recordId;

    preview;
    result;
    error;
    isGenerating = false;
    showResult = false;
    currentStep = 0;
    steps = STEPS;

    @wire(getPreviewData, { initiativeId: '$recordId' })
    wiredPreview({ data, error }) {
        if (data) {
            this.preview = data;
            this.error = undefined;
        } else if (error) {
            this.error = error.body?.message || 'プレビューデータの取得に失敗しました';
        }
    }

    get hasPreview() {
        return !!this.preview;
    }

    get hasResult() {
        return this.showResult && !!this.result;
    }

    get hasError() {
        return !!this.error;
    }

    get hasLinkedNeeds() {
        return this.preview?.linkedNeeds?.length > 0;
    }

    get needsCount() {
        return this.preview?.linkedNeeds?.length || 0;
    }

    get hasReferenceUrls() {
        return this.result && (this.result.specUrl || this.result.diagramUrl);
    }

    get buttonDisabled() {
        return this.isGenerating || !this.hasPreview;
    }

    get buttonLabel() {
        return this.isGenerating ? '処理中...' : 'GCP 製品改善提案を生成';
    }

    get priorityClass() {
        if (!this.result) return '';
        const p = this.result.priority;
        if (p === '高') return 'priority-high';
        if (p === '中') return 'priority-medium';
        return 'priority-low';
    }

    get stepsWithStatus() {
        return this.steps.map(s => ({
            ...s,
            isDone: s.key < this.currentStep,
            isCurrent: s.key === this.currentStep,
            isPending: s.key > this.currentStep,
            stepClass: `step ${s.key < this.currentStep ? 'step-done' : ''} ${s.key === this.currentStep ? 'step-current' : ''} ${s.key > this.currentStep ? 'step-pending' : ''}`
        }));
    }

    async handleGenerate() {
        this.isGenerating = true;
        this.showResult = false;
        this.result = null;
        this.error = undefined;
        this.currentStep = 1;

        const stepTimer = setInterval(() => {
            if (this.currentStep < 3) {
                this.currentStep++;
            }
        }, 1500);

        try {
            const result = await generateDesignSuggestion({ initiativeId: this.recordId });
            clearInterval(stepTimer);
            this.currentStep = 4;

            await this._delay(600);
            this.currentStep = 5;
            this.result = result;

            await this._delay(300);
            this.showResult = true;
        } catch (err) {
            clearInterval(stepTimer);
            this.currentStep = 0;
            this.error = err.body?.message || 'GCP連携でエラーが発生しました';
        } finally {
            this.isGenerating = false;
        }
    }

    _delay(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }
}
