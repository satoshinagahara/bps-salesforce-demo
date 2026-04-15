import { LightningElement, api, wire } from 'lwc';
import getShowcase from '@salesforce/apex/AssetShowcaseController.getShowcase';

export default class AssetShowcaseGcp extends LightningElement {
    @api recordId;
    data;
    error;

    @wire(getShowcase, { assetId: '$recordId' })
    wired(result) {
        if (result.data) {
            this.data = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error.body?.message || 'Load error';
        }
    }

    get hasData() { return !!this.data; }
    get hasDemoData() { return this.data && this.data.hasDemoData; }
    get hasImage() { return this.data && this.data.imageUrl; }

    get mapMarkers() {
        if (!this.hasDemoData) return [];
        return [{
            location: {
                Latitude: this.data.latitude,
                Longitude: this.data.longitude
            },
            title: this.data.assetName,
            description: this.data.locationLabel,
            icon: 'utility:asset_warranty'
        }];
    }

    get mapCenter() {
        if (!this.hasDemoData) return null;
        return {
            location: {
                Latitude: this.data.latitude,
                Longitude: this.data.longitude
            }
        };
    }

    get iotBadgeClass() {
        return this.data && this.data.iotEnabled ? 'badge badge-on' : 'badge badge-off';
    }
    get iotBadgeText() {
        return this.data && this.data.iotEnabled ? 'IoT連携: ON' : 'IoT連携: OFF';
    }
}
