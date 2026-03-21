import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import analyzeSurvey from '@salesforce/apex/CampaignSurveyAnalysisAction.analyzeCampaignSurveyLwc';
import SENTIMENT_FIELD from '@salesforce/schema/Campaign.Survey_Sentiment__c';
import KEY_FINDINGS_FIELD from '@salesforce/schema/Campaign.Survey_Key_Findings__c';
import IMPROVEMENTS_FIELD from '@salesforce/schema/Campaign.Survey_Improvements__c';
import ANALYZED_DATE_FIELD from '@salesforce/schema/Campaign.Survey_Analyzed_Date__c';

const FIELDS = [SENTIMENT_FIELD, KEY_FINDINGS_FIELD, IMPROVEMENTS_FIELD, ANALYZED_DATE_FIELD];

export default class CampaignSurveyAnalysis extends LightningElement {
    @api recordId;
    isLoading = false;
    errorMessage = null;
    wiredCampaignResult;

    // Apex実行後の結果（一時表示用）
    _sentiment = null;
    _keyFindings = null;
    _improvements = null;
    _justAnalyzed = false;

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredCampaign(result) {
        this.wiredCampaignResult = result;
    }

    get sentiment() {
        if (this._justAnalyzed) return this._sentiment;
        return this.wiredCampaignResult?.data ? getFieldValue(this.wiredCampaignResult.data, SENTIMENT_FIELD) : null;
    }

    get keyFindings() {
        if (this._justAnalyzed) return this._keyFindings;
        return this.wiredCampaignResult?.data ? getFieldValue(this.wiredCampaignResult.data, KEY_FINDINGS_FIELD) : null;
    }

    get improvements() {
        if (this._justAnalyzed) return this._improvements;
        return this.wiredCampaignResult?.data ? getFieldValue(this.wiredCampaignResult.data, IMPROVEMENTS_FIELD) : null;
    }

    get hasResults() {
        return this.sentiment != null;
    }

    get keyFindingsHtml() {
        return this.markdownToHtml(this.keyFindings);
    }

    get improvementsHtml() {
        return this.markdownToHtml(this.improvements);
    }

    markdownToHtml(text) {
        if (!text) return '';
        return text
            .replace(/^## (.+)$/gm, '<p><strong>$1</strong></p>')
            .replace(/^• (.+)$/gm, '<li>$1</li>')
            .replace(/(<li>[\s\S]*?<\/li>)/g, '<ul>$1</ul>')
            .replace(/\n/g, '<br/>');
    }

    async handleAnalyze() {
        this.isLoading = true;
        this.errorMessage = null;
        this._justAnalyzed = false;
        try {
            const r = await analyzeSurvey({ campaignId: this.recordId });
            if (r.errorMessage) {
                this.errorMessage = r.errorMessage;
            } else {
                this._sentiment = r.sentiment;
                this._keyFindings = r.keyFindings;
                this._improvements = r.improvements;
                this._justAnalyzed = true;
                // キャンペーンレコードのキャッシュを更新
                await refreshApex(this.wiredCampaignResult);
            }
        } catch (error) {
            this.errorMessage = error.body ? error.body.message : error.message;
        } finally {
            this.isLoading = false;
        }
    }
}
