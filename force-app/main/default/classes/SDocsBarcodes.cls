/**
 * @description Code128 and QR encoders that draw with HTML tables, because Blob.toPdf does not render
 * data: images or SVG.
 *
 * Options come from the field's format string, e.g. 'module=1.2pt;height=40pt' (Code128) or
 * 'module=3pt;level=M' (QR). 'onerror=blank' draws nothing for a value the symbology can't encode;
 * the default is a small visible marker, so one bad field value never fails the whole document.
 */
public inherited sharing class SDocsBarcodes {
    public static final Integer CODE128 = 1;
    public static final Integer QR = 2;

    private static final Set<String> UNITS = new Set<String>{ 'pt', 'px', 'mm', 'in' };
    private static final Set<String> LEVELS = new Set<String>{ 'L', 'M', 'Q', 'H' };
    private static final Set<String> ON_ERROR = new Set<String>{ 'marker', 'blank' };

    public class BarcodeException extends Exception {
    }

    /** Symbology code for a data-sd-symbology value. */
    public static Integer symbology(String name) {
        return name != null && name.equalsIgnoreCase('qr') ? QR : CODE128;
    }

    /**
     * @description Draws a barcode as HTML.
     * @param value text to encode (blank returns '')
     * @param symbologyCode CODE128 or QR
     * @param format options, e.g. 'module=1pt;height=40pt;level=M'
     * @throws BarcodeException when the value or the options can't be drawn
     */
    public static String toHtml(String value, Integer symbologyCode, String format) {
        if (String.isBlank(value)) {
            return '';
        }
        Map<String, String> options = parseOptions(format);
        String error = optionsError(symbologyCode, options);
        if (error != null) {
            throw new BarcodeException(error);
        }
        if (symbologyCode == QR) {
            String module = options.containsKey('module') ? options.get('module') : '3pt';
            try {
                return qrHtml(SDocsQrEncoder.encode(value, options.containsKey('level') ? options.get('level') : 'M'), module);
            } catch (SDocsQrEncoder.QrException e) {
                throw new BarcodeException(e.getMessage());
            }
        }
        String module = options.containsKey('module') ? options.get('module') : '1pt';
        String height = options.containsKey('height') ? options.get('height') : '40pt';
        return code128Html(code128Runs(value), module, height);
    }

    /**
     * @description toHtml for the render path: a value that can't be drawn becomes a small marker
     * (or '' with 'onerror=blank') instead of an exception. The same value always gives the same bytes.
     */
    public static String render(String value, Integer symbologyCode, String format) {
        try {
            return toHtml(value, symbologyCode, format);
        } catch (BarcodeException e) {
            return marker(symbologyCode, format, e.getMessage());
        }
    }

    /** What a symbol that can't be drawn shows: a small red marker, or '' with 'onerror=blank'. */
    public static String marker(Integer symbologyCode, String format, String message) {
        if ('blank'.equalsIgnoreCase(parseOptions(format).get('onerror'))) {
            return '';
        }
        return '<span class="sd-barcode-error" style="font-size:7pt; color:#c00000; border:0.5pt solid #c00000; padding:0 2pt">'
            + (symbologyCode == QR ? 'QR code' : 'Barcode') + ': ' + message.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;') + '</span>';
    }

    /**
     * @description Checks a format string.
     * @return a message for the author, or null when the options are valid
     */
    public static String formatError(Integer symbologyCode, String format) {
        return optionsError(symbologyCode, parseOptions(format));
    }

    private static String optionsError(Integer symbologyCode, Map<String, String> options) {
        Set<String> allowed = symbologyCode == QR ? new Set<String>{ 'module', 'level', 'onerror' } : new Set<String>{ 'module', 'height', 'onerror' };
        for (String key : options.keySet()) {
            String value = options.get(key);
            if (!allowed.contains(key)) {
                return 'unknown option ' + key;
            }
            if ((key == 'module' || key == 'height') && lengthValue(value) == null) {
                return key + ' must be a positive length in pt, px, mm or in';
            }
            if (key == 'level' && !LEVELS.contains(value.toUpperCase())) {
                return 'level must be L, M, Q or H';
            }
            if (key == 'onerror' && !ON_ERROR.contains(value.toLowerCase())) {
                return 'onerror must be marker or blank';
            }
        }
        return null;
    }

    // ------------------------------------------------------------------ Code128

    /** Bar/space widths for values 0..106 (106 = stop, 7 elements). Each pattern spans 11 modules (stop: 13). */
    @TestVisible
    private static final List<String> PATTERNS = new List<String>{
        '212222', '222122', '222221', '121223', '121322', '131222', '122213', '122312', '132212', '221213',
        '221312', '231212', '112232', '122132', '122231', '113222', '123122', '123221', '223211', '221132',
        '221231', '213212', '223112', '312131', '311222', '321122', '321221', '312212', '322112', '322211',
        '212123', '212321', '232121', '111323', '131123', '131321', '112313', '132113', '132311', '211313',
        '231113', '231311', '112133', '112331', '132131', '113123', '113321', '133121', '313121', '211331',
        '231131', '213113', '213311', '213131', '311123', '311321', '331121', '312113', '312311', '332111',
        '314111', '221411', '431111', '111224', '111422', '121124', '121421', '141122', '141221', '112214',
        '112412', '122114', '122411', '142112', '142211', '241211', '221114', '413111', '241112', '134111',
        '111242', '121142', '121241', '114212', '124112', '124211', '411212', '421112', '421211', '212141',
        '214121', '412121', '111143', '111341', '131141', '114113', '114311', '411113', '411311', '113141',
        '114131', '311141', '411131', '211412', '211214', '211232', '2331112'
    };
    private static final Integer START_A = 103;
    private static final Integer START_B = 104;
    private static final Integer START_C = 105;
    private static final Integer CODE_C = 99;
    private static final Integer CODE_B = 100;
    private static final Integer CODE_A = 101;
    private static final Integer STOP = 106;

    /**
     * @description Code128 symbol values: code set C for runs of 4+ even digits (at the start, end, or
     * 6+ in the middle), code set A for control characters (ASCII 0-31), code set B otherwise.
     */
    @TestVisible
    private static List<Integer> code128Values(String text) {
        List<Integer> chars = text.getChars();
        for (Integer c : chars) {
            if (c > 127) {
                throw new BarcodeException('only ASCII characters can be encoded');
            }
        }
        List<Integer> values = new List<Integer>();
        Integer i = 0;
        Integer n = chars.size();
        String codeSet = null;
        while (i < n) {
            Integer run = digitRun(chars, i);
            Boolean atStart = i == 0;
            Boolean toEnd = i + run == n;
            Boolean useC = (run >= 4 && (atStart || toEnd)) || run >= 6;
            if (useC) {
                Integer pairs = run / 2;
                switchTo(values, codeSet, 'C');
                codeSet = 'C';
                for (Integer p = 0; p < pairs; p++) {
                    values.add((chars[i] - 48) * 10 + (chars[i + 1] - 48));
                    i += 2;
                }
                continue;
            }
            Integer c = chars[i];
            String target = c < 32 ? 'A' : (c >= 96 ? 'B' : (codeSet == 'A' || codeSet == 'B' ? codeSet : nextSet(chars, i)));
            switchTo(values, codeSet, target);
            codeSet = target;
            values.add(target == 'A' && c < 32 ? c + 64 : c - 32);
            i++;
        }
        Integer checksum = values[0];
        for (Integer k = 1; k < values.size(); k++) {
            checksum += values[k] * k;
        }
        values.add(Math.mod(checksum, 103));
        values.add(STOP);
        return values;
    }

    /** Start code, or a code-set switch (99/100/101 mean C/B/A in every set that can switch). */
    private static void switchTo(List<Integer> values, String current, String target) {
        if (current == null) {
            values.add(target == 'A' ? START_A : (target == 'B' ? START_B : START_C));
        } else if (current != target) {
            values.add(target == 'A' ? CODE_A : (target == 'B' ? CODE_B : CODE_C));
        }
    }

    /** A or B for a character both sets hold: whichever the next character that needs one of them wants. */
    private static String nextSet(List<Integer> chars, Integer fromIndex) {
        for (Integer k = fromIndex; k < chars.size(); k++) {
            if (chars[k] < 32) {
                return 'A';
            }
            if (chars[k] >= 96) {
                return 'B';
            }
        }
        return 'B';
    }

    private static Integer digitRun(List<Integer> chars, Integer startIndex) {
        Integer k = startIndex;
        while (k < chars.size() && chars[k] >= 48 && chars[k] <= 57) {
            k++;
        }
        return k - startIndex;
    }

    /** Alternating bar/space widths in modules, starting with a bar. */
    @TestVisible
    private static List<Integer> code128Runs(String text) {
        List<Integer> runs = new List<Integer>();
        for (Integer value : code128Values(text)) {
            String pattern = PATTERNS[value];
            for (Integer k = 0; k < pattern.length(); k++) {
                runs.add(Integer.valueOf(pattern.substring(k, k + 1)));
            }
        }
        return runs;
    }

    private static String code128Html(List<Integer> runs, String module, String height) {
        Cells cells = new Cells(module);
        Integer totalModules = 20;
        for (Integer r : runs) {
            totalModules += r;
        }
        List<String> out = new List<String>{
            '<table class="sd-barcode sd-code128" cellpadding="0" cellspacing="0" style="table-layout:fixed; border-collapse:collapse; width:'
            + cells.length(totalModules) + '; height:' + height + '; background-color:#ffffff"><tr style="height:' + height + '">',
            cells.get(10, false)
        };
        for (Integer k = 0; k < runs.size(); k++) {
            out.add(cells.get(runs[k], Math.mod(k, 2) == 0));
        }
        out.add(cells.get(10, false));
        out.add('</tr></table>');
        return String.join(out, '');
    }

    // ------------------------------------------------------------------ QR

    /** Run-length rows: one single-row table per module row, with a 4-module quiet zone. */
    private static String qrHtml(List<List<Boolean>> modules, String module) {
        Cells cells = new Cells(module);
        Integer size = modules.size() + 8;
        String rowOpen = '<table cellpadding="0" cellspacing="0" style="table-layout:fixed; border-collapse:collapse; width:' + cells.length(size)
            + '; height:' + cells.length(1) + '; background-color:#ffffff"><tr style="height:' + cells.length(1) + '">';
        String quietRow = rowOpen + cells.get(size, false) + '</tr></table>';
        List<String> rows = new List<String>{ '<div class="sd-barcode sd-qr">' };
        for (Integer q = 0; q < 4; q++) {
            rows.add(quietRow);
        }
        for (List<Boolean> row : modules) {
            rows.add(rowOpen);
            Boolean current = false;
            Integer runLength = 4; // left quiet zone
            for (Boolean dark : row) {
                if (dark == current) {
                    runLength++;
                } else {
                    rows.add(cells.get(runLength, current));
                    current = dark;
                    runLength = 1;
                }
            }
            if (current) {
                rows.add(cells.get(runLength, true));
                rows.add(cells.get(4, false));
            } else {
                rows.add(cells.get(runLength + 4, false));
            }
            rows.add('</tr></table>');
        }
        for (Integer q = 0; q < 4; q++) {
            rows.add(quietRow);
        }
        rows.add('</div>');
        return String.join(rows, '');
    }

    // ------------------------------------------------------------------ helpers

    /**
     * @description Table cells by run length, built once each: a symbol repeats the same few widths
     * thousands of times. Light cells show the table's white background, so they carry only a width.
     *
     * Blob.toPdf lays boxes out on a grid of 1/20 CSS px (3/80 pt) and rounds every cell to it, so a
     * module that isn't on the grid (1pt is 26.67 steps) drifts: up to half a module across a 1pt
     * Code128 and between the rows of a 2pt QR. The module is therefore converted to pt and snapped
     * to the grid (it moves by at most 0.019pt), which makes every cell, row and table exact.
     */
    private class Cells {
        private final Decimal moduleSize;
        private final Map<Integer, String> cache = new Map<Integer, String>();

        Cells(String module) {
            this.moduleSize = snapToGrid(module);
        }

        String length(Integer modules) {
            return fmt(modules * this.moduleSize) + 'pt';
        }

        String get(Integer modules, Boolean dark) {
            Integer key = dark ? -modules : modules;
            String result = this.cache.get(key);
            if (result == null) {
                result = '<td style="width:' + this.length(modules) + (dark ? '; background-color:#000000' : '') + '"></td>';
                this.cache.put(key, result);
            }
            return result;
        }
    }

    /** A module length in pt, on Blob.toPdf's layout grid of 3/80 pt (at least one step). */
    @TestVisible
    private static Decimal snapToGrid(String module) {
        Decimal value = lengthValue(module);
        String unit = lengthUnit(module);
        Decimal points = unit == 'px' ? value * 0.75 : unit == 'mm' ? value * 72 / 25.4 : unit == 'in' ? value * 72 : value;
        Decimal steps = Decimal.valueOf(Math.max(1L, (points * 80 / 3).round(System.RoundingMode.HALF_UP)));
        return (steps * 3 / 80).setScale(4);
    }

    private static String fmt(Decimal value) {
        return value.setScale(4).stripTrailingZeros().toPlainString();
    }

    /** The number in a length such as '1.2pt', or null when it isn't a positive number with a known unit. */
    private static Decimal lengthValue(String length) {
        String trimmed = length == null ? '' : length.trim();
        String digits = trimmed.length() > 2 && UNITS.contains(trimmed.right(2)) ? trimmed.left(trimmed.length() - 2) : trimmed;
        try {
            Decimal result = Decimal.valueOf(digits.trim());
            return result > 0 && result <= 1000 ? result : null;
        } catch (TypeException e) {
            return null;
        }
    }

    private static String lengthUnit(String length) {
        String trimmed = length.trim();
        return trimmed.length() > 2 && UNITS.contains(trimmed.right(2)) ? trimmed.right(2) : 'pt';
    }

    private static Map<String, String> parseOptions(String format) {
        Map<String, String> options = new Map<String, String>();
        if (String.isBlank(format)) {
            return options;
        }
        for (String part : format.split(';')) {
            Integer eq = part.indexOf('=');
            if (eq > 0) {
                options.put(part.substring(0, eq).trim().toLowerCase(), part.substring(eq + 1).trim());
            }
        }
        return options;
    }
}
