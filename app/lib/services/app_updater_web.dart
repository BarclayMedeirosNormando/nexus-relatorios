import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// Assinatura do `main.dart.js` publicado (muda a cada deploy).
Future<String?> fetchBuildSignature() async {
  final url = Uri.base.resolve('main.dart.js');
  final res = await http.head(
    url,
    headers: const {'Cache-Control': 'no-cache'},
  ).timeout(const Duration(seconds: 12));
  if (res.statusCode != 200) return null;
  final etag = res.headers['etag'] ?? '';
  final modified = res.headers['last-modified'] ?? '';
  final length = res.headers['content-length'] ?? '';
  final signature = '$etag|$modified|$length';
  return signature == '||' ? null : signature;
}

void reloadApp() {
  web.window.location.reload();
}
