import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getPreviewData from '@salesforce/apex/DesignSuggestionGcpController.getPreviewData';
import getLatestSuggestion from '@salesforce/apex/DesignSuggestionGcpController.getLatestSuggestion';
import generateDesignSuggestionAgent from '@salesforce/apex/DesignSuggestionGcpController.generateDesignSuggestionAgent';

const STEPS = [
    { key: 1, label: 'Salesforce から施策情報・紐付くニーズを取得' },
    { key: 2, label: 'BigQuery Vector Search で関連仕様書セクションを検索' },
    { key: 3, label: 'Vertex AI Gemini が検索結果を解釈し設計改善提案を生成' },
    { key: 4, label: '製品改善提案を Salesforce へ書き戻し' }
];

// ライブ生成のタイムアウト（ms）。これを超えるとキャッシュにサイレントフォールバック。
// 直近の正常完走は 18〜34s（n=9）、中央値 26s。45s は最大値+11s のバッファで
// Vertex AI のレイテンシ揺れを許容しつつ、観客視点でも自然な待ち時間に収まる。
const WATCHDOG_MS = 45000;

export default class DesignSuggestionGcpV2 extends LightningElement {
    @api recordId;

    preview;
    result;
    error;
    isGenerating = false;
    showResult = false;
    fromCache = false;
    currentStep = 0;
    steps = STEPS;
    _wiredLatest;

    @wire(getPreviewData, { initiativeId: '$recordId' })
    wiredPreview({ data, error }) {
        if (data) {
            this.preview = data;
            this.error = undefined;
        } else if (error) {
            this.error = error.body?.message || 'プレビューデータの取得に失敗しました';
        }
    }

    @wire(getLatestSuggestion, { initiativeId: '$recordId' })
    wiredLatest(result) {
        // キャッシュは初期表示には使わず、watchdog タイムアウト時の
        // サイレントフォールバック用にだけ保持する。エラーは無視（デモ動作の妨げにしない）。
        this._wiredLatest = result;
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

    get specTitle() {
        const product = this.preview?.productName || '';
        return product ? `${product} 製品仕様書` : '製品仕様書';
    }

    get hasReferenceUrls() {
        return this.result && (this.result.specUrl || this.result.diagramUrl);
    }

    get hasToolHistory() {
        return this.result && this.result.toolHistory && this.result.toolHistory.length > 0;
    }

    get toolHistoryDisplay() {
        if (!this.hasToolHistory) return [];
        return this.result.toolHistory.map((t, i) => ({
            key: 't-' + i,
            num: i + 1,
            tool: t.tool,
            args: t.args,
            resultSummary: t.resultSummary,
            elapsedSec: t.elapsedSec
        }));
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

    get cachedLabel() {
        if (!this.fromCache || !this.result?.generatedAt) return '';
        return `cached ${this.result.generatedAt}`;
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
        this.error = undefined;
        this.currentStep = 1;

        const stepTimer = setInterval(() => {
            if (this.currentStep < 3) {
                this.currentStep++;
            }
        }, 1500);

        // ライブ呼出と watchdog を競争させる。
        // ライブが先に解決/失敗すれば通常フロー、watchdog が先に発火すればキャッシュにフォールバック。
        // ライブPromiseは never-reject 形にラップしておき、watchdog 勝利後に到着しても unhandled rejection が出ないようにする。
        const livePromise = generateDesignSuggestionAgent({ initiativeId: this.recordId })
            .then(r => ({ kind: 'live', result: r }))
            .catch(err => ({ kind: 'error', err }));
        const watchdog = this._delay(WATCHDOG_MS).then(() => ({ kind: 'timeout' }));

        const winner = await Promise.race([livePromise, watchdog]);

        if (winner.kind === 'live') {
            // ライブ生成成功 → 新規結果を表示
            clearInterval(stepTimer);
            this.currentStep = 4;
            await this._delay(600);
            this.currentStep = 5;
            this.result = winner.result;
            this.fromCache = false;
            await this._delay(300);
            this.showResult = true;
            if (this._wiredLatest) {
                refreshApex(this._wiredLatest);
            }
        } else if (winner.kind === 'timeout') {
            // watchdog 発火 → キャッシュにサイレントフォールバック
            clearInterval(stepTimer);
            this.currentStep = 4;
            await this._delay(600);
            this.currentStep = 5;
            const cached = this._wiredLatest?.data;
            if (cached) {
                this.result = cached;
                this.fromCache = true;
                await this._delay(300);
                this.showResult = true;
            } else {
                this.currentStep = 0;
                this.error = '生成に時間がかかっています。後ほど再度お試しください';
            }
        } else {
            // ライブ呼出が watchdog より先に失敗 → キャッシュがあればフォールバック
            clearInterval(stepTimer);
            const cached = this._wiredLatest?.data;
            if (cached) {
                this.currentStep = 4;
                await this._delay(600);
                this.currentStep = 5;
                this.result = cached;
                this.fromCache = true;
                await this._delay(300);
                this.showResult = true;
            } else {
                this.currentStep = 0;
                this.error = winner.err?.body?.message || 'GCP連携でエラーが発生しました';
            }
        }

        this.isGenerating = false;
    }

    _delay(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }
}
