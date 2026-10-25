import { LightningElement, api, wire } from 'lwc';
import { getLayout } from 'lightning/uiLayoutApi';
export default class OrgLoomNativeLayout extends LightningElement {
    @api request;
    get objectApiName() { return this.request?.objectApiName; }
    get recordTypeId() { return this.request?.recordTypeId; }
    get mode() { return this.request?.mode; }
    @wire(getLayout, { objectApiName: '$objectApiName', recordTypeId: '$recordTypeId', layoutType: 'Full', mode: '$mode' })
    layout({ data, error }) {
        if (!this.request || (!data && !error)) return;
        this.dispatchEvent(new CustomEvent('layoutresult', { detail: { id: this.request.id, data: data ? JSON.parse(JSON.stringify(data)) : null, error: error ? 'Salesforce did not provide a layout for this object and user.' : null } }));
    }
}
