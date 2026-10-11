// Smoke test without a template: run with
//   sf apex run --target-org my-org --file scripts/try-callable.apex
// Calls the class the way S-Docs does and prints the size of the HTML it returns.
Map<String, Object> args = new Map<String, Object>{ 'value' => 'https://www.sdocs.com', 'key' => 'siteqr', 'module' => '3pt' };
Map<String, String> result = (Map<String, String>) new SDocsBarcodeCallable().call('qr', args);
String html = result.get('siteqr');
System.debug(LoggingLevel.ERROR, 'QR HTML: ' + html.length() + ' characters, starts with ' + html.left(60));

result = (Map<String, String>) new SDocsBarcodeCallable().call('code128', new Map<String, Object>{ 'value' => 'café' });
System.debug(LoggingLevel.ERROR, 'Bad value draws a marker: ' + result.get('barcode'));
