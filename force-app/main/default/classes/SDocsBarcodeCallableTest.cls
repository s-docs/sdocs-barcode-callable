@IsTest
private class SDocsBarcodeCallableTest {
    // Reference bar/space runs for 'SD-000123-ASPEN' from macOS CoreImage (CICode128BarcodeGenerator), spike S1.
    private static final List<Integer> CORE_IMAGE_RUNS = new List<Integer>{ 2, 1, 1, 2, 1, 4, 2, 1, 3, 1, 1, 3, 1, 1, 2, 3, 1, 3, 1, 2, 2, 1, 3, 2, 1, 1, 3, 1, 4, 1, 2, 1, 2, 2, 2, 2, 2, 2, 2, 1, 2, 2, 3, 1, 2, 1, 3, 1, 1, 1, 4, 1, 3, 1, 1, 2, 2, 1, 3, 2, 1, 1, 1, 3, 2, 3, 2, 1, 3, 1, 1, 3, 3, 1, 3, 1, 2, 1, 1, 3, 2, 1, 1, 3, 1, 1, 3, 3, 2, 1, 1, 1, 2, 2, 3, 2, 2, 3, 3, 1, 1, 1, 2 };

    @IsTest
    static void code128MatchesCoreImageReference() {
        Assert.areEqual(CORE_IMAGE_RUNS, SDocsBarcodes.code128Runs('SD-000123-ASPEN'));
    }

    @IsTest
    static void code128PatternsAreWellFormed() {
        Assert.areEqual(107, SDocsBarcodes.PATTERNS.size());
        for (Integer i = 0; i < SDocsBarcodes.PATTERNS.size(); i++) {
            Integer total = 0;
            for (String d : SDocsBarcodes.PATTERNS[i].split('')) {
                total += Integer.valueOf(d);
            }
            Assert.areEqual(i == 106 ? 13 : 11, total, 'pattern ' + i);
        }
    }

    @IsTest
    static void code128UsesCodeSetCForDigitRuns() {
        List<Integer> values = SDocsBarcodes.code128Values('123456');
        Assert.areEqual(105, values[0], 'starts in code set C');
        Assert.areEqual(new List<Integer>{ 12, 34, 56 }, new List<Integer>{ values[1], values[2], values[3] });
        Assert.areEqual(106, values[values.size() - 1]);
    }

    @IsTest
    static void code128RejectsNonAscii() {
        try {
            SDocsBarcodes.code128Values('café');
            Assert.fail('expected an exception');
        } catch (SDocsBarcodes.BarcodeException e) {
            Assert.isTrue(e.getMessage().contains('ASCII'));
        }
    }

    @IsTest
    static void qrPicksTheSmallestVersion() {
        Assert.areEqual(33, SDocsQrEncoder.encode('https://www.sdocs.com/aspen/s1?doc=SD-000123', 'M').size(), 'version 4: 44 bytes need 364 bits; version 3-M holds 352');
        Assert.areEqual(21, SDocsQrEncoder.encode('HELLO', 'L').size(), 'version 1');
        Assert.areEqual(41, SDocsQrEncoder.encode('x'.repeat(106), 'M').size(), 'version 6 holds 106 bytes at M');
        Assert.areEqual(45, SDocsQrEncoder.encode('x'.repeat(107), 'M').size(), 'version 7 (with version information)');
    }

    @IsTest
    static void qrHasFinderPatterns() {
        List<List<Boolean>> m = SDocsQrEncoder.encode('HELLO', 'M');
        Integer last = m.size() - 1;
        for (Integer i = 0; i < 7; i++) {
            Assert.isTrue(m[0][i] && m[i][0] && m[0][last - i] && m[last][i], 'finder edge ' + i);
        }
        Assert.isFalse(m[1][1], 'finder ring is light');
        Assert.isTrue(m[3][3], 'finder centre is dark');
    }

    @IsTest
    static void htmlUsesTablesWithQuietZones() {
        String code = SDocsBarcodes.toHtml('SD-000123-ASPEN', SDocsBarcodes.CODE128, 'module=1.2pt;height=40pt');
        Assert.isTrue(code.startsWith('<table class="sd-barcode sd-code128"'), code.left(120));
        Assert.areEqual(CORE_IMAGE_RUNS.size() + 2, code.countMatches('<td '));
        String qr = SDocsBarcodes.toHtml('HELLO', SDocsBarcodes.QR, 'module=4pt;level=Q');
        Assert.isTrue(qr.startsWith('<div class="sd-barcode sd-qr">'));
        Assert.areEqual(21 + 8, qr.countMatches('<table '), 'one table per row plus 8 quiet rows');
        Assert.areEqual('', SDocsBarcodes.toHtml(' ', SDocsBarcodes.QR, null));
    }

