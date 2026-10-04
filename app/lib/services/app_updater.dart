import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_updater_stub.dart'
    if (dart.library.js_interop) 'app_updater_web.dart' as impl;

/// Avisa quando existe uma versão nova do PWA publicada (web).
///
/// Guarda a "assinatura" do arquivo principal do app (ETag/Last-Modified do
/// `main.dart.js`) quando o app abre e compara de tempos em tempos. Se mudou,
/// [updateAvailable] vira `true` e a tela inicial mostra "Atualizar".
/// No Android/Windows (app nativo) não faz nada.
class AppUpdater {
  AppUpdater._();

  static final ValueNotifier<bool> updateAvailable = ValueNotifier<bool>(false);

  static String? _baseline;
  static Timer? _timer;
  static bool _started = false;

  static Future<void> start() async {
    if (_started || !kIsWeb) return;
    _started = true;
    _baseline = await impl.fetchBuildSignature();
    _timer = Timer.periodic(const Duration(minutes: 10), (_) => check());
  }

  static Future<void> check() async {
    if (!kIsWeb || updateAvailable.value) return;
    try {
      final current = await impl.fetchBuildSignature();
      if (current == null || current.isEmpty) return;
      if (_baseline == null || _baseline!.isEmpty) {
        _baseline = current;
        return;
      }
      if (current != _baseline) updateAvailable.value = true;
    } catch (e) {
      debugPrint('Verificação de versão falhou: $e');
    }
  }

  /// Recarrega o app para carregar a versão nova. Os relatórios pendentes
  /// ficam guardados no aparelho e não são perdidos.
  static void applyUpdate() => impl.reloadApp();
}
