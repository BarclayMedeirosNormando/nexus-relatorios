// lib/services/apps_script_client.dart
//
// Cliente HTTP único para o Apps Script. Substitui as 7 cópias de
// "http.Request + followRedirects=false + seguir 302 na mão" que existem em
// google_sheets_service.dart. Funciona em Web (PWA), Android e Windows.
//
// Por que o PWA precisa disso:
//  1. No navegador o `fetch` não expõe o header `location` do 302 do Apps Script
//     e `followRedirects = false` não é suportado -> deixar o navegador seguir.
//  2. `Content-Type: application/json` dispara preflight (OPTIONS), que o Apps
//     Script não responde (CORS). Usar `text/plain` evita o preflight; o corpo
//     continua sendo JSON e o servidor lê `e.postData.contents`.
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

class AppsScriptClient {
  AppsScriptClient._();

  /// Defina na compilação:
  ///   flutter build web --dart-define=APPS_SCRIPT_URL=https://script.google.com/macros/s/XXXX/exec
  static const String scriptUrl = String.fromEnvironment('APPS_SCRIPT_URL');

  /// Token de sessão devolvido pelo `login` quando a segurança do backend
  /// está ligada (REQUIRE_TOKEN=true). Guarde também em SharedPreferences.
  static String? sessionToken;

  /// Chamado quando o servidor responde code == 'AUTH' (sessão expirada).
  static void Function()? onAuthExpired;

  static Future<http.Response> post(
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    if (scriptUrl.isEmpty) {
      throw StateError('APPS_SCRIPT_URL não definido (use --dart-define).');
    }
    final body = Map<String, dynamic>.from(payload);
    final token = sessionToken;
    if (token != null && token.isNotEmpty) body['token'] = token;

    final uri = Uri.parse(scriptUrl);
    final response = kIsWeb
        ? await _postWeb(uri, body, timeout)
        : await _postNative(uri, body, timeout);

    _notifyIfAuthExpired(response);
    return response;
  }

  // Web: o navegador segue o redirect sozinho.
  static Future<http.Response> _postWeb(
    Uri uri,
    Map<String, dynamic> body,
    Duration timeout,
  ) {
    return http
        .post(
          uri,
          headers: const {'Content-Type': 'text/plain;charset=utf-8'},
          body: jsonEncode(body),
        )
        .timeout(timeout);
  }

  // Android / Windows: comportamento atual (POST -> 302 -> GET no destino).
  static Future<http.Response> _postNative(
    Uri uri,
    Map<String, dynamic> body,
    Duration timeout,
  ) async {
    final client = http.Client();
    try {
      final request = http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json; charset=utf-8'
        ..body = jsonEncode(body)
        ..followRedirects = false;

      var response = await http.Response.fromStream(
        await client.send(request).timeout(timeout),
      );

      if ({301, 302, 303}.contains(response.statusCode)) {
        final location = response.headers['location'];
        if (location != null && location.isNotEmpty) {
          final redirected = http.Request('GET', Uri.parse(location))
            ..followRedirects = true;
          response = await http.Response.fromStream(
            await client.send(redirected).timeout(timeout),
          );
        }
      }
      return response;
    } finally {
      client.close();
    }
  }

  static void _notifyIfAuthExpired(http.Response response) {
    if (onAuthExpired == null) return;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map && decoded['code'] == 'AUTH') onAuthExpired!();
    } catch (_) {
      // corpo não é JSON: ignorar
    }
  }
}
