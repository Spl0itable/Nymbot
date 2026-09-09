(function () {
    'use strict';

    const synth = window.speechSynthesis || null;

    const Speech = {
        speakingId: null,
        onSpeakChange: null,

        canSpeak() { return !!synth; },

        voices() {
            if (!synth) return [];
            try { return synth.getVoices() || []; } catch (_) { return []; }
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
