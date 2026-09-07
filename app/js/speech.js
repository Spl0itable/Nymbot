(function () {
    'use strict';

    const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition || null;
    const synth = window.speechSynthesis || null;

    const Speech = {
        listening: false,
        speakingId: null,
        onListenChange: null,
        onListenError: null,
        onSpeakChange: null,
        onTranscript: null,
        _recogniser: null,

        canListen() { return !!Recognition; },

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
            if (!Recognition || this.listening) return false;
            // Chrome refuses on an insecure origin without ever firing an
            // error, so the button appears to do nothing at all. Say so first.
            if (window.isSecureContext === false) {
                this._failed('insecure');
                return false;
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
                this._failed((e && e.error) || 'unknown');
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
            this.listening = false;
            if (r) { try { r.stop(); } catch (_) { } }
            if (this.onListenChange) this.onListenChange(false);
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
