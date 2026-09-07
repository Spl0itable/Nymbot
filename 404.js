// 404.html's only script, and the only page that loads it. A file rather than
// an inline script so the page is served under `script-src 'self'` like the
// rest of the site — see `_headers`.
//
// Everything here is a progressive enhancement: with scripting off the page
// still renders, still explains itself, and still links onward.
(function () {
    // One of these replaces the default line on each load, so a mistyped link
    // is at least a different joke the second time.
    var QUIPS = [
        'Nothing here is stored, logged, or found. Two of those are on purpose.',
        'That page was ephemeral. Aggressively ephemeral.',
        'No relay has ever heard of this URL.',
        "You've reached geohash nowhere. Population: you.",
        'This link was gift-wrapped to absolutely nobody.',
        'We asked the mesh. The mesh said no.',
        'Even Nymbot has no idea what this is, and Nymbot has an idea about everything.',
        '404 nyms are typing. None of them exist.',
        'Delivered to /dev/null with end-to-end encryption.',
        'This page guarded its privacy so well that we lost it too.'
    ];

    var quip = document.getElementById('nfQuip');
    if (quip) quip.textContent = QUIPS[Math.floor(Math.random() * QUIPS.length)];

    // Show what was actually asked for. textContent, never innerHTML: the path
    // is attacker-controlled by definition — anyone can link to anything here.
    var path = document.getElementById('nfPath');
    if (path) {
        var asked = location.pathname + location.search;
        if (asked.length > 48) asked = asked.slice(0, 47) + '…';
        path.textContent = asked;
    }
})();
