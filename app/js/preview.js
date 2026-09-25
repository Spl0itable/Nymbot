(function () {
    'use strict';

    const origin = new URL(location.href).origin;

    function onMessage(e) {
        if (e.source !== window.parent || e.origin !== origin) return;
        const d = e.data || {};
        if (d.type !== 'nymbot-preview' || typeof d.html !== 'string') return;
        window.removeEventListener('message', onMessage);
        document.open();
        document.write(d.html);
        document.close();
    }

    window.addEventListener('message', onMessage);
    window.parent.postMessage({ type: 'nymbot-preview-ready' }, origin);
})();
