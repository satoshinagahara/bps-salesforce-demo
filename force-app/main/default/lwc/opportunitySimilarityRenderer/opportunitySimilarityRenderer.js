import { LightningElement, api } from 'lwc';

export default class OpportunitySimilarityRenderer extends LightningElement {
    @api data;

    showInsights = false;

    get userQuery() {
        return this.data?.userQuery || '';
    }

    get reportText() {
        return this.data?.reportText || '';
    }

    get currentOpportunity() {
        try {
            return this.data?.currentOpportunityJson
                ? JSON.parse(this.data.currentOpportunityJson)
                : {};
        } catch (e) {
            return {};
        }
    }

    get similarOpportunities() {
        try {
            const opps = this.data?.similarOpportunitiesJson
                ? JSON.parse(this.data.similarOpportunitiesJson)
                : [];
            return opps.map(opp => ({
                ...opp,
                cardClass: 'slds-box slds-box_x-small slds-theme_default card-item' +
                           (opp.isWon ? ' card-won' : '')
            }));
        } catch (e) {
            return [];
        }
    }

    get hasSimilarOpps() {
        return this.similarOpportunities.length > 0;
    }

    get similarCount() {
        return `${this.similarOpportunities.length}件の類似商談`;
    }

    get insightsIcon() {
        return this.showInsights ? 'utility:chevrondown' : 'utility:chevronright';
    }

    get insightsToggleLabel() {
        return this.showInsights ? '（閉じる）' : '（詳細を表示）';
    }

    get reportSections() {
        if (!this.reportText) return [];
        const lines = this.reportText.split('\n');
        const sections = [];
        let idx = 0;
        let currentParagraph = '';

        const flushParagraph = () => {
            if (currentParagraph.trim()) {
                sections.push({
                    key: 'p' + idx++,
                    isHeading: false,
                    isSubHeading: false,
                    isParagraph: true,
                    text: currentParagraph.trim().replace(/\*\*/g, '')
                });
                currentParagraph = '';
            }
        };

        for (const line of lines) {
            const trimmed = line.trim();
            if (!trimmed) {
                flushParagraph();
                continue;
            }
            if (trimmed.startsWith('## ') || trimmed.startsWith('# ')) {
                flushParagraph();
                sections.push({
                    key: 'h' + idx++,
                    isHeading: true,
                    isSubHeading: false,
                    isParagraph: false,
                    text: trimmed.replace(/^#+\s*/, '')
                });
            } else if (trimmed.startsWith('### ')) {
                flushParagraph();
                sections.push({
                    key: 'sh' + idx++,
                    isHeading: false,
                    isSubHeading: true,
                    isParagraph: false,
                    text: trimmed.replace(/^#+\s*/, '')
                });
            } else {
                currentParagraph += (currentParagraph ? ' ' : '') + trimmed;
            }
        }
        flushParagraph();
        return sections;
    }

    toggleInsights() {
        this.showInsights = !this.showInsights;
    }
}
