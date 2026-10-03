import 'package:flutter/foundation.dart' show debugPrint;
import 'package:idb_shim/idb_browser.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _dbName = 'nexus_local';
const String _storeName = 'kv';

Future<Database>? _dbFuture;

Future<Database> _db() {
  return _dbFuture ??= idbFactoryBrowser.open(
    _dbName,
    version: 1,
    onUpgradeNeeded: (VersionChangeEvent event) {
      final db = event.database;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    },
  );
}

Future<String?> _idbGet(String key) async {
  final db = await _db();
  final txn = db.transaction(_storeName, idbModeReadOnly);
  final value = await txn.objectStore(_storeName).getObject(key);
  await txn.completed;
  return value is String ? value : null;
}

Future<void> _idbPut(String key, String value) async {
  final db = await _db();
  final txn = db.transaction(_storeName, idbModeReadWrite);
  await txn.objectStore(_storeName).put(value, key);
  await txn.completed;
}

Future<void> _idbDelete(String key) async {
  final db = await _db();
  final txn = db.transaction(_storeName, idbModeReadWrite);
  await txn.objectStore(_storeName).delete(key);
  await txn.completed;
}

Future<String?> getString(String key) async {
  try {
    final value = await _idbGet(key);
    if (value != null) return value;
  } catch (e) {
    debugPrint('IndexedDB indisponível para leitura ($key): $e');
  }

  // Migração: dado antigo que ainda esteja no localStorage.
  final prefs = await SharedPreferences.getInstance();
  final legacy = prefs.getString(key);
  if (legacy != null) {
    try {
      await _idbPut(key, legacy);
      await prefs.remove(key);
    } catch (e) {
      debugPrint('Não foi possível migrar $key para IndexedDB: $e');
    }
  }
  return legacy;
}

Future<void> setString(String key, String value) async {
  try {
    await _idbPut(key, value);
    // Libera o espaço do localStorage se houver cópia antiga.
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(key)) await prefs.remove(key);
    return;
  } catch (e) {
    debugPrint('IndexedDB indisponível para gravação ($key): $e');
  }
  // Fallback: localStorage (pode falhar se estiver cheio).
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(key, value);
}

Future<void> remove(String key) async {
  try {
    await _idbDelete(key);
  } catch (e) {
    debugPrint('IndexedDB indisponível para remoção ($key): $e');
  }
  final prefs = await SharedPreferences.getInstance();
  if (prefs.containsKey(key)) await prefs.remove(key);
}
