(function () {
    'use strict';

    const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition || null;
    const synth = window.speechSynthesis || null;

    // Chrome's Web Speech API is not on the device: it streams the audio to
    // Google and hands back text.
    const canRecord = !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia
        && window.MediaRecorder);
    // Long enough for a paragraph, short enough that a forgotten recording is not
    // a four-minute upload.
    const RECORD_MAX_MS = 120000;

    function pickMime() {
        if (!window.MediaRecorder || !MediaRecorder.isTypeSupported) return '';
        for (const type of ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg']) {
            if (MediaRecorder.isTypeSupported(type)) return type;
        }
        return '';
    }

    function base64Of(blob) {
        return new Promise((resolve, reject) => {
            const r = new FileReader();
            r.onload = () => {
                const out = String(r.result || '');
                const at = out.indexOf(',');
                resolve(at === -1 ? out : out.slice(at + 1));
            };
            r.onerror = () => reject(new Error('unreadable'));
            r.readAsDataURL(blob);
        });
    }

    const Speech = {
        listening: false,
        speakingId: null,
        onListenChange: null,
        onListenError: null,
        onSpeakChange: null,
        onTranscript: null,
        /// Called when dictation switches to recording, so the button can say
        /// that the text arrives when you stop rather than as you speak.
        onListenMode: null,
        _recogniser: null,
        _recorder: null,
        _stream: null,
        _chunks: null,
        _recordTimer: null,
        /// Set once the live service has failed on this device: a second attempt
        /// would fail the same way, so it goes straight to recording.
        _liveIsDead: false,

        canListen() { return !!Recognition || canRecord; },

        _failed(code) {
            const why = this.reasonFor(code);
            if (why && this.onListenError) this.onListenError(why, code);
        },

        /// Why dictation stopped, in words a reader can act on. Every one of
        /// these used to end as a button that turned itself off again with
        /// nothing said, which is indistinguishable from a broken button.
        reasonFor(code) {
            switch (code) {
                case 'not-allowed':
                case 'service-not-allowed':
                    return t('Dictation needs permission to use the microphone. Allow it in the site settings and try again.');
                case 'audio-capture':
                    return t('No microphone was found.');
                case 'network':
                    return t('Dictation could not reach the speech service. It needs a connection.');
                case 'no-speech':
                    return t('Nothing was heard.');
                case 'aborted':
                    return '';
                case 'busy':
                    return t('The microphone is still busy from the last time. Try again in a moment.');
                case 'insecure':
                    return t('Dictation only works over a secure connection (https).');
                case 'unsupported':
                    return t('This browser cannot record audio, so dictation is not available here.');
                default:
                    return t('Dictation stopped unexpectedly.');
            }
        },
        canSpeak() { return !!synth; },

        voices() {
            if (!synth) return [];
            try { return synth.getVoices() || []; } catch (_) { return []; }
        },

        startListening(lang) {
            if (this.listening) return false;
            // Chrome refuses on an insecure origin without ever firing an
            // error, so the button appears to do nothing at all. Say so first.
            if (window.isSecureContext === false) {
                this._failed('insecure');
                return false;
            }
            if (!Recognition || this._liveIsDead) {
                if (!canRecord) { this._failed('unsupported'); return false; }
                this.startRecording();
                return true;
            }
            const r = new Recognition();
            r.lang = lang || document.documentElement.lang || 'en-US';
            r.continuous = true;
            r.interimResults = true;
            r.maxAlternatives = 1;

            let settled = '';
            r.onresult = (e) => {
                let interim = '';
                for (let i = e.resultIndex; i < e.results.length; i++) {
                    const chunk = e.results[i][0].transcript;
                    if (e.results[i].isFinal) settled += chunk;
                    else interim += chunk;
                }
                if (this.onTranscript) this.onTranscript(settled + interim, settled);
            };
            r.onerror = (e) => {
                const code = (e && e.error) || 'unknown';
                // "network" means the browser could not reach its own speech
                // service, which no amount of retrying fixes.
                if ((code === 'network' || code === 'service-not-allowed') && canRecord) {
                    this._liveIsDead = true;
                    this._recogniser = null;
                    try { r.abort(); } catch (_) { }
                    this.startRecording();
                    return;
                }
                this._failed(code);
                this.stopListening();
            };
            r.onend = () => {
                this.listening = false;
                this._recogniser = null;
                if (this.onListenChange) this.onListenChange(false);
            };

            this._recogniser = r;
            this.listening = true;
            if (this.onListenChange) this.onListenChange(true);
            try {
                r.start();
            } catch (_) {
                // Chrome throws here when a previous session has not finished
                // releasing the microphone. Silence made that look like a dead
                // button; saying so at least explains the wait.
                this._failed('busy');
                this.stopListening();
                return false;
            }
            return true;
        },

        stopListening() {
            const r = this._recogniser;
            this._recogniser = null;
            if (this._recorder) { this.stopRecording(); return; }
            this.listening = false;
            if (r) { try { r.stop(); } catch (_) { } }
            if (this.onListenChange) this.onListenChange(false);
        },

        // --- recording, where the live service cannot be reached -------------

        /// Records until it is stopped, then sends the clip to be transcribed.
        async startRecording() {
            if (this._recorder || !canRecord) return false;
            let stream;
            try {
                stream = await navigator.mediaDevices.getUserMedia({ audio: true });
            } catch (e) {
                this._failed((e && e.name === 'NotFoundError') ? 'audio-capture' : 'not-allowed');
                return false;
            }
            const mime = pickMime();
            let recorder;
            try {
                recorder = new MediaRecorder(stream, mime ? { mimeType: mime } : undefined);
            } catch (_) {
                stream.getTracks().forEach(tr => tr.stop());
                this._failed('unsupported');
                return false;
            }
            this._chunks = [];
            this._stream = stream;
            this._recorder = recorder;
            this.listening = true;
            recorder.ondataavailable = (e) => {
                if (e.data && e.data.size) this._chunks.push(e.data);
            };
            recorder.onstop = () => { this._finishRecording(mime); };
            try {
                recorder.start();
            } catch (_) {
                this._releaseRecorder();
                this._failed('busy');
                return false;
            }
            // A recording nobody stopped is a microphone left open, so it stops
            // itself and transcribes what it has.
            this._recordTimer = setTimeout(() => this.stopRecording(), RECORD_MAX_MS);
            if (this.onListenChange) this.onListenChange(true);
            if (this.onListenMode) this.onListenMode('recording');
            return true;
        },

        stopRecording() {
            const recorder = this._recorder;
            if (!recorder) return;
            clearTimeout(this._recordTimer);
            this._recordTimer = null;
            try { recorder.stop(); } catch (_) { this._releaseRecorder(); }
        },

        _releaseRecorder() {
            clearTimeout(this._recordTimer);
            this._recordTimer = null;
            if (this._stream) {
                try { this._stream.getTracks().forEach(tr => tr.stop()); } catch (_) { }
            }
            this._stream = null;
            this._recorder = null;
            this._chunks = null;
            this.listening = false;
        },

        async _finishRecording(mime) {
            const chunks = this._chunks || [];
            this._releaseRecorder();
            if (this.onListenChange) this.onListenChange(false);
            if (this.onListenMode) this.onListenMode(null);
            const blob = new Blob(chunks, { type: mime || 'audio/webm' });
            if (blob.size < 2048) { this._failed('no-speech'); return; }
            if (this.onListenMode) this.onListenMode('transcribing');
            let said = '';
            try {
                const audio = await base64Of(blob);
                const { data } = await window.NymbotApi.transcribe(audio, { signer: this.signer || null });
                if (data && data.error) throw new Error(data.error);
                said = String((data && data.text) || '').trim();
            } catch (e) {
                if (this.onListenMode) this.onListenMode(null);
                if (this.onListenError) {
                    this.onListenError((e && e.message) || t('That clip could not be transcribed.'), 'transcribe');
                }
                return;
            }
            if (this.onListenMode) this.onListenMode(null);
            if (!said) { this._failed('no-speech'); return; }
            if (this.onTranscript) this.onTranscript(said, said);
        },

        toggleListening(lang) {
            if (this.listening) { this.stopListening(); return false; }
            return this.startListening(lang);
        },

        speak(id, text, options) {
            if (!synth) return false;
            const opts = options || {};
            this.stopSpeaking();
            const clean = String(text || '')
                .replace(/```[\s\S]*?```/g, ' code block ')
                .replace(/`([^`]+)`/g, '$1')
                .replace(/!\[[^\]]*\]\([^)]*\)/g, ' image ')
                .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
                .replace(/[#*_>|~]/g, '')
                .replace(/\s+/g, ' ')
                .trim();
            if (!clean) return false;
            const u = new SpeechSynthesisUtterance(clean);
            u.rate = opts.rate || 1;
            u.pitch = opts.pitch || 1;
            if (opts.voiceUri) {
                const voice = this.voices().find(v => v.voiceURI === opts.voiceUri);
                if (voice) u.voice = voice;
            }
            u.onend = u.onerror = () => {
                this.speakingId = null;
                if (this.onSpeakChange) this.onSpeakChange(null);
            };
            this.speakingId = id;
            if (this.onSpeakChange) this.onSpeakChange(id);
            try { synth.speak(u); } catch (_) { this.speakingId = null; return false; }
            return true;
        },

        stopSpeaking() {
            if (!synth) return;
            try { synth.cancel(); } catch (_) { }
            if (this.speakingId !== null) {
                this.speakingId = null;
                if (this.onSpeakChange) this.onSpeakChange(null);
            }
        },

        toggleSpeak(id, text, options) {
            if (this.speakingId === id) { this.stopSpeaking(); return false; }
            return this.speak(id, text, options);
        }
    };

    window.NymbotSpeech = Speech;
})();
