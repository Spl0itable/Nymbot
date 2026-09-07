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
        verified: '<circle cx="12" cy="12" r="9"></circle><polyline points="8.2 12.3 10.8 14.9 15.8 9.4"></polyline>',
        thought: '<path d="M7.5 16A4.5 4.5 0 0 1 7 7a5 5 0 0 1 9.6-1.3A4 4 0 0 1 17 16Z"></path><circle cx="6" cy="19" r="1.6"></circle><circle cx="10" cy="21.2" r="1"></circle>',
        bolt: '<polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon>',
        more: '<circle cx="12" cy="5" r="1.8"></circle><circle cx="12" cy="12" r="1.8"></circle><circle cx="12" cy="19" r="1.8"></circle>',
        memory: '<path d="M12 5.2a2.6 2.6 0 0 0-4.9-1.2A2.7 2.7 0 0 0 4.2 7a2.7 2.7 0 0 0-.6 4.3 2.8 2.8 0 0 0 .9 4.3A2.9 2.9 0 0 0 9 19.6a3 3 0 0 0 3-2.3Z"></path><path d="M12 5.2a2.6 2.6 0 0 1 4.9-1.2A2.7 2.7 0 0 1 19.8 7a2.7 2.7 0 0 1 .6 4.3 2.8 2.8 0 0 1-.9 4.3A2.9 2.9 0 0 1 15 19.6a3 3 0 0 1-3-2.3Z"></path><path d="M8.2 8.6c1.4.2 2.5 1.2 2.8 2.6"></path><path d="M15.8 8.6c-1.4.2-2.5 1.2-2.8 2.6"></path>',
        search: '<circle cx="11" cy="11" r="7"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line>',
        tools: '<path d="M14.8 6.4a1.1 1.1 0 0 0 0 1.6l1.6 1.6a1.1 1.1 0 0 0 1.6 0l3.2-3.2a5.8 5.8 0 0 1-7.7 7.7l-6.7 6.7a2.2 2.2 0 0 1-3-3l6.7-6.7a5.8 5.8 0 0 1 7.7-7.7l-3.4 3Z"></path>',
        pen: '<path d="M4 20s2-6 7-11 8-6 8-6 0 3-4 8-11 9-11 9Z"></path><path d="M4 20h6"></path>',
        graduation: '<path d="M12 4 2 9l10 5 10-5-10-5Z"></path><path d="M6 11.5V17c0 1.5 3 3 6 3s6-1.5 6-3v-5.5"></path>',
        chart: '<line x1="3" y1="21" x2="21" y2="21"></line><rect x="5" y="12" width="3.5" height="6"></rect><rect x="10.2" y="7" width="3.5" height="11"></rect><rect x="15.4" y="3.5" width="3.5" height="14.5"></rect>',
        robot: '<rect x="4" y="8" width="16" height="12" rx="2"></rect><path d="M12 4v4"></path><circle cx="12" cy="3" r="1.4"></circle><line x1="9" y1="13" x2="9" y2="14.5"></line><line x1="15" y1="13" x2="15" y2="14.5"></line><line x1="9.5" y1="17" x2="14.5" y2="17"></line>',
        terse: '<line x1="4" y1="8" x2="20" y2="8"></line><line x1="4" y1="12" x2="14" y2="12"></line><line x1="4" y1="16" x2="9" y2="16"></line>',
        person: '<circle cx="12" cy="8" r="4"></circle><path d="M4 21a8 8 0 0 1 16 0"></path>',
        code: '<polyline points="8.5 8 4 12 8.5 16"></polyline><polyline points="15.5 8 20 12 15.5 16"></polyline><line x1="13.6" y1="5.5" x2="10.4" y2="18.5"></line>',
        flask: '<line x1="8" y1="3" x2="16" y2="3"></line><path d="M9 3v6.4L4.8 16.8A2 2 0 0 0 6.5 20h11a2 2 0 0 0 1.7-3.2L15 9.4V3"></path><line x1="7.3" y1="14.4" x2="16.7" y2="14.4"></line>',
        scale: '<line x1="12" y1="4.5" x2="12" y2="20"></line><line x1="8" y1="20" x2="16" y2="20"></line><line x1="4" y1="7.5" x2="20" y2="7.5"></line><path d="M4 7.5 1.6 12.8a2.9 2.9 0 0 0 4.8 0Z"></path><path d="M20 7.5l-2.4 5.3a2.9 2.9 0 0 0 4.8 0Z"></path>',
        compass: '<circle cx="12" cy="12" r="9"></circle><polygon points="16 8 13.4 13.4 8 16 10.6 10.6"></polygon>',
        lightbulb: '<path d="M12 3a6 6 0 0 0-3.6 10.8c.7.5 1.1 1.3 1.1 2.2h5c0-.9.4-1.7 1.1-2.2A6 6 0 0 0 12 3Z"></path><line x1="9.6" y1="18.6" x2="14.4" y2="18.6"></line><line x1="10.6" y1="21" x2="13.4" y2="21"></line>',
        globe: '<circle cx="12" cy="12" r="9"></circle><line x1="3" y1="12" x2="21" y2="12"></line><path d="M12 3a15 15 0 0 1 0 18a15 15 0 0 1 0-18Z"></path>',
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
        wallet: '<path d="M3 7a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2"></path><rect x="3" y="7" width="18" height="13" rx="2"></rect><circle cx="16.5" cy="13.5" r="1.2"></circle>',
        link: '<path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"></path><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"></path>'
    };

    const FILLED = {
        star: '<polygon points="12 3 14.9 9 21.5 9.8 16.7 14.3 18 20.8 12 17.6 6 20.8 7.3 14.3 2.5 9.8 9.1 9 12 3"></polygon>',
        dot: '<circle cx="12" cy="12" r="5"></circle>',
        thumbUp: '<path d="M7 21V10l5-7a2 2 0 0 1 3 2l-1 5h5a2 2 0 0 1 2 2.4l-1.4 7A2 2 0 0 1 17.6 21H7Z"></path><rect x="2" y="10" width="5" height="11" rx="1"></rect>',
        thumbDown: '<path d="M17 3v11l-5 7a2 2 0 0 1-3-2l1-5H5a2 2 0 0 1-2-2.4l1.4-7A2 2 0 0 1 6.4 3H17Z"></path><rect x="17" y="3" width="5" height="11" rx="1"></rect>',
        stop: '<rect x="6" y="6" width="12" height="12" rx="2"></rect>',
        more: '<circle cx="12" cy="5" r="1.8"></circle><circle cx="12" cy="12" r="1.8"></circle><circle cx="12" cy="19" r="1.8"></circle>'
    };

    const PERSONA_ICONS = ['tools', 'code', 'search', 'pen', 'graduation', 'chart', 'flask',
        'scale', 'compass', 'lightbulb', 'globe', 'terse', 'robot', 'model', 'person', 'bolt'];

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

    /// The app icon, drawn rather than loaded, traced off images/nymbot-icon.png at 700x700 and divided
    /// by 29.1667 into a 24-unit box, so the sidebar, the tab and the avatar
    /// are the same drawing rather than three impressions of it.
    const MARK = [
        '<path d="M7.96 1.37 9.57 5.07"></path>',
        '<path d="M15.98 1.37 14.40 5.07"></path>',
        '<path d="M3.87 5.98H20.09"></path>',
        '<path d="M2.76 6.41v1.99"></path>',
        '<path d="M2.76 9.57v4.69"></path>',
        '<path d="M2.76 15.40v4.62"></path>',
        '<path d="M21.20 6.41v1.99"></path>',
        '<path d="M21.20 9.57v4.69"></path>',
        '<path d="M21.20 15.40v4.62"></path>',
        '<path d="M6.79 9.32H5.85v3.85h0.94"></path>',
        '<path d="M17.18 9.32h0.94v3.85h-0.94"></path>',
        '<path d="m8.16 11.31 0.94-2.05 0.95 2.05"></path>',
        '<path d="m13.92 11.31 1.01-2.05 1.01 2.05"></path>',
        '<path d="M8.33 16.05h2.06"></path>',
        '<path d="M10.94 16.05h2.09"></path>',
        '<path d="M13.58 16.05h2.06"></path>',
        '<path d="M8.33 17.01h2.06"></path>',
        '<path d="M10.94 17.01h2.09"></path>',
        '<path d="M13.58 17.01h2.06"></path>',
        '<path d="M3.87 20.47H20.09"></path>'
    ].join('');

    function wordmark(options) {
        const opts = options || {};
        const size = opts.size || 24;
        const svg = document.createElementNS(NS, 'svg');
        svg.setAttribute('viewBox', '0 0 24 24');
        svg.setAttribute('width', String(size));
        svg.setAttribute('height', String(size));
        svg.setAttribute('fill', 'none');
        svg.setAttribute('stroke', 'currentColor');
        // The artwork's own strokes are 16/700 of the canvas, which is under a
        // pixel at this size. Widened just enough to survive it; every
        // coordinate below is the measured one.
        svg.setAttribute('stroke-width', '1');
        svg.setAttribute('stroke-linecap', 'butt');
        svg.setAttribute('stroke-linejoin', 'miter');
        svg.setAttribute('class', 'brand-mark');
        svg.setAttribute('role', 'img');
        svg.innerHTML = MARK;
        return svg;
    }

    window.NymbotIcons = { markup, node, wordmark, MARK, PERSONA_ICONS, names: Object.keys(STROKE) };
})();
