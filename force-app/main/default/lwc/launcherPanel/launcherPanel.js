import { LightningElement, wire } from 'lwc';
import getItems from '@salesforce/apex/LauncherController.getItems';
import { NavigationMixin } from 'lightning/navigation';

export default class LauncherPanel extends NavigationMixin(LightningElement) {
    items = [];
    error;
    _searchTerm = '';
    _collapsedCategories = new Set();

    get searchTerm() {
        return this._searchTerm;
    }

    @wire(getItems)
    wiredItems({ error, data }) {
        if (data) {
            this.items = data;
            this.error = undefined;
        } else if (error) {
            this.error = error.body?.message || 'Failed to load launcher items';
            this.items = [];
        }
    }

    get categories() {
        const filtered = this._searchTerm
            ? this.items.filter(item =>
                item.Name.toLowerCase().includes(this._searchTerm.toLowerCase()) ||
                (item.Description__c && item.Description__c.toLowerCase().includes(this._searchTerm.toLowerCase())) ||
                (item.Category__c && item.Category__c.toLowerCase().includes(this._searchTerm.toLowerCase()))
            )
            : this.items;

        const map = new Map();
        filtered.forEach(item => {
            const cat = item.Category__c || 'その他';
            if (!map.has(cat)) {
                map.set(cat, []);
            }
            map.get(cat).push({
                ...item,
                key: item.Id
            });
        });

        return Array.from(map.entries()).map(([name, items]) => ({
            name,
            items,
            isCollapsed: this._collapsedCategories.has(name),
            chevronClass: this._collapsedCategories.has(name) ? 'chevron collapsed' : 'chevron',
            sectionClass: this._collapsedCategories.has(name) ? 'button-grid hidden' : 'button-grid'
        }));
    }

    get hasItems() {
        return this.categories.length > 0;
    }

    get noResults() {
        return this._searchTerm && this.categories.length === 0;
    }

    handleSearch(event) {
        this._searchTerm = event.target.value;
    }

    toggleCategory(event) {
        const cat = event.currentTarget.dataset.category;
        if (this._collapsedCategories.has(cat)) {
            this._collapsedCategories.delete(cat);
        } else {
            this._collapsedCategories.add(cat);
        }
        this._collapsedCategories = new Set(this._collapsedCategories);
    }

    handleClick(event) {
        const itemId = event.currentTarget.dataset.id;
        const item = this.items.find(i => i.Id === itemId);
        if (!item) return;

        const url = item.Link__c;

        if (item.Open_In_New_Tab__c) {
            window.open(url, '_blank');
            return;
        }

        if (url.startsWith('/')) {
            this[NavigationMixin.Navigate]({
                type: 'standard__webPage',
                attributes: { url }
            });
        } else {
            window.open(url, '_blank');
        }
    }
}
