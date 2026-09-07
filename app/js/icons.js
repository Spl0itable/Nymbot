(function () {
    'use strict';

    const NS = 'http://www.w3.org/2000/svg';

    const STROKE = {
        copy: '<rect x="9" y="9" width="12" height="12" rx="2"></rect><path d="M5 15V5a2 2 0 0 1 2-2h10"></path>',
        refresh: '<path d="M21 12a9 9 0 1 1-2.64-6.36"></path><polyline points="21 3 21 9 15 9"></polyline>',
        speaker: '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon><path d="M15.5 8.5a5 5 0 0 1 0 7"></path><path d="M18.5 5.5a9 9 0 0 1 0 13"></path>',
        mute: '<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon><line x1="22" y1="9" x2="16" y2="15"></line><line x1="16" y1="9" x2="22" y2="15"></line>',
        branch: '<line x1="6" y1="3" x2="6" y2="15"></line><circle cx="18" cy="6" r="3"></circle><circle cx="6" cy="18" r="3"></circle><path d="M18 9a9 9 0 0 1-9 9"></path>',
        quote: '<path d="M9 7H5a2 2 0 0 0-2 2v3a2 2 0 0 0 2 2h2v1a3 3 0 0 1-3 3"></path><path d="M19 7h-4a2 2 0 0 0-2 2v3a2 2 0 0 0 2 2h2v1a3 3 0 0 1-3 3"></path>',
        thumbUp: '<path d="M7 21V10l5-7a2 2 0 0 1 3 2l-1 5h5a2 2 0 0 1 2 2.4l-1.4 7A2 2 0 0 1 17.6 21H7Z"></path><rect x="2" y="10" width="5" height="11" rx="1"></rect>',
        thumbDown: '<path d="M17 3v11l-5 7a2 2 0 0 1-3-2l1-5H5a2 2 0 0 1-2-2.4l1.4-7A2 2 0 0 1 6.4 3H17Z"></path><rect x="17" y="3" width="5" height="11" rx="1"></rect>',
        pencil: '<path d="M12 20h9"></path><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"></path>',
        sendAgain: '<path d="M3 11l18-8-8 18-2-7-8-3Z"></path><path d="M21 3 11 13"></path>',
        star: '<polygon points="12 3 14.9 9 21.5 9.8 16.7 14.3 18 20.8 12 17.6 6 20.8 7.3 14.3 2.5 9.8 9.1 9 12 3"></polygon>',
        close: '<line x1="5" y1="5" x2="19" y2="19"></line><line x1="19" y1="5" x2="5" y2="19"></line>',
        check: '<polyline points="4 12.5 9.5 18 20 6.5"></polyline>',
        verified: '<path d="M12 2.5 14.6 5l3.5-.2.5 3.5 2.9 2-1.6 3.2 1.6 3.1-2.9 2-.5 3.5-3.5-.2L12 21.5 9.4 19l-3.5.2-.5-3.5-2.9-2 1.6-3.1L2.5 7.3l2.9-2 .5-3.5L9.4 2 12 2.5Z"></path><polyline points="8.5 12 11 14.5 15.5 9.5"></polyline>',
        thought: '<path d="M7.5 16A4.5 4.5 0 0 1 7 7a5 5 0 0 1 9.6-1.3A4 4 0 0 1 17 16Z"></path><circle cx="6" cy="19" r="1.6"></circle><circle cx="10" cy="21.2" r="1"></circle>',
        bolt: '<polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon>',
        search: '<circle cx="11" cy="11" r="7"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line>',
        tools: '<path d="M14.7 6.3a4 4 0 0 0 5.3 5.3l-8 8a2.8 2.8 0 0 1-4-4Z"></path><path d="m6 6 3 3"></path><path d="M3.5 8.5 8.5 3.5l3 3-2 2-3-3"></path>',
        pen: '<path d="M4 20s2-6 7-11 8-6 8-6 0 3-4 8-11 9-11 9Z"></path><path d="M4 20h6"></path>',
        graduation: '<path d="M12 4 2 9l10 5 10-5-10-5Z"></path><path d="M6 11.5V17c0 1.5 3 3 6 3s6-1.5 6-3v-5.5"></path>',
        chart: '<line x1="3" y1="21" x2="21" y2="21"></line><rect x="5" y="12" width="3.5" height="6"></rect><rect x="10.2" y="7" width="3.5" height="11"></rect><rect x="15.4" y="3.5" width="3.5" height="14.5"></rect>',
        robot: '<rect x="4" y="8" width="16" height="12" rx="2"></rect><path d="M12 4v4"></path><circle cx="12" cy="3" r="1.4"></circle><line x1="9" y1="13" x2="9" y2="14.5"></line><line x1="15" y1="13" x2="15" y2="14.5"></line><line x1="9.5" y1="17" x2="14.5" y2="17"></line>',
        terse: '<line x1="4" y1="8" x2="20" y2="8"></line><line x1="4" y1="12" x2="14" y2="12"></line><line x1="4" y1="16" x2="9" y2="16"></line>',
        person: '<circle cx="12" cy="8" r="4"></circle><path d="M4 21a8 8 0 0 1 16 0"></path>',
        model: '<path d="m12 3-1.9 5.8a2 2 0 0 1-1.3 1.3L3 12l5.8 1.9a2 2 0 0 1 1.3 1.3L12 21l1.9-5.8a2 2 0 0 1 1.3-1.3L21 12l-5.8-1.9a2 2 0 0 1-1.3-1.3Z"></path>',
        globe: '<circle cx="12" cy="12" r="9"></circle><path d="M3 12h18"></path><path d="M12 3a15 15 0 0 1 0 18a15 15 0 0 1 0-18Z"></path>',
        eyeOff: '<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"></path><line x1="3" y1="21" x2="21" y2="3"></line>',
        plus: '<line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line>',
        menu: '<line x1="3" y1="6" x2="21" y2="6"></line><line x1="3" y1="12" x2="21" y2="12"></line><line x1="3" y1="18" x2="21" y2="18"></line>',
        down: '<line x1="12" y1="5" x2="12" y2="19"></line><polyline points="19 12 12 19 5 12"></polyline>',
        up: '<line x1="12" y1="19" x2="12" y2="5"></line><polyline points="5 12 12 5 19 12"></polyline>',
        prompt: '<path d="M4 4h16v12H7l-3 3z"></path>',
        settings: '<circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06A1.65 1.65 0 0 0 15 19.4a1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.6 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.6a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09A1.65 1.65 0 0 0 15 4.6a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9c.14.36.46.62.85.7H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"></path>',
        attach: '<path d="M21.4 11.05 12.25 20.2a5.5 5.5 0 0 1-7.78-7.78l9.2-9.2a3.67 3.67 0 0 1 5.18 5.18l-9.2 9.2a1.83 1.83 0 1 1-2.6-2.6l8.5-8.48"></path>',
        mic: '<rect x="9" y="2" width="6" height="12" rx="3"></rect><path d="M5 11a7 7 0 0 0 14 0"></path><line x1="12" y1="18" x2="12" y2="22"></line>',
        send: '<line x1="22" y1="2" x2="11" y2="13"></line><polygon points="22 2 15 22 11 13 2 9 22 2"></polygon>',
        dot: '<circle cx="12" cy="12" r="5"></circle>',
        circle: '<circle cx="12" cy="12" r="6.5"></circle>',
        wallet: '<path d="M3 7a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2"></path><rect x="3" y="7" width="18" height="13" rx="2"></rect><circle cx="16.5" cy="13.5" r="1.2"></circle>'
    };

    const FILLED = {
        star: '<polygon points="12 3 14.9 9 21.5 9.8 16.7 14.3 18 20.8 12 17.6 6 20.8 7.3 14.3 2.5 9.8 9.1 9 12 3"></polygon>',
        dot: '<circle cx="12" cy="12" r="5"></circle>',
        thumbUp: '<path d="M7 21V10l5-7a2 2 0 0 1 3 2l-1 5h5a2 2 0 0 1 2 2.4l-1.4 7A2 2 0 0 1 17.6 21H7Z"></path><rect x="2" y="10" width="5" height="11" rx="1"></rect>',
        thumbDown: '<path d="M17 3v11l-5 7a2 2 0 0 1-3-2l1-5H5a2 2 0 0 1-2-2.4l1.4-7A2 2 0 0 1 6.4 3H17Z"></path><rect x="17" y="3" width="5" height="11" rx="1"></rect>',
        stop: '<rect x="6" y="6" width="12" height="12" rx="2"></rect>'
    };

    const PERSONA_ICONS = ['tools', 'search', 'pen', 'graduation', 'chart', 'terse', 'robot', 'model', 'person', 'bolt'];

    function markup(name, options) {
        const opts = options || {};
        const size = opts.size || 16;
        const filled = opts.filled && FILLED[name];
        const body = filled || STROKE[name] || STROKE.robot;
        const paint = filled
            ? 'fill="currentColor" stroke="none"'
            : 'fill="none" stroke="currentColor" stroke-width="' + (opts.weight || 2)
                + '" stroke-linecap="round" stroke-linejoin="round"';
        return `<svg class="icon${opts.cls ? ' ' + opts.cls : ''}" viewBox="0 0 24 24" width="${size}" height="${size}" ${paint} aria-hidden="true" focusable="false">${body}</svg>`;
    }

    function node(name, options) {
        const wrap = document.createElement('span');
        wrap.className = 'icon-wrap';
        wrap.innerHTML = markup(name, options);
        const svg = wrap.firstChild;
        wrap.removeChild(svg);
        return svg;
    }

    /// The app's own mark, drawn rather than loaded: a monospace robot head in
    /// the same shapes the icon and the ASCII wordmark use, so the sidebar,
    /// the tab and the avatar are recognisably one thing.
    function wordmark(options) {
        const opts = options || {};
        const size = opts.size || 22;
        const svg = document.createElementNS(NS, 'svg');
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('width', String(size));
        svg.setAttribute('height', String(size));
        svg.setAttribute('fill', 'none');
        svg.setAttribute('stroke', 'currentColor');
        svg.setAttribute('stroke-width', '1.6');
        svg.setAttribute('stroke-linecap', 'square');
        svg.setAttribute('class', 'brand-mark');
        svg.setAttribute('role', 'img');
        svg.innerHTML = [
            '<path d="M8 2.4 9.8 6"></path>',
            '<path d="M16 2.4 14.2 6"></path>',
            '<path d="M3.6 6.6h16.8"></path>',
            '<path d="M2.4 8.6v7"></path>',
            '<path d="M21.6 8.6v7"></path>',
            '<path d="M4.8 8.8v8.6"></path>',
            '<path d="M19.2 8.8v8.6"></path>',
            '<path d="M3.6 19.6h16.8"></path>',
            '<path d="M8.6 9.6H7.4v4.2h1.2"></path>',
            '<path d="M15.4 9.6h1.2v4.2h-1.2"></path>',
            '<path d="m9.2 12.6 1.1-1.8 1.1 1.8"></path>',
            '<path d="m12.6 12.6 1.1-1.8 1.1 1.8"></path>',
            '<path d="M9 16.2h2.2"></path>',
            '<path d="M12.8 16.2H15"></path>'
        ].join('');
        return svg;
    }

    window.NymbotIcons = { markup, node, wordmark, PERSONA_ICONS, names: Object.keys(STROKE) };
})();
