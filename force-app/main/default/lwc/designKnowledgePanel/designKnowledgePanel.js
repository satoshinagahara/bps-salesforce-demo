import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getRelatedKnowledge from '@salesforce/apex/DesignKnowledgeController.getRelatedKnowledge';

export default class DesignKnowledgePanel extends NavigationMixin(LightningElement) {
    @api recordId;
    articles = [];
    error;
    isLoading = true;
    hasArticles = false;

    @wire(getRelatedKnowledge, { designProjectId: '$recordId' })
    wiredKnowledge({ data, error }) {
        this.isLoading = false;
        if (data) {
            this.articles = data.map((art, idx) => ({
                ...art,
                index: idx + 1,
                categoryClass: 'category-badge category--' + this.categoryKey(art.category),
                scoreClass: 'score-indicator score--' + this.scoreLevel(art.relevanceScore),
                scoreLabel: this.scoreLabel(art.relevanceScore),
                statusLabel: art.publishStatus === 'Online' ? '公開中' : 'ドラフト',
                statusClass: art.publishStatus === 'Online' ? 'status-badge status--online' : 'status-badge status--draft'
            }));
            this.hasArticles = this.articles.length > 0;
            this.error = undefined;
        } else if (error) {
            this.error = error.body ? error.body.message : error.message;
            this.articles = [];
            this.hasArticles = false;
        }
    }

    categoryKey(category) {
        const map = {
            '電子部品': 'electronic', '樹脂材料': 'resin', '金属部品': 'metal',
            '化学材料': 'chemical', '組立工程': 'assembly', '検査工程': 'inspection', 'その他': 'other'
        };
        return map[category] || 'other';
    }

    scoreLevel(score) {
        if (score >= 7) return 'high';
        if (score >= 4) return 'medium';
        return 'low';
    }

    scoreLabel(score) {
        if (score >= 7) return '高';
        if (score >= 4) return '中';
        return '低';
    }

    handleArticleClick(event) {
        const articleId = event.currentTarget.dataset.id;
        // Knowledge__kavのKnowledgeArticleIdではなくIdで遷移
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: articleId,
                objectApiName: 'Knowledge__kav',
                actionName: 'view'
            }
        });
    }
}
