import 'local_store_io.dart'
    if (dart.library.js_interop) 'local_store_web.dart' as impl;

/// Armazenamento local para dados GRANDES (fila offline, relatórios locais,
/// cache de funcionários).
///
/// - Web (PWA): IndexedDB (centenas de MB), em vez do localStorage (~5 MB).
///   Dados antigos que estiverem no localStorage são migrados sozinhos na
///   primeira leitura.
/// - Android/Windows: SharedPreferences, como antes.
class LocalStore {
  LocalStore._();

  static Future<String?> getString(String key) => impl.getString(key);

  static Future<void> setString(String key, String value) =>
      impl.setString(key, value);

  static Future<void> remove(String key) => impl.remove(key);
}
