import { LightningElement, wire } from 'lwc';
import hostConfig from '@salesforce/apex/OrgLoomNativeController.hostConfig';
import { CurrentPageReference } from 'lightning/navigation';

export default class OrgLoomNativeHost extends LightningElement {
    config;
    error;
    jobs = [];
    openCanvas;
    viewportHeight;
    resizeFrame;
    resizeObserver;
    resizeListener = () => this.scheduleResize();
    get viewportStyle() { return this.viewportHeight === undefined ? '' : 'height:'+this.viewportHeight+'px'; }
    scheduleResize() {
        if (this.resizeFrame !== undefined) return;
        this.resizeFrame = window.requestAnimationFrame(() => {
            this.resizeFrame = undefined;
            const frame = this.template.querySelector('iframe');
            if (!frame) return;
            // Lightning navigation/header sizes vary with the shell and zoom level.
            const viewport = window.visualViewport;
            const bottom = viewport ? viewport.offsetTop + viewport.height : window.innerHeight;
            // Measure in the unscrolled shell: using the current screen position
            // would enlarge the iframe every time an overflowing ancestor scrolls.
            let top = frame.getBoundingClientRect().top + (window.scrollY || 0);
            let gutter = 0;
            let availableBottom = bottom;
            const ancestors = [];
            let element = (this.hostElement || this.template.host)?.parentElement;
            while (element && element !== document.documentElement) {
                ancestors.push(element);
                if (element !== document.scrollingElement) top += element.scrollTop || 0;
                element = element.parentElement || element.getRootNode?.().host;
            }
            let outerScroll = window.scrollY || 0;
            for (const ancestor of ancestors.reverse()) {
                const style = window.getComputedStyle(ancestor);
                const pixels = value => parseFloat(value) || 0;
                // A Lightning workspace can end above the window (for example,
                // above a utility bar). Respect that scroll container as well.
                if (/^(auto|scroll|hidden|clip)$/.test(style.overflowY) && ancestor.clientHeight) {
                    availableBottom = Math.min(availableBottom,
                        ancestor.getBoundingClientRect().top + outerScroll + ancestor.clientTop + ancestor.clientHeight);
                }
                gutter += pixels(style.paddingBottom) + pixels(style.marginBottom) + pixels(style.borderBottomWidth);
                if (ancestor !== document.scrollingElement) outerScroll += ancestor.scrollTop || 0;
            }
            const height = Math.max(0, Math.floor(availableBottom - top - gutter));
            if (height !== this.viewportHeight) this.viewportHeight = height;
        });
    }
    renderedCallback() {
        if (!this.resizeObserver && typeof ResizeObserver !== 'undefined') {
            const parent = (this.hostElement || this.template.host)?.parentElement;
            if (parent) {
                this.resizeObserver = new ResizeObserver(this.resizeListener);
                this.resizeObserver.observe(parent);
            }
        }
        this.scheduleResize();
    }
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
    connectedCallback() {
        window.addEventListener('message', this.listener);
        window.addEventListener('resize', this.resizeListener);
        window.addEventListener('scroll', this.resizeListener, true);
        window.visualViewport?.addEventListener('resize', this.resizeListener);
    }
    disconnectedCallback() {
        window.removeEventListener('message', this.listener);
        window.removeEventListener('resize', this.resizeListener);
        window.removeEventListener('scroll', this.resizeListener, true);
        window.visualViewport?.removeEventListener('resize', this.resizeListener);
        if (this.resizeFrame !== undefined) window.cancelAnimationFrame(this.resizeFrame);
        this.resizeFrame = undefined;
        this.resizeObserver?.disconnect();
        this.resizeObserver = undefined;
    }
    frameLoaded() {
        this.scheduleResize();
        this.send({type:'orgloom-native-ready',openCanvas:this.openCanvas});
    }
    receive(event) {
        const frame = this.template.querySelector('iframe');
        if (!frame || event.source !== frame.contentWindow || event.origin !== this.config?.visualforceOrigin) return;
        let message = event.data;
        if (typeof message === 'string') {
            try { message = JSON.parse(message); } catch { return; }
        }
        if (message?.type === 'orgloom-native-hello') {
            this.frameLoaded();return;
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
        this.send({ type: 'orgloom-native-layout-result', id, data, error });
    }
    send(message) {
        // Do not pass LWC/Locker proxy objects to cross-origin structured clone.
        this.template.querySelector('iframe')?.contentWindow.postMessage(JSON.stringify(message), this.config.visualforceOrigin);
    }
}
