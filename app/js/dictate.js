(function () {
    'use strict';

    const MAX_MS = 120000;
    const MAX_AUDIO_CHARS = 4 * 1024 * 1024;
    const TYPES = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus', 'audio/ogg'];
    const SAMPLE_MS = 50;
    const HISTORY = 64;
    const FLOOR_DB = -60;
    const SOUND_LEVEL = 0.1;
    const MIN_SAMPLES = 10;

    function levelOf(rms) {
        if (!(rms > 0)) return 0;
        const db = 20 * Math.log10(rms);
        return Math.max(0, Math.min(1, (db - FLOOR_DB) / -FLOOR_DB));
    }

    function makeMeter(stream) {
        const Ctx = window.AudioContext || window.webkitAudioContext;
        if (typeof Ctx !== 'function') return null;
        let ctx = null;
        try {
            ctx = new Ctx();
            const source = ctx.createMediaStreamSource(stream);
            const analyser = ctx.createAnalyser();
            analyser.fftSize = 1024;
            source.connect(analyser);
            if (ctx.state === 'suspended' && typeof ctx.resume === 'function') {
                Promise.resolve(ctx.resume()).catch(() => { });
            }
            const floats = typeof analyser.getFloatTimeDomainData === 'function'
                ? new Float32Array(analyser.fftSize) : null;
            const bytes = floats ? null : new Uint8Array(analyser.fftSize);
            return {
                ctx,
                source,
                read() {
                    if (ctx.state !== 'running') return null;
                    let sum = 0;
                    if (floats) {
                        analyser.getFloatTimeDomainData(floats);
                        for (let i = 0; i < floats.length; i++) sum += floats[i] * floats[i];
                        return levelOf(Math.sqrt(sum / floats.length));
                    }
                    analyser.getByteTimeDomainData(bytes);
                    for (let i = 0; i < bytes.length; i++) {
                        const v = (bytes[i] - 128) / 128;
                        sum += v * v;
                    }
                    return levelOf(Math.sqrt(sum / bytes.length));
                },
                close() {
                    try { source.disconnect(); } catch (_) { }
                    try { Promise.resolve(ctx.close()).catch(() => { }); } catch (_) { }
                }
            };
        } catch (_) {
            if (ctx) {
                try { Promise.resolve(ctx.close()).catch(() => { }); } catch (_) { }
            }
            return null;
        }
    }

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
        HINT_MS: 3000,
        SOUND_LEVEL,
        state: 'idle',
        onLimit: null,
        _recorder: null,
        _stream: null,
        _chunks: [],
        _started: 0,
        _limit: null,
        _done: null,
        _meter: null,
        _sampler: null,
        _levels: [],
        _samples: 0,
        _heard: false,
        duration: 0,
        silent: false,

        supported,
        levelOf,
        toDataUrl,

        recording() { return this.state === 'recording'; },

        elapsed() { return this.state === 'recording' ? Date.now() - this._started : 0; },

        metering() { return !!this._meter && this._samples >= MIN_SAMPLES; },

        levels() { return this._levels.slice(); },

        level() { return this._levels.length ? this._levels[this._levels.length - 1] : 0; },

        heard() { return this._heard; },

        noSound() {
            return this.state === 'recording' && !this._heard && this.metering() && this.elapsed() >= this.HINT_MS;
        },

        silentClip(ms) {
            if (this._heard || !this._meter) return false;
            return this._samples >= MIN_SAMPLES && this._samples * SAMPLE_MS >= ms * 0.5;
        },

        sample() {
            if (!this._meter) return;
            let level = null;
            try { level = this._meter.read(); } catch (_) { level = null; }
            if (level === null || !isFinite(level)) return;
            this._samples++;
            if (level >= SOUND_LEVEL) this._heard = true;
            this._levels.push(level);
            if (this._levels.length > HISTORY) this._levels.shift();
        },

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
            this._levels = [];
            this._samples = 0;
            this._heard = false;
            this.silent = false;
            this.duration = 0;
            this._meter = makeMeter(stream);
            if (this._meter) this._sampler = setInterval(() => this.sample(), SAMPLE_MS);
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
            this.duration = Date.now() - this._started;
            this.silent = this.silentClip(this.duration);
            this.stopMeter();
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

        stopMeter() {
            clearInterval(this._sampler);
            this._sampler = null;
            if (this._meter) this._meter.close();
            this._meter = null;
        },

        release() {
            clearTimeout(this._limit);
            this._limit = null;
            this.stopMeter();
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
