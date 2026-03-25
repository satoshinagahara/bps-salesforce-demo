import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getInputStatus from '@salesforce/apex/OpportunitySimilarityController.getInputStatus';
import searchAndAnalyze from '@salesforce/apex/OpportunitySimilarityController.searchAndAnalyze';
import createTodoFromRecommendation from '@salesforce/apex/OpportunitySimilarityController.createTodoFromRecommendation';

export default class OpportunitySimilarityPanel extends LightningElement {
    @api recordId;

    userQuery = '';
    isLoading = false;
    error = null;
    analysisResult = null;
    inputStatus = null;

    // --- 入力状況の取得（パネル表示時） ---

    @wire(getInputStatus, { opportunityId: '$recordId' })
    wiredInputStatus({ error, data }) {
        if (data) {
            this.inputStatus = JSON.parse(data);
        } else if (error) {
            console.error('Input status error:', error);
        }
    }

    // --- 入力状況の表示 ---

    get summaryLabel() { return this.inputStatus?.hasSummaryCard ? '✅' : '❌'; }
    get descLabel() { return this.inputStatus?.hasDescription ? '✅' : '❌'; }
    get productLabel() {
        const c = this.inputStatus?.productCount || 0;
        return c > 0 ? `✅${c}件` : '❌0件';
    }
    get activityLabel() {
        const c = this.inputStatus?.activityCount || 0;
        if (c === 0) return '❌0件';
        if (c < 3) return `⚠️${c}件`;
        return `✅${c}件`;
    }
    get meetingLabel() {
        const c = this.inputStatus?.meetingCount || 0;
        return c > 0 ? `✅${c}件` : '❌0件';
    }

    get summaryBadgeClass() {
        return 'status-badge ' + (this.inputStatus?.hasSummaryCard ? 'status-ok' : 'status-ng');
    }
    get descBadgeClass() {
        return 'status-badge ' + (this.inputStatus?.hasDescription ? 'status-ok' : 'status-ng');
    }
    get productBadgeClass() {
        const c = this.inputStatus?.productCount || 0;
        return 'status-badge ' + (c > 0 ? 'status-ok' : 'status-ng');
    }
    get activityBadgeClass() {
        const c = this.inputStatus?.activityCount || 0;
        if (c === 0) return 'status-badge status-ng';
        if (c < 3) return 'status-badge status-warn';
        return 'status-badge status-ok';
    }
    get meetingBadgeClass() {
        const c = this.inputStatus?.meetingCount || 0;
        return 'status-badge ' + (c > 0 ? 'status-ok' : 'status-ng');
    }

    get confidenceScore() { return this.inputStatus?.confidenceScore || 1; }
    get confidenceDots() {
        const score = this.confidenceScore;
        return '●'.repeat(score) + '○'.repeat(5 - score);
    }
    get confidenceTooltip() {
        const labels = ['', '低い', 'やや低い', '中程度', '高い', '非常に高い'];
        return labels[this.confidenceScore] || '';
    }
    get confidenceContainerClass() {
        return 'confidence-container slds-p-around_x-small slds-m-bottom_x-small ' +
            (this.confidenceScore <= 2 ? 'confidence-low' : 'confidence-ok');
    }
    get showWarning() { return this.confidenceScore <= 2; }
    get warningMessage() {
        if (!this.inputStatus?.hasDescription) {
            return 'Descriptionと活動を充実させると、より精度の高い示唆が得られます';
        }
        return '活動記録を追加すると分析精度が向上します';
    }

    // --- 質問入力と分析実行 ---

    handleQueryChange(event) {
        this.userQuery = event.target.value;
    }

    handleKeyUp() {
        // 入力中の変更検知のみ（Enterでの即実行は行わない）
    }

    get isAnalyzeDisabled() {
        return this.isLoading || !this.userQuery.trim();
    }

    get hasResults() {
        return this.analysisResult && !this.isLoading && !this.error;
    }

    get hasRecommendations() {
        return this.analysisResult?.recommendations?.length > 0;
    }

    get hasRisks() {
        return this.analysisResult?.risks?.length > 0;
    }

    get hasSimilarOpps() {
        return this.analysisResult?.similarOpportunities?.length > 0;
    }

    get similarSectionLabel() {
        const count = this.analysisResult?.similarOpportunities?.length || 0;
        return `参照した類似商談（${count}件）`;
    }

    get showInitialState() {
        return !this.isLoading && !this.error && !this.analysisResult;
    }

    async handleAnalyze() {
        if (!this.userQuery.trim()) return;

        this.isLoading = true;
        this.error = null;
        this.analysisResult = null;

        try {
            const resultJson = await searchAndAnalyze({
                opportunityId: this.recordId,
                userQuery: this.userQuery.trim()
            });

            // JSON文字列をパース（LLMがコードブロックで囲む場合の対応）
            let cleaned = resultJson.trim();
            if (cleaned.startsWith('```')) {
                cleaned = cleaned.replace(/^```json?\n?/, '').replace(/\n?```$/, '');
            }

            this.analysisResult = JSON.parse(cleaned);
        } catch (err) {
            console.error('Analysis error:', err);
            this.error = err.body?.message || err.message || '分析中にエラーが発生しました';
        } finally {
            this.isLoading = false;
        }
    }

    // --- ToDo作成 ---

    async handleCreateTodo(event) {
        const { subject, description } = event.detail;

        try {
            await createTodoFromRecommendation({
                opportunityId: this.recordId,
                subject: subject,
                description: description
            });

            this.dispatchEvent(new ShowToastEvent({
                title: 'ToDo作成完了',
                message: `「${subject}」をToDoとして作成しました`,
                variant: 'success'
            }));
        } catch (err) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'エラー',
                message: err.body?.message || 'ToDo作成に失敗しました',
                variant: 'error'
            }));
        }
    }
}
