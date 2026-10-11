/**
 * @description QR Code encoder (ISO/IEC 18004), byte mode, error correction L/M/Q/H, versions 1-40.
 * Follows the structure of Project Nayuki's reference QR generator: data bits, Reed-Solomon ECC per
 * block, interleaving, function patterns, codeword placement, and the mask with the lowest penalty.
 *
 * Cost: Apex charges per statement, so the hot paths avoid per-bit work.
 * Data codewords are packed a byte at a time, Reed-Solomon uses log/exp tables, and the eight mask
 * penalties are scored on rows and columns packed into Longs (48 modules a word), because every mask
 * is periodic (6 modules across, 12 down) and so is a single word pattern per row or column.
 */
public inherited sharing class SDocsQrEncoder {
    public class QrException extends Exception {
    }

    // Index [ecl][version]; ecl order L, M, Q, H. Version 0 is unused.
    private static final List<List<Integer>> ECC_CODEWORDS_PER_BLOCK = new List<List<Integer>>{
        new List<Integer>{ -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
        new List<Integer>{ -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
        new List<Integer>{ -1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
        new List<Integer>{ -1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 }
    };
    private static final List<List<Integer>> NUM_ERROR_CORRECTION_BLOCKS = new List<List<Integer>>{
        new List<Integer>{ -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 },
        new List<Integer>{ -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 },
        new List<Integer>{ -1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
        new List<Integer>{ -1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 }
    };
    private static final List<String> LEVEL_NAMES = new List<String>{ 'L', 'M', 'Q', 'H' };

    // Packed mask scoring: modules per Long word, and the complement mask (Apex has no unary ~).
    private static final Integer WORD = 48;
    private static final Long ALL = -1L;
    private static final Long M1 = 6148914691236517205L; // 0x5555555555555555
    private static final Long M2 = 3689348814741910323L; // 0x3333333333333333
    private static final Long M4 = 1085102592571150095L; // 0x0F0F0F0F0F0F0F0F
    private static List<Integer> gfExp;
    private static List<Integer> gfLog;
    private static List<List<Long>> rowPatterns;
    private static List<List<Long>> colPatterns;
    private static final List<Integer> FORMAT_BITS = new List<Integer>{ 1, 0, 3, 2 };

    private final Integer version;
    private final Integer size;
    private final Integer ecl;
    private List<Boolean> modules;
    private List<Boolean> isFunction;
    /** Indexes of the format-information modules, recorded by drawFormatBits when not null. */
    private List<Integer> formatCells;

    private SDocsQrEncoder(Integer version, Integer ecl) {
        this.version = version;
        this.ecl = ecl;
        this.size = version * 4 + 17;
        this.modules = new List<Boolean>();
        this.isFunction = new List<Boolean>();
        for (Integer i = 0; i < this.size * this.size; i++) {
            this.modules.add(false);
            this.isFunction.add(false);
        }
    }

    /**
     * @description Encodes UTF-8 text in byte mode with the smallest version that fits.
     * @param text text to encode
     * @param level 'L', 'M', 'Q' or 'H'
     * @return module grid [row][column], true = dark, without quiet zone
     */
    public static List<List<Boolean>> encode(String text, String level) {
        SDocsQrEncoder qr = prepare(text, level);
        qr.build();
        return qr.grid();
    }

    /** Picks the version, then draws the function patterns and the data and ECC codewords (no mask yet). */
    private static SDocsQrEncoder prepare(String text, String level) {
        Integer ecl = eclIndex(level);
        List<Integer> bytes = utf8Bytes(text);
        Integer version = -1;
        for (Integer v = 1; v <= 40; v++) {
            if (bytes.size() <= capacity(v, ecl)) {
                version = v;
                break;
            }
        }
        if (version < 0) {
            throw new QrException('value is too long (' + bytes.size() + ' bytes; level ' + LEVEL_NAMES[ecl] + ' holds ' + maxBytes(ecl) + ')');
        }
        SDocsQrEncoder qr = new SDocsQrEncoder(version, ecl);
        qr.drawFunctionPatterns();
        qr.drawCodewords(qr.addEccAndInterleave(dataCodewords(bytes, version, numDataCodewords(version, ecl))));
        return qr;
    }

    /**
     * @description Byte-mode segment: mode 0100, the byte count (8 bits below version 10, else 16),
     * the bytes, a 4-bit terminator and pad bytes. The header is 12 or 20 bits, so every data byte
     * straddles two codewords at a fixed 4-bit offset; the last nibble plus the terminator fill a byte.
     */
    private static List<Integer> dataCodewords(List<Integer> bytes, Integer ver, Integer count) {
        List<Integer> result = new List<Integer>();
        Integer countBits = ver < 10 ? 8 : 16;
        Integer header = (4 << countBits) | bytes.size();
        if (countBits == 16) {
            result.add(header >>> 12);
        }
        result.add((header >>> 4) & 255);
        Integer carry = header & 15;
        for (Integer b : bytes) {
            result.add((carry << 4) | (b >>> 4));
            carry = b & 15;
        }
        result.add(carry << 4);
        for (Integer pad = 0; result.size() < count; pad++) {
            result.add(Math.mod(pad, 2) == 0 ? 236 : 17);
        }
        return result;
    }

    private void build() {
        List<Integer> penalties = this.maskPenalties();
        Integer bestMask = 0;
        for (Integer m = 1; m < 8; m++) {
            if (penalties[m] < penalties[bestMask]) {
                bestMask = m;
            }
        }
        this.applyMask(bestMask);
        this.drawFormatBits(bestMask);
    }

    private List<List<Boolean>> grid() {
        List<List<Boolean>> rows = new List<List<Boolean>>();
        for (Integer y = 0; y < this.size; y++) {
            List<Boolean> row = new List<Boolean>();
            for (Integer x = 0; x < this.size; x++) {
                row.add(this.modules[y * this.size + x]);
            }
            rows.add(row);
        }
        return rows;
    }

    // ------------------------------------------------------------------ function patterns

    private void drawFunctionPatterns() {
        for (Integer i = 0; i < this.size; i++) {
            this.setFunction(6, i, Math.mod(i, 2) == 0);
            this.setFunction(i, 6, Math.mod(i, 2) == 0);
        }
        this.drawFinder(3, 3);
        this.drawFinder(this.size - 4, 3);
        this.drawFinder(3, this.size - 4);
        List<Integer> positions = this.alignmentPositions();
        Integer numAlign = positions.size();
        for (Integer i = 0; i < numAlign; i++) {
            for (Integer j = 0; j < numAlign; j++) {
                if ((i == 0 && j == 0) || (i == 0 && j == numAlign - 1) || (i == numAlign - 1 && j == 0)) {
                    continue;
                }
                this.drawAlignment(positions[i], positions[j]);
            }
        }
        this.drawFormatBits(0); // reserves the format areas; redrawn after masking
        this.drawVersion();
    }

    private void drawFinder(Integer x, Integer y) {
        for (Integer dy = -4; dy <= 4; dy++) {
            for (Integer dx = -4; dx <= 4; dx++) {
                Integer dist = Math.max(Math.abs(dx), Math.abs(dy));
                Integer xx = x + dx;
                Integer yy = y + dy;
                if (xx >= 0 && xx < this.size && yy >= 0 && yy < this.size) {
                    this.setFunction(xx, yy, dist != 2 && dist != 4);
                }
            }
        }
    }

    private void drawAlignment(Integer x, Integer y) {
        for (Integer dy = -2; dy <= 2; dy++) {
            for (Integer dx = -2; dx <= 2; dx++) {
                this.setFunction(x + dx, y + dy, Math.max(Math.abs(dx), Math.abs(dy)) != 1);
            }
        }
    }

    private List<Integer> alignmentPositions() {
        if (this.version == 1) {
            return new List<Integer>();
        }
        Integer numAlign = this.version / 7 + 2;
        Integer step = (this.version * 8 + numAlign * 3 + 5) / (numAlign * 4 - 4) * 2;
        List<Integer> result = new List<Integer>();
        for (Integer i = 0; i < numAlign; i++) {
            result.add(0);
        }
        result[0] = 6;
        Integer pos = this.size - 7;
        for (Integer i = numAlign - 1; i >= 1; i--) {
            result[i] = pos;
            pos -= step;
        }
        return result;
    }

    private void drawFormatBits(Integer mask) {
        Integer data = (FORMAT_BITS[this.ecl] << 3) | mask;
        Integer rem = data;
        for (Integer i = 0; i < 10; i++) {
            rem = (rem << 1) ^ ((rem >>> 9) * 1335); // 0x537
        }
        Integer bits = ((data << 10) | rem) ^ 21522; // 0x5412
        for (Integer i = 0; i <= 5; i++) {
            this.setFunction(8, i, bit(bits, i));
        }
        this.setFunction(8, 7, bit(bits, 6));
        this.setFunction(8, 8, bit(bits, 7));
        this.setFunction(7, 8, bit(bits, 8));
        for (Integer i = 9; i < 15; i++) {
            this.setFunction(14 - i, 8, bit(bits, i));
        }
        for (Integer i = 0; i < 8; i++) {
            this.setFunction(this.size - 1 - i, 8, bit(bits, i));
        }
        for (Integer i = 8; i < 15; i++) {
            this.setFunction(8, this.size - 15 + i, bit(bits, i));
        }
        this.setFunction(8, this.size - 8, true); // always-dark module
    }

    private void drawVersion() {
        if (this.version < 7) {
            return;
        }
        Integer rem = this.version;
        for (Integer i = 0; i < 12; i++) {
            rem = (rem << 1) ^ ((rem >>> 11) * 7973); // 0x1F25
        }
        Integer bits = (this.version << 12) | rem;
        for (Integer i = 0; i < 18; i++) {
            Boolean dark = bit(bits, i);
            Integer a = this.size - 11 + Math.mod(i, 3);
            Integer b = i / 3;
            this.setFunction(a, b, dark);
            this.setFunction(b, a, dark);
        }
    }

    private void setFunction(Integer x, Integer y, Boolean dark) {
        this.modules[y * this.size + x] = dark;
        this.isFunction[y * this.size + x] = true;
        if (this.formatCells != null) {
            this.formatCells.add(y * this.size + x);
        }
    }

    // ------------------------------------------------------------------ codewords

    private List<Integer> addEccAndInterleave(List<Integer> data) {
        Integer numBlocks = NUM_ERROR_CORRECTION_BLOCKS[this.ecl][this.version];
        Integer blockEccLen = ECC_CODEWORDS_PER_BLOCK[this.ecl][this.version];
        Integer rawCodewords = numRawDataModules(this.version) / 8;
        Integer numShortBlocks = numBlocks - Math.mod(rawCodewords, numBlocks);
        Integer shortBlockLen = rawCodewords / numBlocks;
        List<Integer> divisor = rsDivisor(blockEccLen);
        List<List<Integer>> blocks = new List<List<Integer>>();
        Integer k = 0;
        for (Integer i = 0; i < numBlocks; i++) {
            Integer datLen = shortBlockLen - blockEccLen + (i < numShortBlocks ? 0 : 1);
            List<Integer> dat = new List<Integer>();
            for (Integer j = 0; j < datLen; j++) {
                dat.add(data[k + j]);
            }
            k += datLen;
            List<Integer> ecc = rsRemainder(dat, divisor);
            if (i < numShortBlocks) {
                dat.add(0);
            }
            dat.addAll(ecc);
            blocks.add(dat);
        }
        List<Integer> result = new List<Integer>();
        for (Integer i = 0; i < blocks[0].size(); i++) {
            for (Integer j = 0; j < blocks.size(); j++) {
                if (i != shortBlockLen - blockEccLen || j >= numShortBlocks) {
                    result.add(blocks[j][i]);
                }
            }
        }
        return result;
    }

    private void drawCodewords(List<Integer> data) {
        Integer i = 0;
        Integer totalBits = data.size() * 8;
        Integer right = this.size - 1;
        while (right >= 1) {
            if (right == 6) {
                right = 5;
            }
            Boolean upward = ((right + 1) & 2) == 0;
            for (Integer vert = 0; vert < this.size; vert++) {
                for (Integer j = 0; j < 2; j++) {
                    Integer x = right - j;
                    Integer y = upward ? this.size - 1 - vert : vert;
                    Integer idx = y * this.size + x;
                    if (!this.isFunction[idx] && i < totalBits) {
                        this.modules[idx] = bit(data[i >>> 3], 7 - (i & 7));
                        i++;
                    }
                }
            }
            right -= 2;
        }
    }

    private void applyMask(Integer mask) {
        List<Boolean> tile = new List<Boolean>();
        for (Integer i = 0; i < 72; i++) {
            tile.add(maskBit(mask, Math.mod(i, 6), i / 6));
        }
        Integer idx = 0;
        for (Integer y = 0; y < this.size; y++) {
            Integer rowBase = Math.mod(y, 12) * 6;
            Integer col = 0;
            for (Integer x = 0; x < this.size; x++) {
                if (!this.isFunction[idx] && tile[rowBase + col]) {
                    this.modules[idx] = !this.modules[idx];
                }
                idx++;
                col = col == 5 ? 0 : col + 1;
            }
        }
    }

    /** Whether a mask inverts module (x, y). Every mask depends only on x mod 6 and y mod 12. */
    private static Boolean maskBit(Integer mask, Integer x, Integer y) {
        switch on mask {
            when 0 { return Math.mod(x + y, 2) == 0; }
            when 1 { return Math.mod(y, 2) == 0; }
            when 2 { return Math.mod(x, 3) == 0; }
            when 3 { return Math.mod(x + y, 3) == 0; }
            when 4 { return Math.mod(x / 3 + y / 2, 2) == 0; }
            when 5 { return Math.mod(x * y, 2) + Math.mod(x * y, 3) == 0; }
            when 6 { return Math.mod(Math.mod(x * y, 2) + Math.mod(x * y, 3), 2) == 0; }
            when else { return Math.mod(Math.mod(x + y, 2) + Math.mod(x * y, 3), 2) == 0; }
        }
    }

    // ------------------------------------------------------------------ penalty (mask selection)

    /**
     * @description The penalty of each of the 8 masks (ISO/IEC 18004 7.8.3, with N3 counted for the
     * 1:1:3:1:1 pattern at module scale beside 4 light modules, as ZXing does).
     *
     * Each row and column is a line of Long words: bit p of the line is module p - 4, with 4 light
     * modules of padding on both sides (the quiet zone, so N3 sees light beyond the edge) and a zero
     * word at the end. A word holds 48 modules and is read together with the next word's first 16
     * (lookahead), so 5- and 11-module windows starting in it are whole. 48 is a multiple of the mask
     * periods, so a masked word is base ^ (pattern & free), with one pattern per line.
     */
    private List<Integer> maskPenalties() {
        Integer n = this.size;
        Integer nw = (n + 8) / WORD + 2;
        List<List<Long>> rowBits = zeroLines(n, nw);
        List<List<Long>> rowFree = zeroLines(n, nw);
        List<List<Long>> colBits = zeroLines(n, nw);
        List<List<Long>> colFree = zeroLines(n, nw);
        List<Integer> wordOf = new List<Integer>();
        List<Long> bitOf = new List<Long>();
        for (Integer i = 0; i < n; i++) {
            wordOf.add((i + 4) / WORD);
            bitOf.add(1L << Math.mod(i + 4, WORD));
        }
        Integer idx = 0;
        for (Integer y = 0; y < n; y++) {
            List<Long> rb = rowBits[y];
            List<Long> rf = rowFree[y];
            Integer wy = wordOf[y];
            Long yBit = bitOf[y];
            for (Integer x = 0; x < n; x++) {
                if (this.modules[idx]) {
                    rb[wordOf[x]] |= bitOf[x];
                    colBits[x][wy] |= yBit;
                }
                if (!this.isFunction[idx]) {
                    rf[wordOf[x]] |= bitOf[x];
                    colFree[x][wy] |= yBit;
                }
                idx++;
            }
        }
        // Line-position masks for one word index: window starts that stay inside the symbol.
        List<Long> win5 = positionMasks(nw, 4, n - 1);
        List<Long> firstCell = positionMasks(nw, 4, 4);
        List<Long> finder = positionMasks(nw, 0, n - 3);
        List<Long> block = positionMasks(nw, 4, n + 2);
        initPatterns();

        this.formatCells = new List<Integer>();
        this.drawFormatBits(0);
        List<Integer> formatIdx = this.formatCells;
        this.formatCells = null;

        List<Integer> result = new List<Integer>();
        for (Integer m = 0; m < 8; m++) {
            this.drawFormatBits(m);
            for (Integer f : formatIdx) {
                Integer fy = f / n;
                Integer fx = f - fy * n;
                setPacked(rowBits[fy], wordOf[fx], bitOf[fx], this.modules[f]);
                setPacked(colBits[fx], wordOf[fy], bitOf[fy], this.modules[f]);
            }
            Integer penalty = 0;
            Integer dark = 0;
            Integer blocks = 0;
            List<Long> prev = null;
            List<Long> pats = rowPatterns[m];
            Integer r = 0;
            for (Integer y = 0; y < n; y++) {
                List<Long> line = masked(rowBits[y], rowFree[y], pats[r], nw);
                r = r == 11 ? 0 : r + 1;
                penalty += linePenalty(line, nw, win5, firstCell, finder);
                for (Long w : line) {
                    if (w != 0) {
                        dark += popcount(w);
                    }
                }
                if (prev != null) {
                    blocks += blockCount(prev, line, nw, block);
                }
                prev = line;
            }
            pats = colPatterns[m];
            Integer c = 0;
            for (Integer x = 0; x < n; x++) {
                penalty += linePenalty(masked(colBits[x], colFree[x], pats[c], nw), nw, win5, firstCell, finder);
                c = c == 5 ? 0 : c + 1;
            }
            Integer total = n * n;
            Integer k = (Math.abs(dark * 20 - total * 10) + total - 1) / total - 1;
            result.add(penalty + blocks * 3 + Math.max(0, k) * 10);
        }
        return result;
    }

    private static List<List<Long>> zeroLines(Integer count, Integer nw) {
        List<Long> zero = new List<Long>();
        for (Integer k = 0; k < nw; k++) {
            zero.add(0L);
        }
        List<List<Long>> result = new List<List<Long>>();
        for (Integer i = 0; i < count; i++) {
            result.add(zero.clone());
        }
        return result;
    }

    /** One mask per word with the bits for line positions from..to (inclusive) set. */
    private static List<Long> positionMasks(Integer nw, Integer fromPos, Integer toPos) {
        List<Long> result = new List<Long>();
        for (Integer k = 0; k < nw; k++) {
            Long w = 0L;
            for (Integer j = 0; j < WORD; j++) {
                Integer p = k * WORD + j;
                if (p >= fromPos && p <= toPos) {
                    w |= 1L << j;
                }
            }
            result.add(w);
        }
        return result;
    }

    /**
     * Word patterns per mask: rows by y mod 12 (bit j is x = j - 4, so x mod 6 = (j + 2) mod 6), and
     * columns by x mod 6 (bit j is y = j - 4, so y mod 12 = (j + 8) mod 12).
     */
    private static void initPatterns() {
        if (rowPatterns != null) {
            return;
        }
        rowPatterns = new List<List<Long>>();
        colPatterns = new List<List<Long>>();
        for (Integer m = 0; m < 8; m++) {
            List<Long> rows = new List<Long>();
            for (Integer y = 0; y < 12; y++) {
                Long w = 0L;
                for (Integer j = 0; j < WORD; j++) {
                    if (maskBit(m, j + 2, y)) {
                        w |= 1L << j;
                    }
                }
                rows.add(w);
            }
            rowPatterns.add(rows);
            List<Long> cols = new List<Long>();
            for (Integer x = 0; x < 6; x++) {
                Long w = 0L;
                for (Integer j = 0; j < WORD; j++) {
                    if (maskBit(m, x, j + 8)) {
                        w |= 1L << j;
                    }
                }
                cols.add(w);
            }
            colPatterns.add(cols);
        }
    }

    private static void setPacked(List<Long> line, Integer word, Long bitValue, Boolean dark) {
        line[word] = dark ? line[word] | bitValue : line[word] & (bitValue ^ ALL);
    }

    private static List<Long> masked(List<Long> base, List<Long> free, Long pattern, Integer nw) {
        List<Long> result = new List<Long>();
        for (Integer k = 0; k < nw; k++) {
            result.add(base[k] ^ (pattern & free[k]));
        }
        return result;
    }

    /**
     * N1: each run of 5+ same-colour modules scores 3 + (length - 5) = (length - 4 windows of 5) + 2
     * per run start. N3: 40 per 1011101 with 0000 after (or before) it.
     */
    private static Integer linePenalty(List<Long> line, Integer nw, List<Long> win5, List<Long> firstCell, List<Long> finder) {
        Integer penalty = 0;
        Long carry = 0L;
        for (Integer k = 0; k < nw - 1; k++) {
            Long e = line[k] | (line[k + 1] << WORD);
            Long d = e ^ (e >>> 1);
            Long same = d ^ ALL;
            Long windows = same & (same >>> 1) & (same >>> 2) & (same >>> 3) & win5[k];
            if (windows != 0) {
                Long starts = windows & ((d << 1) | carry | firstCell[k]);
                penalty += popcount(windows) + 2 * popcount(starts);
            }
            carry = (d >>> (WORD - 1)) & 1L;
            Long core = (e >>> 4) & ((e >>> 5) ^ ALL) & (e >>> 6) & ((e >>> 1) ^ ALL) & ((e >>> 9) ^ ALL) & finder[k];
            if (core != 0) {
                Long after = e & (e >>> 2) & (e >>> 3) & ((e >>> 7) ^ ALL) & ((e >>> 8) ^ ALL) & ((e >>> 10) ^ ALL);
                Long before = (e ^ ALL) & ((e >>> 2) ^ ALL) & ((e >>> 3) ^ ALL) & (e >>> 7) & (e >>> 8) & (e >>> 10);
                Long hits = core & (after | before);
                if (hits != 0) {
                    penalty += 40 * popcount(hits);
                }
            }
        }
        return penalty;
    }

    /** N2: 2x2 blocks of one colour between two adjacent rows. */
    private static Integer blockCount(List<Long> upper, List<Long> lower, Integer nw, List<Long> block) {
        Integer count = 0;
        for (Integer k = 0; k < nw - 1; k++) {
            Long a = upper[k] | (upper[k + 1] << WORD);
            Long b = lower[k] | (lower[k + 1] << WORD);
            Long eq = (a ^ b) ^ ALL;
            Long hits = eq & (eq >>> 1) & ((a ^ (a >>> 1)) ^ ALL) & block[k];
            if (hits != 0) {
                count += popcount(hits);
            }
        }
        return count;
    }

    private static Integer popcount(Long value) {
        Long x = value - ((value >>> 1) & M1);
        x = (x & M2) + ((x >>> 2) & M2);
        x = (x + (x >>> 4)) & M4;
        x = x + (x >>> 8);
        x = x + (x >>> 16);
        x = x + (x >>> 32);
        return (x & 127L).intValue();
    }

    /** Test hook: each mask's penalty, and the module grid each was scored on (format bits included). */
    @TestVisible
    private static Map<String, Object> maskDiagnostics(String text, String level) {
        SDocsQrEncoder qr = prepare(text, level);
        List<Integer> penalties = qr.maskPenalties();
        List<List<Boolean>> grids = new List<List<Boolean>>();
        for (Integer m = 0; m < 8; m++) {
            qr.applyMask(m);
            qr.drawFormatBits(m);
            grids.add(qr.modules.clone());
            qr.applyMask(m);
        }
        return new Map<String, Object>{ 'size' => qr.size, 'penalties' => penalties, 'grids' => grids };
    }

    // ------------------------------------------------------------------ math helpers

    private static Integer numRawDataModules(Integer ver) {
        Integer result = (16 * ver + 128) * ver + 64;
        if (ver >= 2) {
            Integer numAlign = ver / 7 + 2;
            result -= (25 * numAlign - 10) * numAlign - 55;
            if (ver >= 7) {
                result -= 36;
            }
        }
        return result;
    }

    private static Integer numDataCodewords(Integer ver, Integer ecl) {
        return numRawDataModules(ver) / 8 - ECC_CODEWORDS_PER_BLOCK[ecl][ver] * NUM_ERROR_CORRECTION_BLOCKS[ecl][ver];
    }

    /** Most UTF-8 bytes a version-40 symbol holds at a level (byte mode: 4-bit mode and 16-bit count). */
    public static Integer maxBytes(String level) {
        return maxBytes(eclIndex(level));
    }

    private static Integer maxBytes(Integer ecl) {
        return capacity(40, ecl);
    }

    /** Most UTF-8 bytes a symbol of the given version holds at a level. */
    public static Integer capacity(Integer version, String level) {
        return capacity(version, eclIndex(level));
    }

    private static Integer capacity(Integer ver, Integer ecl) {
        return (numDataCodewords(ver, ecl) * 8 - 4 - (ver < 10 ? 8 : 16)) / 8;
    }

    private static List<Integer> rsDivisor(Integer degree) {
        List<Integer> result = new List<Integer>();
        for (Integer i = 0; i < degree; i++) {
            result.add(0);
        }
        result[degree - 1] = 1;
        Integer root = 1;
        for (Integer i = 0; i < degree; i++) {
            for (Integer j = 0; j < degree; j++) {
                result[j] = gfMultiply(result[j], root);
                if (j + 1 < degree) {
                    result[j] ^= result[j + 1];
                }
            }
            root = gfMultiply(root, 2);
        }
        return result;
    }

    private static List<Integer> rsRemainder(List<Integer> data, List<Integer> divisor) {
        initTables();
        Integer degree = divisor.size();
        List<Integer> divisorLog = new List<Integer>();
        List<Integer> result = new List<Integer>();
        for (Integer d : divisor) {
            divisorLog.add(d == 0 ? -1 : gfLog[d]);
            result.add(0);
        }
        for (Integer b : data) {
            Integer factor = b ^ result.remove(0);
            result.add(0);
            if (factor == 0) {
                continue;
            }
            Integer factorLog = gfLog[factor];
            for (Integer i = 0; i < degree; i++) {
                if (divisorLog[i] >= 0) {
                    result[i] ^= gfExp[divisorLog[i] + factorLog];
                }
            }
        }
        return result;
    }

    /** Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1 (0x11D), by log/exp tables. */
    private static Integer gfMultiply(Integer x, Integer y) {
        initTables();
        return x == 0 || y == 0 ? 0 : gfExp[gfLog[x] + gfLog[y]];
    }

    private static void initTables() {
        if (gfExp != null) {
            return;
        }
        gfExp = new List<Integer>();
        gfLog = new List<Integer>();
        for (Integer i = 0; i < 256; i++) {
            gfLog.add(0);
        }
        Integer value = 1;
        for (Integer i = 0; i < 255; i++) {
            gfExp.add(value);
            gfLog[value] = i;
            value <<= 1;
            if (value >= 256) {
                value ^= 285;
            }
        }
        for (Integer i = 255; i < 510; i++) {
            gfExp.add(gfExp[i - 255]); // exp[a + b] without a mod 255
        }
    }

    private static Boolean bit(Integer value, Integer index) {
        return ((value >>> index) & 1) != 0;
    }

    private static Integer eclIndex(String level) {
        String l = level == null ? 'M' : level.trim().toUpperCase();
        return l == 'L' ? 0 : (l == 'Q' ? 2 : (l == 'H' ? 3 : 1));
    }

    private static List<Integer> utf8Bytes(String text) {
        List<Integer> hex = EncodingUtil.convertToHex(Blob.valueOf(text)).getChars();
        List<Integer> bytes = new List<Integer>();
        for (Integer i = 0; i < hex.size(); i += 2) {
            Integer hi = hex[i];
            Integer lo = hex[i + 1];
            bytes.add(((hi < 97 ? hi - 48 : hi - 87) << 4) | (lo < 97 ? lo - 48 : lo - 87));
        }
        return bytes;
    }

}
