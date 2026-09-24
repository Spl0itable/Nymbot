(function () {
    'use strict';

    const COMMAND = /^\s*\?(?:image|imagine)\b([\s\S]*)$/i;

    function hasPicture(attachments) {
        return (attachments || []).some(a => a && a.kind === 'image');
    }

    function typedCommand(text) {
        const m = COMMAND.exec(String(text || ''));
        if (!m) return null;
        const rest = m[1].replace(/(?:^|\s)(?:--model|-m)[\s=]+\S+/i, ' ').trim();
        if (/^models?$/i.test(rest)) return null;
        return { rest };
    }

    function pinnedImage(media) {
        return !!(media && media.kind === 'image' && media.command);
    }

    function editing(text, attachments, media) {
        if (!hasPicture(attachments)) return false;
        const raw = String(text || '').trim();
        if (typedCommand(raw)) return true;
        if (/^[?!@]/.test(raw)) return false;
        return pinnedImage(media);
    }

    function instruction(text) {
        const typed = typedCommand(text);
        return typed ? typed.rest : String(text || '').trim();
    }

    function hint() {
        return t('Describe how to change the picture');
    }

    window.NymbotPicEdit = { hasPicture, typedCommand, pinnedImage, editing, instruction, hint };
})();