    @IsTest
    static void code128UsesCodeSetAForControlCharacters() {
        List<Integer> values = SDocsBarcodes.code128Values('A\tB');
        Assert.areEqual(new List<Integer>{ 103, 33, 73, 34 }, new List<Integer>{ values[0], values[1], values[2], values[3] }, 'start A; tab is 9 + 64');
        values = SDocsBarcodes.code128Values('ab\tc');
        Assert.areEqual(new List<Integer>{ 104, 65, 66, 101, 73, 100, 67 }, new List<Integer>{ values[0], values[1], values[2], values[3], values[4], values[5], values[6] }, 'B, switch to A for the tab, back to B for lower case');
        values = SDocsBarcodes.code128Values('X\u007F');
        Assert.areEqual(95, values[2], 'DEL is the last code set B value');
    }

    @IsTest
    static void qrCapacityAtVersion40() {
        Assert.areEqual(2953, SDocsQrEncoder.maxBytes('L'));
        Assert.areEqual(2331, SDocsQrEncoder.maxBytes('M'));
        Assert.areEqual(1663, SDocsQrEncoder.maxBytes('Q'));
        Assert.areEqual(1273, SDocsQrEncoder.maxBytes('H'));
        try {
            SDocsQrEncoder.encode('x'.repeat(1274), 'H');
            Assert.fail('expected an exception');
        } catch (SDocsQrEncoder.QrException e) {
            Assert.areEqual('value is too long (1274 bytes; level H holds 1273)', e.getMessage());
        }
    }

    @IsTest
    static void renderDrawsAMarkerForValuesThatCannotBeEncoded() {
        String marker = SDocsBarcodes.render('café', SDocsBarcodes.CODE128, 'module=1pt');
        Assert.areEqual('<span class="sd-barcode-error" style="font-size:7pt; color:#c00000; border:0.5pt solid #c00000; padding:0 2pt">Barcode: only ASCII characters can be encoded</span>', marker);
        Assert.areEqual(marker, SDocsBarcodes.render('café', SDocsBarcodes.CODE128, 'module=1pt'), 'same value, same bytes');
        String tooLong = SDocsBarcodes.render('x'.repeat(3000), SDocsBarcodes.QR, 'level=L');
        Assert.isTrue(tooLong.contains('>QR code: value is too long (3000 bytes; level L holds 2953)<'), tooLong);
        Assert.areEqual('', SDocsBarcodes.render('café', SDocsBarcodes.CODE128, 'onerror=blank'));
        Assert.isTrue(SDocsBarcodes.render('ok', SDocsBarcodes.CODE128, 'module=wide').contains('module must be a positive length'), 'bad options also degrade');
        Assert.isTrue(SDocsBarcodes.render('ok', SDocsBarcodes.CODE128, null).startsWith('<table class="sd-barcode sd-code128"'));
    }

    @IsTest
    static void toHtmlStillThrowsForCallersThatWantTheError() {
        try {
            SDocsBarcodes.toHtml('x'.repeat(3000), SDocsBarcodes.QR, 'level=L');
            Assert.fail('expected an exception');
        } catch (SDocsBarcodes.BarcodeException e) {
            Assert.isTrue(e.getMessage().startsWith('value is too long'), e.getMessage());
        }
    }

    @IsTest
    static void formatErrorChecksOptions() {
        Assert.isNull(SDocsBarcodes.formatError(SDocsBarcodes.CODE128, 'module=1.2pt;height=0.5in;onerror=blank'));
        Assert.isNull(SDocsBarcodes.formatError(SDocsBarcodes.QR, ' module = 2.5mm ; level = h '));
        Assert.isNull(SDocsBarcodes.formatError(SDocsBarcodes.QR, null));
        Assert.areEqual('module must be a positive length in pt, px, mm or in', SDocsBarcodes.formatError(SDocsBarcodes.QR, 'module=0pt'));
        Assert.areEqual('module must be a positive length in pt, px, mm or in', SDocsBarcodes.formatError(SDocsBarcodes.QR, 'module=3em'));
        Assert.areEqual('height must be a positive length in pt, px, mm or in', SDocsBarcodes.formatError(SDocsBarcodes.CODE128, 'height=tall'));
        Assert.areEqual('level must be L, M, Q or H', SDocsBarcodes.formatError(SDocsBarcodes.QR, 'level=X'));
        Assert.areEqual('unknown option level', SDocsBarcodes.formatError(SDocsBarcodes.CODE128, 'level=M'), 'Code128 has no error correction level');
        Assert.areEqual('onerror must be marker or blank', SDocsBarcodes.formatError(SDocsBarcodes.QR, 'onerror=hide'));
    }

