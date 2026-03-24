import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

export default class OpportunitySimilarOppBadge extends NavigationMixin(LightningElement) {
    @api opp;

    navigateToRecord() {
        if (this.opp?.id) {
            this[NavigationMixin.Navigate]({
                type: 'standard__recordPage',
                attributes: {
                    recordId: this.opp.id,
                    objectApiName: 'Opportunity',
                    actionName: 'view'
                }
            });
        }
    }
}
