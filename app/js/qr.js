// A byte-mode QR encoder, so a Lightning invoice can be scanned without
// fetching a library or sending the invoice anywhere to be rendered.
(function () {
    'use strict';

    // GF(256) with the QR primitive polynomial 0x11d.
    const EXP = new Uint8Array(512);
    const LOG = new Uint8Array(256);
    for (let i = 0, x = 1; i < 255; i++) {
        EXP[i] = x;
        LOG[x] = i;
        x <<= 1;
        if (x & 0x100) x ^= 0x11d;
    }
    for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];

    const mul = (a, b) => (a === 0 || b === 0) ? 0 : EXP[LOG[a] + LOG[b]];

    function rsGenerator(degree) {
        let poly = [1];
        for (let i = 0; i < degree; i++) {
            const next = new Array(poly.length + 1).fill(0);
            for (let j = 0; j < poly.length; j++) {
                next[j] ^= mul(poly[j], 1);
                next[j + 1] ^= mul(poly[j], EXP[i]);
            }
            poly = next;
        }
        return poly;
    }

    function rsRemainder(data, degree) {
        const gen = rsGenerator(degree);
        const out = new Array(degree).fill(0);
        for (const b of data) {
            const factor = b ^ out[0];
            out.shift();
            out.push(0);
            for (let i = 0; i < degree; i++) out[i] ^= mul(gen[i + 1], factor);
        }
        return out;
    }

    // Per version: [total codewords, ecc codewords per block, block count]
    // for error-correction level L, which is what a one-off payment QR wants.
    const ECC_L = [
        null,
        [26, 7, 1], [44, 10, 1], [70, 15, 1], [100, 20, 1], [134, 26, 1],
        [172, 18, 2], [196, 20, 2], [242, 24, 2], [292, 30, 2], [346, 18, 4],
        [404, 20, 4], [466, 24, 4], [532, 26, 4], [581, 30, 4], [655, 22, 6],
        [733, 24, 6], [815, 28, 6], [901, 30, 6], [991, 28, 7], [1085, 28, 8],
        [1156, 28, 8], [1258, 28, 9], [1364, 30, 9], [1474, 30, 10], [1588, 26, 12],
        [1706, 28, 12], [1828, 30, 12], [1921, 30, 13], [2051, 30, 14], [2185, 30, 15],
        [2323, 30, 16], [2465, 30, 17], [2611, 30, 18], [2761, 30, 19], [2876, 30, 19],
        [3034, 30, 20], [3196, 30, 21], [3362, 30, 22], [3532, 30, 24], [3706, 30, 25]
    ];

    const ALIGN = [
        null, [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42],
        [6, 26, 46], [6, 28, 50], [6, 30, 54], [6, 32, 58], [6, 34, 62], [6, 26, 46, 66],
        [6, 26, 48, 70], [6, 26, 50, 74], [6, 30, 54, 78], [6, 30, 56, 82], [6, 30, 58, 86],
        [6, 34, 62, 90], [6, 28, 50, 72, 94], [6, 26, 50, 74, 98], [6, 30, 54, 78, 102],
        [6, 28, 54, 80, 106], [6, 32, 58, 84, 110], [6, 30, 58, 86, 114], [6, 34, 62, 90, 118],
        [6, 26, 50, 74, 98, 122], [6, 30, 54, 78, 102, 126], [6, 26, 52, 78, 104, 130],
        [6, 30, 56, 82, 108, 134], [6, 34, 60, 86, 112, 138], [6, 30, 58, 86, 114, 142],
        [6, 34, 62, 90, 118, 146], [6, 30, 54, 78, 102, 126, 150], [6, 24, 50, 76, 102, 128, 154],
        [6, 28, 54, 80, 106, 132, 158], [6, 32, 58, 84, 110, 136, 162],
        [6, 26, 54, 82, 110, 138, 166], [6, 30, 58, 86, 114, 142, 170]
    ];

    function capacityBits(version) {
        const [total, eccPerBlock, blocks] = ECC_L[version];
        return (total - eccPerBlock * blocks) * 8;
    }

    function charCountBits(version) {
        return version < 10 ? 8 : 16;
    }

    function pickVersion(byteLen) {
        for (let v = 1; v <= 40; v++) {
            const needed = 4 + charCountBits(v) + byteLen * 8;
            if (needed <= capacityBits(v)) return v;
        }
        throw new Error('too much data for one QR code');
    }

    function encodeData(bytes, version) {
        const bits = [];
        const push = (value, len) => {
            for (let i = len - 1; i >= 0; i--) bits.push((value >> i) & 1);
        };
        push(0b0100, 4);                       // byte mode
        push(bytes.length, charCountBits(version));
        for (const b of bytes) push(b, 8);

        const capacity = capacityBits(version);
        push(0, Math.min(4, capacity - bits.length));
        while (bits.length % 8) bits.push(0);
        const pad = [0xec, 0x11];
        for (let i = 0; bits.length < capacity; i++) push(pad[i % 2], 8);

        const data = new Uint8Array(bits.length / 8);
        for (let i = 0; i < data.length; i++) {
            for (let j = 0; j < 8; j++) data[i] = (data[i] << 1) | bits[i * 8 + j];
        }
        return data;
    }

    function interleave(data, version) {
        const [total, eccPerBlock, blockCount] = ECC_L[version];
        const dataLen = total - eccPerBlock * blockCount;
        const shortLen = Math.floor(dataLen / blockCount);
        const longBlocks = dataLen % blockCount;

        const blocks = [];
        let at = 0;
        for (let i = 0; i < blockCount; i++) {
            const len = shortLen + (i >= blockCount - longBlocks ? 1 : 0);
            const chunk = Array.from(data.slice(at, at + len));
            at += len;
            blocks.push({ data: chunk, ecc: rsRemainder(chunk, eccPerBlock) });
        }

        const out = [];
        const maxData = shortLen + (longBlocks ? 1 : 0);
        for (let i = 0; i < maxData; i++) {
            for (const b of blocks) if (i < b.data.length) out.push(b.data[i]);
        }
        for (let i = 0; i < eccPerBlock; i++) {
            for (const b of blocks) out.push(b.ecc[i]);
        }
        return out;
    }

    function buildMatrix(version) {
        const size = version * 4 + 17;
        const m = Array.from({ length: size }, () => new Int8Array(size).fill(-1));

        const finder = (r, c) => {
            for (let dr = -1; dr <= 7; dr++) {
                for (let dc = -1; dc <= 7; dc++) {
                    const rr = r + dr, cc = c + dc;
                    if (rr < 0 || cc < 0 || rr >= size || cc >= size) continue;
                    const inner = dr >= 0 && dr <= 6 && dc >= 0 && dc <= 6;
                    const on = inner && (dr === 0 || dr === 6 || dc === 0 || dc === 6
                        || (dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4));
                    m[rr][cc] = on ? 1 : 0;
                }
            }
        };
        finder(0, 0);
        finder(0, size - 7);
        finder(size - 7, 0);

        for (let i = 8; i < size - 8; i++) {
            const bit = i % 2 === 0 ? 1 : 0;
            m[6][i] = bit;
            m[i][6] = bit;
        }

        // Every combination except the three that would sit on a finder. The
        // ones crossing the timing pattern are drawn, and overwrite it.
        const centers = ALIGN[version];
        const last = centers.length - 1;
        for (let i = 0; i <= last; i++) {
            for (let j = 0; j <= last; j++) {
                if ((i === 0 && j === 0) || (i === 0 && j === last) || (i === last && j === 0)) continue;
                const r = centers[i], c = centers[j];
                for (let dr = -2; dr <= 2; dr++) {
                    for (let dc = -2; dc <= 2; dc++) {
                        const on = Math.max(Math.abs(dr), Math.abs(dc)) !== 1;
                        m[r + dr][c + dc] = on ? 1 : 0;
                    }
                }
            }
        }

        m[size - 8][8] = 1;   // the always-dark module
        return m;
    }

    function reserveFormat(m, size) {
        const taken = [];
        for (let i = 0; i < 9; i++) {
            if (m[8][i] === -1) { m[8][i] = 0; taken.push([8, i]); }
            if (m[i][8] === -1) { m[i][8] = 0; taken.push([i, 8]); }
        }
        for (let i = size - 8; i < size; i++) {
            if (m[8][i] === -1) { m[8][i] = 0; taken.push([8, i]); }
            if (m[i][8] === -1) { m[i][8] = 0; taken.push([i, 8]); }
        }
        return taken;
    }

    function placeData(m, size, codewords, reserved) {
        const isFree = (r, c) => m[r][c] === -1;
        let bitIndex = 0;
        const nextBit = () => {
            const byte = codewords[bitIndex >> 3];
            const bit = byte === undefined ? 0 : (byte >> (7 - (bitIndex & 7))) & 1;
            bitIndex++;
            return bit;
        };
        let upward = true;
        for (let right = size - 1; right >= 1; right -= 2) {
            if (right === 6) right = 5;
            for (let step = 0; step < size; step++) {
                const row = upward ? size - 1 - step : step;
                for (const col of [right, right - 1]) {
                    if (isFree(row, col)) m[row][col] = nextBit();
                }
            }
            upward = !upward;
        }
        return reserved;
    }

    const MASKS = [
        (r, c) => (r + c) % 2 === 0,
        (r) => r % 2 === 0,
        (r, c) => c % 3 === 0,
        (r, c) => (r + c) % 3 === 0,
        (r, c) => (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0,
        (r, c) => (r * c) % 2 + (r * c) % 3 === 0,
        (r, c) => ((r * c) % 2 + (r * c) % 3) % 2 === 0,
        (r, c) => ((r + c) % 2 + (r * c) % 3) % 2 === 0
    ];

    function formatBits(mask) {
        // ECC level L is 01 in the format string.
        let data = (0b01 << 3) | mask;
        let rem = data;
        for (let i = 0; i < 10; i++) rem = (rem << 1) ^ (((rem >> 9) & 1) * 0x537);
        return ((data << 10) | rem) ^ 0x5412;
    }

    function versionBits(version) {
        let rem = version;
        for (let i = 0; i < 12; i++) rem = (rem << 1) ^ (((rem >> 11) & 1) * 0x1f25);
        return (version << 12) | rem;
    }

    function penalty(m, size) {
        let score = 0;
        const runScore = (line) => {
            let run = 1;
            for (let i = 1; i < line.length; i++) {
                if (line[i] === line[i - 1]) { run++; continue; }
                if (run >= 5) score += 3 + (run - 5);
                run = 1;
            }
            if (run >= 5) score += 3 + (run - 5);
        };
        for (let r = 0; r < size; r++) runScore(m[r]);
        for (let c = 0; c < size; c++) runScore(m.map(row => row[c]));
        for (let r = 0; r < size - 1; r++) {
            for (let c = 0; c < size - 1; c++) {
                const v = m[r][c];
                if (v === m[r][c + 1] && v === m[r + 1][c] && v === m[r + 1][c + 1]) score += 3;
            }
        }
        let dark = 0;
        for (let r = 0; r < size; r++) for (let c = 0; c < size; c++) dark += m[r][c];
        const ratio = Math.abs((dark * 100) / (size * size) - 50);
        score += Math.floor(ratio / 5) * 10;
        return score;
    }

    function applyFormat(m, size, version, mask) {
        const bits = formatBits(mask);
        const get = (i) => (bits >> i) & 1;
        // Column 8 downward, then row 8 leftward — the first copy.
        for (let i = 0; i <= 5; i++) m[i][8] = get(i);
        m[7][8] = get(6);
        m[8][8] = get(7);
        m[8][7] = get(8);
        for (let i = 9; i <= 14; i++) m[8][14 - i] = get(i);
        // Row 8 from the right edge, then column 8 up from the bottom.
        for (let i = 0; i <= 7; i++) m[8][size - 1 - i] = get(i);
        for (let i = 8; i <= 14; i++) m[size - 15 + i][8] = get(i);
        m[size - 8][8] = 1;

        if (version >= 7) {
            const vb = versionBits(version);
            for (let i = 0; i < 18; i++) {
                const bit = (vb >> i) & 1;
                m[Math.floor(i / 3)][size - 11 + (i % 3)] = bit;
                m[size - 11 + (i % 3)][Math.floor(i / 3)] = bit;
            }
        }
    }

    /// Returns { size, modules } where modules[r][c] is 0 or 1.
    function encode(text) {
        const bytes = new TextEncoder().encode(String(text));
        const version = pickVersion(bytes.length);
        const codewords = interleave(encodeData(bytes, version), version);

        const size = version * 4 + 17;
        const base = buildMatrix(version);
        const reserved = reserveFormat(base, size);
        if (version >= 7) {
            for (let i = 0; i < 18; i++) {
                base[Math.floor(i / 3)][size - 11 + (i % 3)] = 0;
                base[size - 11 + (i % 3)][Math.floor(i / 3)] = 0;
                reserved.push([Math.floor(i / 3), size - 11 + (i % 3)]);
                reserved.push([size - 11 + (i % 3), Math.floor(i / 3)]);
            }
        }
        // Function modules are whatever the template already set; everything
        // still -1 is a data module.
        const fixed = base.map(row => Array.from(row, v => v !== -1));
        placeData(base, size, codewords, reserved);

        let best = null;
        for (let mask = 0; mask < 8; mask++) {
            const m = base.map(row => Array.from(row));
            for (let r = 0; r < size; r++) {
                for (let c = 0; c < size; c++) {
                    if (!fixed[r][c] && MASKS[mask](r, c)) m[r][c] ^= 1;
                }
            }
            applyFormat(m, size, version, mask);
            const score = penalty(m, size);
            if (!best || score < best.score) best = { score, modules: m };
        }
        return { size, modules: best.modules };
    }

    /// Paints onto a canvas, sized to fit its current width.
    function draw(canvas, text, opts) {
        const options = opts || {};
        const { size, modules } = encode(text);
        const quiet = options.quiet == null ? 4 : options.quiet;
        const total = size + quiet * 2;
        const scale = Math.max(1, Math.floor((options.width || canvas.width) / total));
        canvas.width = total * scale;
        canvas.height = total * scale;
        const ctx = canvas.getContext('2d');
        ctx.fillStyle = options.light || '#ffffff';
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        ctx.fillStyle = options.dark || '#000000';
        for (let r = 0; r < size; r++) {
            for (let c = 0; c < size; c++) {
                if (modules[r][c]) ctx.fillRect((c + quiet) * scale, (r + quiet) * scale, scale, scale);
            }
        }
    }

    window.NymbotQR = { encode, draw };
})();