    @IsTest
    static void packedMaskPenaltiesMatchAPlainReference() {
        // v1 (one word per line), v7 (version information), v14 (two words), v20 (three words)
        List<List<String>> cases = new List<List<String>>{
            new List<String>{ 'HELLO', 'L' }, new List<String>{ 'x'.repeat(100), 'Q' },
            new List<String>{ 'https://sdocs.com/'.repeat(10), 'M' }, new List<String>{ 'ab12'.repeat(150), 'H' }
        };
        for (List<String> c : cases) {
            Map<String, Object> d = SDocsQrEncoder.maskDiagnostics(c[0], c[1]);
            Integer n = (Integer) d.get('size');
            List<Integer> penalties = (List<Integer>) d.get('penalties');
            List<List<Boolean>> grids = (List<List<Boolean>>) d.get('grids');
            for (Integer m = 0; m < 8; m++) {
                Assert.areEqual(referencePenalty(grids[m], n), penalties[m], 'size ' + n + ' mask ' + m);
            }
        }
    }

    /** Per-module penalty: N1 runs, N2 blocks, N3 1011101 beside 4 light (quiet zone counts), N4 balance. */
    private static Integer referencePenalty(List<Boolean> g, Integer n) {
        Integer penalty = 0;
        Integer dark = 0;
        for (Integer line = 0; line < n; line++) {
            List<Boolean> row = new List<Boolean>();
            List<Boolean> col = new List<Boolean>();
            for (Integer i = 0; i < n; i++) {
                row.add(g[line * n + i]);
                col.add(g[i * n + line]);
                if (g[line * n + i]) {
                    dark++;
                }
            }
            penalty += referenceLine(row) + referenceLine(col);
        }
        for (Integer y = 0; y < n - 1; y++) {
            for (Integer x = 0; x < n - 1; x++) {
                Boolean c = g[y * n + x];
                if (c == g[y * n + x + 1] && c == g[(y + 1) * n + x] && c == g[(y + 1) * n + x + 1]) {
                    penalty += 3;
                }
            }
        }
        Integer total = n * n;
        Integer k = (Math.abs(dark * 20 - total * 10) + total - 1) / total - 1;
        return penalty + Math.max(0, k) * 10;
    }

    private static Integer referenceLine(List<Boolean> cells) {
        Integer penalty = 0;
        Integer run = 1;
        for (Integer i = 1; i <= cells.size(); i++) {
            if (i < cells.size() && cells[i] == cells[i - 1]) {
                run++;
            } else {
                penalty += run >= 5 ? run - 2 : 0;
                run = 1;
            }
        }
        String padded = '0000';
        for (Boolean c : cells) {
            padded += c ? '1' : '0';
        }
        padded += '0000';
        for (Integer s = 0; s + 11 <= padded.length(); s++) {
            String w = padded.substring(s, s + 11);
            if (w.equals('10111010000') || w.equals('00001011101')) {
                penalty += 40;
            }
        }
        return penalty;
    }

    @IsTest
    static void modulesSnapToThePdfLayoutGrid() {
        Assert.areEqual(0.75, SDocsBarcodes.snapToGrid('0.75pt'), '1 px: 20 steps');
        Assert.areEqual(1.2, SDocsBarcodes.snapToGrid('1.2pt'), '32 steps');
        Assert.areEqual(1.0125, SDocsBarcodes.snapToGrid('1pt'), '26.67 steps rounds to 27');
        Assert.areEqual(1.9875, SDocsBarcodes.snapToGrid('2pt'), '53.33 steps rounds to 53');
        Assert.areEqual(3, SDocsBarcodes.snapToGrid('3pt'));
        Assert.areEqual(3, SDocsBarcodes.snapToGrid('4px'));
        Assert.areEqual(5.6625, SDocsBarcodes.snapToGrid('2mm'), '5.669pt is 151.2 steps');
        Assert.areEqual(0.0375, SDocsBarcodes.snapToGrid('0.001pt'), 'at least one step');
        String qr = SDocsBarcodes.toHtml('HELLO', SDocsBarcodes.QR, 'module=2pt');
        Assert.isTrue(qr.contains('width:57.6375pt; height:1.9875pt'), '29 modules of 1.9875pt: ' + qr.left(300));
    }

    // ------------------------------------------------------------------ the callable

    private static Map<String, String> call(String action, Map<String, Object> args) {
        return (Map<String, String>) new SDocsBarcodeCallable().call(action, args);
    }

