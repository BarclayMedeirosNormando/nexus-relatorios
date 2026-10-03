import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/technician_model.dart';

/// Permite entrar sem internet em um aparelho onde o usuário já fez login
/// online. Guarda apenas um hash com sal da senha (nunca a senha em texto).
class OfflineAuth {
  OfflineAuth._();

  static String _key(String email) {
    final id = sha256.convert(utf8.encode(email.trim().toLowerCase()));
    return 'offline_auth_${id.toString().substring(0, 24)}';
  }

  static String _hash(String salt, String senha) =>
      sha256.convert(utf8.encode('$salt:$senha')).toString();

  /// Chamado após um login bem-sucedido no servidor.
  static Future<void> remember(
    String email,
    String senha,
    TechnicianModel tecnico,
  ) async {
    final rnd = Random.secure();
    final salt =
        base64UrlEncode(List<int>.generate(12, (_) => rnd.nextInt(256)));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key(email),
      jsonEncode({
        'salt': salt,
        'hash': _hash(salt, senha),
        'tecnico': {
          'id': tecnico.id,
          'nome': tecnico.name,
          'matricula': tecnico.registration,
          'email': tecnico.email,
          'permissao': tecnico.permissions,
        },
      }),
    );
  }

  /// `known` = existe login anterior deste e-mail neste aparelho.
  /// `tecnico` != null = senha confere.
  static Future<({bool known, TechnicianModel? tecnico})> verify(
    String email,
    String senha,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(email));
    if (raw == null) return (known: false, tecnico: null);
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final salt = data['salt'] as String;
      if (_hash(salt, senha) != data['hash']) {
        return (known: true, tecnico: null);
      }
      final t = data['tecnico'] as Map<String, dynamic>;
      return (
        known: true,
        tecnico: TechnicianModel(
          id: t['id']?.toString() ?? '',
          name: t['nome']?.toString() ?? '',
          registration: t['matricula']?.toString() ?? '',
          email: t['email']?.toString() ?? '',
          permissions: t['permissao']?.toString() ?? 'USR',
        ),
      );
    } catch (_) {
      return (known: false, tecnico: null);
    }
  }
}
