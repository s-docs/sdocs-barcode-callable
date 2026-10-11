/**
 * @description Barcodes and QR codes for existing S-Docs templates, through S-Docs' callable Apex
 * ("Call Apex classes in your S-Docs templates" on kb.sdocs.com). The symbol is drawn with HTML
 * tables, because the PDF renderer can't draw data: images or SVG. No images, files, external
 * services or package changes are involved.
 *
 * In the template's Source view, one callable block per symbol, then the symbol's key in TRIPLE braces
 * (the value is HTML):
 *
 *   <!--<callable><class>SDocsBarcodeCallable</class><action>qr</action>
 *   <args>{"field":"Payment_Link__c","key":"paymentqr","module":"3pt","level":"M"}</args></callable>-->
 *   {{{!paymentqr}}}
 *
 * Actions: qr, code128.
 * Args (strings):
 *   field    path of the value on the template's record, e.g. "Name" or "Account.AccountNumber" (up to 5
 *            lookups). Read with SOQL in user mode. Preferred: the value arrives exactly as stored.
 *   value    the text itself, usually a merge field ("{{!Opportunity.Name}}"). Used when there's no field.
 *   key      the merge field name to use in the template (default qrcode or barcode). Use a different key
 *            for every symbol in a template. S-Docs lowercases it.
 *   module   module size in pt, px, mm or in (QR default 3pt, minimum 2pt; Code128 default 1pt, minimum 1pt)
 *   height   Code128 bar height (default 40pt)
 *   level    QR error correction: L, M (default), Q or H
 *   onerror  marker (default) or blank: what to draw for a value that can't be encoded
 * S-Docs adds recordId (the template's record) itself.
 */
global with sharing class SDocsBarcodeCallable implements Callable {
    private static final Set<String> OPTIONS = new Set<String>{ 'module', 'height', 'level', 'onerror' };

    global Object call(String action, Map<String, Object> args) {
        String name = action == null ? '' : action.trim().toLowerCase();
        Integer symbology;
        if (name == 'qr' || name == 'qrcode') {
            symbology = SDocsBarcodes.QR;
        } else if (name == 'code128' || name == 'barcode') {
            symbology = SDocsBarcodes.CODE128;
        } else {
            throw new SDocsBarcodes.BarcodeException('SDocsBarcodeCallable: unknown action ' + action + ' (use qr or code128)');
        }
        Map<String, Object> params = args == null ? new Map<String, Object>() : args;
        String key = arg(params, 'key');
        if (String.isBlank(key)) {
            key = symbology == SDocsBarcodes.QR ? 'qrcode' : 'barcode';
        }
        List<String> format = new List<String>();
        for (String option : OPTIONS) {
            String optionValue = arg(params, option);
            if (String.isNotBlank(optionValue)) {
                format.add(option + '=' + optionValue);
            }
        }
        String formatString = String.join(format, ';');
        String html;
        try {
            String field = arg(params, 'field');
            String value = String.isNotBlank(field) ? fieldValue(arg(params, 'recordId'), field) : unescapeMergeValue(arg(params, 'value'));
            html = SDocsBarcodes.render(value, symbology, formatString);
        } catch (Exception e) {
            html = SDocsBarcodes.marker(symbology, formatString, e.getMessage());
        }
        return new Map<String, String>{ key.trim() => html };
    }

    private static String arg(Map<String, Object> params, String name) {
        Object value = params.get(name);
        return value == null ? null : String.valueOf(value);
    }

    /**
     * @description A merge field inside <args> arrives with S-Docs' own escaping still applied ('<' comes
     * as '#AMP#lt;', a line break as 'lt#br /gt#'), so undo it. Prefer 'field', which reads the stored
     * value directly: a double quote or backslash in a merge value breaks S-Docs' parsing of <args>.
     */
    @TestVisible
    private static String unescapeMergeValue(String value) {
        return value == null ? null : value.replace('lt#br /gt#', '\n').replace('lt#br/gt#', '\n').replace('#AMP#', '&').unescapeHtml4();
    }

    /** A field's value on the record, by path ('Name', 'Account.Owner.Email'), read in user mode. */
    @TestVisible
    private static String fieldValue(String recordId, String path) {
        String trimmed = path.trim();
        if (!Pattern.matches('[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*){0,5}', trimmed)) {
            throw new SDocsBarcodes.BarcodeException('field must be a field path such as Name or Account.AccountNumber');
        }
        if (String.isBlank(recordId)) {
            throw new SDocsBarcodes.BarcodeException('no record to read ' + trimmed + ' from');
        }
        Id recId = Id.valueOf(recordId);
        String objectName = recId.getSObjectType().getDescribe().getName();
        List<SObject> records = Database.query('SELECT ' + trimmed + ' FROM ' + objectName + ' WHERE Id = :recId', AccessLevel.USER_MODE);
        if (records.isEmpty()) {
            return null;
        }
        SObject current = records[0];
        List<String> parts = trimmed.split('\\.');
        for (Integer i = 0; i < parts.size() - 1; i++) {
            current = current.getSObject(parts[i]);
            if (current == null) {
                return null;
            }
        }
        Object value = current.get(parts[parts.size() - 1]);
        return value == null ? null : String.valueOf(value);
    }
}