    @IsTest
    static void qrFromALiteralValue() {
        Map<String, String> result = call('qr', new Map<String, Object>{ 'value' => 'https://www.sdocs.com', 'key' => 'siteqr', 'module' => '2.5pt', 'level' => 'Q' });
        Assert.areEqual(new Set<String>{ 'siteqr' }, result.keySet());
        Assert.areEqual(SDocsBarcodes.toHtml('https://www.sdocs.com', SDocsBarcodes.QR, 'module=2.5pt;level=Q'), result.get('siteqr'));
    }

    @IsTest
    static void code128FromAFieldPath() {
        Account acc = new Account(Name = 'Acme', AccountNumber = 'ACME-42');
        insert acc;
        Contact con = new Contact(LastName = 'Lovelace', AccountId = acc.Id);
        insert con;
        Map<String, String> result = call('code128', new Map<String, Object>{ 'recordId' => String.valueOf(con.Id), 'field' => 'Account.AccountNumber', 'height' => '30pt' });
        Assert.areEqual(SDocsBarcodes.toHtml('ACME-42', SDocsBarcodes.CODE128, 'height=30pt'), result.get('barcode'), 'default key is barcode');
        result = call('qrcode', new Map<String, Object>{ 'recordId' => String.valueOf(acc.Id), 'field' => 'Name' });
        Assert.areEqual(SDocsBarcodes.toHtml('Acme', SDocsBarcodes.QR, null), result.get('qrcode'), 'default key is qrcode');
    }

    @IsTest
    static void emptyValuesDrawNothing() {
        Account acc = new Account(Name = 'No number');
        insert acc;
        Assert.areEqual('', call('barcode', new Map<String, Object>{ 'recordId' => String.valueOf(acc.Id), 'field' => 'AccountNumber' }).get('barcode'));
        Contact orphan = new Contact(LastName = 'Orphan');
        insert orphan;
        Assert.areEqual('', call('barcode', new Map<String, Object>{ 'recordId' => String.valueOf(orphan.Id), 'field' => 'Account.AccountNumber' }).get('barcode'), 'missing parent');
        Assert.areEqual('', call('qr', new Map<String, Object>{ 'value' => '' }).get('qrcode'));
        Assert.areEqual('', call('qr', null).get('qrcode'));
    }

    @IsTest
    static void problemsDrawAMarkerNotAnError() {
        Account acc = new Account(Name = 'Acme');
        insert acc;
        String id = String.valueOf(acc.Id);
        Assert.isTrue(call('code128', new Map<String, Object>{ 'value' => 'café' }).get('barcode').contains('only ASCII characters can be encoded'));
        Assert.isTrue(call('qr', new Map<String, Object>{ 'value' => 'x', 'level' => 'Z' }).get('qrcode').contains('level must be L, M, Q or H'));
        Assert.isTrue(call('qr', new Map<String, Object>{ 'recordId' => id, 'field' => 'No_Such_Field__c' }).get('qrcode').startsWith('<span class="sd-barcode-error"'));
        Assert.isTrue(call('qr', new Map<String, Object>{ 'recordId' => id, 'field' => 'Name FROM User --' }).get('qrcode').contains('field must be a field path'));
        Assert.isTrue(call('qr', new Map<String, Object>{ 'field' => 'Name' }).get('qrcode').contains('no record'));
        Assert.areEqual('', call('code128', new Map<String, Object>{ 'value' => 'café', 'onerror' => 'blank' }).get('barcode'));
    }

    @IsTest
    static void unknownActionsThrow() {
        try {
            call('datamatrix', new Map<String, Object>());
            Assert.fail('expected an exception');
        } catch (SDocsBarcodes.BarcodeException e) {
            Assert.isTrue(e.getMessage().contains('unknown action datamatrix'));
        }
    }

    @IsTest
    static void sDocsPassesStringMaps() {
        Map<String, String> args = new Map<String, String>{ 'value' => '123456', 'key' => 'Ref' };
        Map<String, String> result = (Map<String, String>) ((Callable) new SDocsBarcodeCallable()).call('code128', args);
        Assert.isTrue(result.get('Ref').startsWith('<table class="sd-barcode sd-code128"'));
    }

    @IsTest
    static void mergeValuesAreUnescaped() {
        Assert.areEqual('Tom & Jerry\'s <b>shop</b>', SDocsBarcodeCallable.unescapeMergeValue('Tom & Jerry\'s #AMP#lt;b>shop#AMP#lt;/b>'));
        Assert.areEqual('line1\nline2', SDocsBarcodeCallable.unescapeMergeValue('line1lt#br /gt#line2'));
        Assert.isNull(SDocsBarcodeCallable.unescapeMergeValue(null));
    }
}
