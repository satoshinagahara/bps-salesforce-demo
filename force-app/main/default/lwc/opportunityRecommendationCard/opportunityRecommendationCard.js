import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

export default class OpportunityRecommendationCard extends NavigationMixin(LightningElement) {
    @api recommendation;
    @api index;

    todoCreated = false;

    get cardNumber() {
        return (this.index || 0) + 1;
    }

    get hasSource() {
        return this.recommendation?.sourceOpportunityName;
    }

    navigateToSource() {
        if (this.recommendation?.sourceOpportunityId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.recommendation.sourceOpportunityId,
                    objectApiName: 'Opportunity',
                    actionName: 'view'
                }
            });
        }
    }

    handleCreateTodo() {
        const subject = this.recommendation.title;
        const description = this.recommendation.actions?.join('\n• ') || '';
        this.dispatchEvent(new CustomEvent('createtodo', {
            detail: {
                subject: subject,
                description: '• ' + description
            }
        }));
        this.todoCreated = true;
    }
}
