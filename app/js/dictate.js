(function () {
    'use strict';

    const MAX_MS = 120000;
    const MAX_AUDIO_CHARS = 4 * 1024 * 1024;
    const TYPES = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus', 'audio/ogg'];

    function supported() {
        return !!(window.isSecureContext !== false
            && navigator.mediaDevices
            && typeof navigator.mediaDevices.getUserMedia === 'function'
            && typeof window.MediaRecorder === 'function');
    }

    function pickType() {
        const Rec = window.MediaRecorder;
        if (!Rec || typeof Rec.isTypeSupported !== 'function') return '';
        return TYPES.find(type => {
            try { return Rec.isTypeSupported(type); } catch (_) { return false; }
        }) || '';
    }

    async function toDataUrl(blob) {
        const bytes = new Uint8Array(await blob.arrayBuffer());
        let binary = '';
        for (let i = 0; i < bytes.length; i += 0x8000) {
            binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
        }
        return 'data:' + (blob.type || 'audio/webm') + ';base64,' + btoa(binary);
    }

    const Dictate = {
        MAX_MS,
        MAX_AUDIO_CHARS,
        state: 'idle',
        onLimit: null,
        _recorder: null,
        _stream: null,
        _chunks: [],
        _started: 0,
        _limit: null,
        _done: null,

        supported,
        toDataUrl,

        recording() { return this.state === 'recording'; },

        elapsed() { return this.state === 'recording' ? Date.now() - this._started : 0; },

        async start() {
            if (this.state !== 'idle') return false;
            if (!supported()) throw Object.assign(new Error('unsupported'), { name: 'NotSupportedError' });
            this.state = 'starting';
            let stream;
            try {
                stream = await navigator.mediaDevices.getUserMedia({ audio: true });
            } catch (e) {
                this.state = 'idle';
                throw e;
            }
            const type = pickType();
            let recorder;
            try {
                recorder = type ? new MediaRecorder(stream, { mimeType: type }) : new MediaRecorder(stream);
            } catch (e) {
                for (const track of stream.getTracks()) track.stop();
                this.state = 'idle';
                throw e;
            }
            this._stream = stream;
            this._recorder = recorder;
            this._chunks = [];
            recorder.addEventListener('dataavailable', (e) => {
                if (e.data && e.data.size) this._chunks.push(e.data);
            });
            recorder.addEventListener('stop', () => {
                if (this._recorder !== recorder) return;
                const blob = this._chunks.length
                    ? new Blob(this._chunks, { type: recorder.mimeType || type || 'audio/webm' })
                    : null;
                const done = this._done;
                this._done = null;
                this.release();
                if (done) done(blob);
            });
            recorder.start(1000);
            this._started = Date.now();
            this.state = 'recording';
            this._limit = setTimeout(() => {
                if (this.state === 'recording' && typeof this.onLimit === 'function') this.onLimit();
            }, MAX_MS);
            return true;
        },

        stop() {
            if (this.state !== 'recording' || !this._recorder) return Promise.resolve(null);
            this.state = 'stopping';
            return new Promise((resolve) => {
                this._done = resolve;
                try { this._recorder.stop(); } catch (_) {
                    this._done = null;
                    this.release();
                    resolve(null);
                }
            });
        },

        cancel() {
            if (!this._recorder) {
                this.release();
                return;
            }
            this._done = null;
            this._chunks = [];
            try { this._recorder.stop(); } catch (_) { }
            this.release();
        },

        release() {
            clearTimeout(this._limit);
            this._limit = null;
            if (this._stream) {
                for (const track of this._stream.getTracks()) {
                    try { track.stop(); } catch (_) { }
                }
            }
            this._stream = null;
            this._recorder = null;
            this.state = 'idle';
        }
    };

    window.NymbotDictate = Dictate;
})();
