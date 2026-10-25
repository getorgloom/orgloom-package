import { LightningElement, wire } from 'lwc';
import hostConfig from '@salesforce/apex/OrgLoomNativeController.hostConfig';
import { CurrentPageReference } from 'lightning/navigation';

export default class OrgLoomNativeHost extends LightningElement {
    config;
    error;
    jobs = [];
    openCanvas;
    @wire(CurrentPageReference) page(reference) {
        const id=reference?.state?.c__openCanvas;
        this.openCanvas=/^[a-zA-Z0-9]{15,18}$/.test(id||'')?id:null;
    }
    listener = (event) => this.receive(event);
    @wire(hostConfig) configuration({ data, error }) {
        if (data) this.config = data;
        if (error) this.error = error.body?.message || 'Unable to open Org Loom.';
    }
    get source() { return this.config ? this.config.visualforceOrigin + this.config.launchPath + (this.openCanvas ? '?openCanvas='+this.openCanvas : '') : null; }
    connectedCallback() { window.addEventListener('message', this.listener); }
    disconnectedCallback() { window.removeEventListener('message', this.listener); }
    receive(event) {
        const frame = this.template.querySelector('iframe');
        if (!frame || event.source !== frame.contentWindow || event.origin !== this.config?.visualforceOrigin) return;
        const message = event.data;
        if (message?.type === 'orgloom-native-hello') {
            frame.contentWindow.postMessage({type: 'orgloom-native-ready',openCanvas:this.openCanvas}, this.config.visualforceOrigin);return;
        }
        if (message?.type !== 'orgloom-native-layout' || !/^[a-zA-Z0-9_-]{1,80}$/.test(message.id || '')) return;
        const request = message.request;
        if (!request || !/^\w{1,100}$/.test(request.objectApiName || '') || !/^[a-zA-Z0-9]{15,18}$/.test(request.recordTypeId || '') || !['Create', 'Edit', 'View'].includes(request.mode)) return;
        if (this.jobs.some(job => job.id === message.id)) return;
        if (this.jobs.length >= 12) { this.reply(message.id, null, 'Too many layout requests.'); return; }
        this.jobs = [...this.jobs, { id: message.id, objectApiName: request.objectApiName, recordTypeId: request.recordTypeId, mode: request.mode }];
    }
    completed(event) {
        event.stopPropagation();
        const { id, data, error } = event.detail;
        if (!this.jobs.some(job => job.id === id)) return;
        this.jobs = this.jobs.filter(job => job.id !== id);
        this.reply(id, data, error);
    }
    reply(id, data, error) {
        this.template.querySelector('iframe')?.contentWindow.postMessage({ type: 'orgloom-native-layout-result', id, data, error }, this.config.visualforceOrigin);
    }
}
