import 'local_store.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart'
    show kIsWeb, debugPrint, debugPrintStack;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/report_model.dart';
import '../models/school_model.dart';
import '../models/technician_model.dart';
import '../utils/app_constants.dart';
import '../utils/text_encoding.dart';
import '../utils/json_utils.dart';
import 'school_service.dart';
import 'apps_script_client.dart';

class PendingSyncItem {
  final String id;
  final String entityType;
  final String actionLabel;
  final String reportNumber;
  final String title;
  final DateTime? queuedAt;
  final String status;
  final Map<String, dynamic> rawData;

  const PendingSyncItem({
    required this.id,
    required this.entityType,
    required this.actionLabel,
    required this.reportNumber,
    required this.title,
    required this.queuedAt,
    required this.status,
    required this.rawData,
  });
}

class GoogleSheetsService {
  // A URL do Apps Script gerada
  // URL vem de --dart-define=APPS_SCRIPT_URL=... (ver docs/MIGRACAO.md)
  static const String _scriptUrl = AppsScriptClient.scriptUrl;

  // Chave para salvar os dados offline no SharedPreferences
  static const String _offlineQueueKey = 'offline_reports_queue';
  static const String _localReportsKey = 'local_reports';
  static const List<String> _legacyOfflineQueueKeys = [
    'pending_sync',
    'pending_reports',
    'offline_reports',
    'syncQueue',
    'offlineQueue',
    'offline_queue',
    'sync_queue',
    'pending_sync_queue',
  ];
  /// Resolve o município de um relatório garantindo que SchoolService esteja carregado.
  /// Ordem: schoolCity → INEP no SchoolService → nome da escola no SchoolService → ''.
  Future<String> _resolveReportMunicipio(ReportModel report) async {
    // 1. Já tem cidade
    final city = report.schoolCity?.trim();
    if (city != null && city.isNotEmpty) return city;

    // 2. Garante escolas carregadas
    await SchoolService().loadSchoolsIfNeeded();

    // 3. Por INEP
    final cityByInep = GoogleSheetsService.findCityByInep(report.schoolInep);
    if (cityByInep != null && cityByInep.isNotEmpty) return cityByInep;

    // 4. Por nome da escola
    final nameLower = _normalizeText(report.schoolName);
    if (nameLower.isNotEmpty) {
      for (final school in SchoolService().schools) {
        if (_normalizeText(school.name) == nameLower) {
          final c = school.city.trim();
          if (c.isNotEmpty) return c;
        }
      }
    }

    return '';
  }

  static String _normalizeText(String? value) {
    return (value ?? '').trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Envia o relatório. Se estiver offline, salva na fila para sincronizar depois.
  /// [isEdit] indica se é uma edição (true) ou criação nova (false).
  Future<void> sendReport(
    ReportModel report,
    String loggedInUser, {
    bool isEdit = false,
  }) async {
    // Resolve o município mesmo que schoolCity esteja vazio
    final municipio = await _resolveReportMunicipio(report);
    final materiaisTiJson = jsonEncode(
      report.tiMaterials.map((item) => item.toJson()).toList(),
    );

    // Monta o pacote de dados JSON
    final Map<String, dynamic> data = {
      'acao': 'adicionar',
      'acao_tipo': isEdit ? 'Editar' : 'Criar', // para auditoria
      'id': report.id,
      'numero_relatorio': report.reportNumber,
      'usuario_logado': loggedInUser,
      'escola': report.schoolName,
      'endereco_escola': report.schoolAddress ?? '',
      'municipio': municipio,
      'inep': report.schoolInep ?? '',
      'data_visita': report.visitDate.toIso8601String(),
      'tipo_relatorio': report.isTechnicalAnalysis ? 'Técnico' : 'Não-Técnico',
      'motivos': report.subjects.join(', '),
      'observacoes': report.observations ?? '',
      'materiais_ti_json': materiaisTiJson,
      'materiaisTiJson': materiaisTiJson,
      'tiMaterials': report.tiMaterials.map((item) => item.toJson()).toList(),
      'gre': report.gre ?? '',
      'tecnicos': report.technicians.join(', '),
      'responsavel': report.responsiblePerson ?? '',
    };

    // Se tiver assinatura única, converte para Base64 e adiciona campos legados.
    if (report.signatureBytes != null) {
      data['assinaturaBase64'] = base64Encode(report.signatureBytes!);
      data['assinaturaNome'] = 'assinatura_${report.id}.png';
    }

    // Se tiver múltiplas assinaturas, transmite em lista também.
    if (report.signatureBytesList != null && report.signatureBytesList!.isNotEmpty) {
      data['signatureBytesList'] = report.signatureBytesList!
          .map((bytes) => base64Encode(bytes))
          .toList();
      data['assinaturaBase64List'] = report.signatureBytesList!
          .map((bytes) => base64Encode(bytes))
          .toList();
    }

    if (report.signatureUrlList != null && report.signatureUrlList!.isNotEmpty) {
      data['signatureUrlList'] = report.signatureUrlList;
    }

    // Trata múltiplas fotos e funciona tanto no Web quanto no Celular!
    final remotePhotos = <Map<String, String>>[];
    List<Map<String, String>> fotosBase64Array = [];
    if (report.photos.isNotEmpty) {
      for (int i = 0; i < report.photos.length; i++) {
        try {
          final path = report.photos[i].path.trim();
          if (path.startsWith('http://') || path.startsWith('https://')) {
            remotePhotos.add({
              'url': path,
              'comment': report.photos[i].comment ?? '',
            });
            continue;
          }

          Uint8List bytes;
          if (kIsWeb) {
            // No navegador, a foto fica numa URL temporária "blob:"
            final response = await http.get(Uri.parse(path));
            bytes = response.bodyBytes;
          } else {
            // No celular/Windows, é um arquivo real
            bytes = await File(path).readAsBytes();
          }
          fotosBase64Array.add({
            'base64': base64Encode(bytes),
            'nome': 'foto_${report.id}_$i.jpg',
            'comentario': report.photos[i].comment ?? '',
          });
        } catch (e) {
          debugPrint('Erro ao converter foto $i: $e');
        }
      }
    }
    data['fotosArray'] = fotosBase64Array;
    if (remotePhotos.isNotEmpty) {
      data['fotosJsonExistente'] = remotePhotos;
      data['urlFotosExistente'] = remotePhotos
          .map((photo) => photo['url'])
          .whereType<String>()
          .join(', ');
    }
    if (report.signatureUrl != null && report.signatureUrl!.trim().isNotEmpty) {
      data['urlAssinaturaExistente'] = report.signatureUrl!.trim();
    }

    try {
      // Tenta enviar para a internet seguindo redirects do Apps Script.
      final response = await _postAppsScript(
        Uri.parse(_scriptUrl),
        payload: data,
      );

      if (response.statusCode == 200 || response.statusCode == 302) {
        final decoded = _parseAndValidateResponse(response);
        if (!_isSuccess(decoded)) {
          final errMsg =
              decoded['message'] ?? 'Erro desconhecido no Apps Script';
          throw Exception(errMsg);
        }
      } else {
        throw Exception('Erro na API: status ${response.statusCode}');
      }
    } catch (e) {
      // Se cair aqui, é porque falhou (Sem internet, timeout, etc)
      debugPrint('Falha ao enviar relatório, mantendo offline: $e');
      await _saveOffline(data);

      final errStr = e.toString();
      if (errStr.contains('HTML') ||
          errStr.contains('decodificada') ||
          errStr.contains('JSON')) {
        throw Exception(
          'Falha ao enviar relatório. A API retornou resposta inválida. Verifique a implantação do Apps Script.',
        );
      }
      rethrow; // Propaga para a UI tratar e exibir o SnackBar se necessário
    }
  }

  /// Remove um relatório da planilha do Google Sheets.
  /// Apenas ADM pode chamar esta função (controle feito na UI do Flutter).
  Future<void> deleteReport(
    String reportId,
    String loggedInUser,
    ReportModel report,
  ) async {
    final Map<String, dynamic> data = {
      'acao': 'deletar_relatorio',
      'id': reportId,
      'usuario_logado': loggedInUser,
      'numero_relatorio': report.reportNumber,
      'escola': report.schoolName,
    };
    try {
      final response = await _postAppsScript(
        Uri.parse(_scriptUrl),
        payload: data,
      );
      if (response.statusCode == 200 || response.statusCode == 302) {
        final decoded = _parseAndValidateResponse(response);
        if (_isSuccess(decoded)) {
          debugPrint('Relatório $reportId excluído da nuvem com sucesso!');
        } else {
          final errMsg =
              decoded['message'] ?? 'Erro desconhecido no Apps Script';
          throw Exception(errMsg);
        }
      } else {
        throw Exception(
          'Erro ao excluir da nuvem: status ${response.statusCode}',
        );
      }
    } catch (e) {
      debugPrint(
        'Erro ao excluir relatório da nuvem. Salvando ação offline. Erro: $e',
      );
      await _saveOffline(data);
    }
  }

  /// Busca o histórico de alterações e exclusões (somente ADM).
  Future<List<Map<String, dynamic>>> fetchHistory() async {
    final Map<String, dynamic> data = {'acao': 'buscar_historico'};
    try {
      final http.Response finalResponse = await AppsScriptClient.post(
        data,
        timeout: const Duration(seconds: 40),
      );

      if (finalResponse.statusCode == 200) {
        final decoded = _parseAndValidateResponse(finalResponse);
        if (_isSuccess(decoded)) {
          final rawData = decoded['data'];
          final history = <Map<String, dynamic>>[];

          if (rawData is List) {
            for (final item in rawData) {
              if (item is Map) {
                // Converter Map<dynamic, dynamic> para Map<String, dynamic> com segurança total
                final safeMap = <String, dynamic>{};
                item.forEach((key, value) {
                  safeMap[key.toString()] = value;
                });

                // Normalizar fotos/técnicos/motivos usando JsonUtils e sem cast direto
                safeMap['motivos'] = JsonUtils.asString(
                  safeMap['motivos'] ??
                      safeMap['subjects'] ??
                      safeMap['Motivos / Assuntos'],
                );
                safeMap['tecnicos'] = JsonUtils.asString(
                  safeMap['tecnicos'] ??
                      safeMap['technicians'] ??
                      safeMap['Técnicos Presentes'] ??
                      safeMap['Tecnicos Presentes'],
                );

                // Normalização para fotos/assinaturas
                safeMap['fotosJson'] = JsonUtils.asNullableString(
                  safeMap['fotosJson'] ?? safeMap['fotos_json'],
                );
                safeMap['urlFotos'] = JsonUtils.asNullableString(
                  safeMap['urlFotos'] ??
                      safeMap['photos'] ??
                      safeMap['url_fotos'] ??
                      safeMap['Link Foto'],
                );
                safeMap['urlAssinatura'] = JsonUtils.asNullableString(
                  safeMap['urlAssinatura'] ??
                      safeMap['signatureUrl'] ??
                      safeMap['Link Assinatura'],
                );
                safeMap['materiais_ti_json'] = JsonUtils.asNullableString(
                  safeMap['materiais_ti_json'] ?? safeMap['tiMaterials'],
                );

                history.add(safeMap);
              }
            }
          }
          debugPrint(
            'Histórico recebido e convertido com segurança: ${history.length}',
          );
          return history;
        }
        throw Exception(
          decoded['message']?.toString() ??
              'Erro desconhecido ao buscar histórico',
        );
      }
      throw Exception(
        'Erro HTTP ${finalResponse.statusCode} ao buscar histórico',
      );
    } catch (e) {
      debugPrint('Erro ao buscar histórico: $e');
      rethrow;
    }
  }

  /// Salva ou atualiza os dados na memória do celular quando está offline,
  /// aplicando regras de deduplicação e normalização inteligentes.
  Future<void> _saveOffline(Map<String, dynamic> data) async {
    final List<Map<String, dynamic>> parsedQueue = await _getOfflineQueue();
    final pendingData = Map<String, dynamic>.from(data);
    pendingData['_pendingCreatedAt'] ??= DateTime.now().toIso8601String();

    final String targetId = pendingData['id']?.toString() ?? '';
    if (targetId.isEmpty) {
      debugPrint(
        'Tentativa de salvar operação offline sem ID válido. Ignorado.',
      );
      return;
    }

    final String targetAction =
        pendingData['acao']?.toString() ??
        ''; // 'adicionar' ou 'deletar_relatorio'
    final String targetActionType =
        pendingData['acao_tipo']?.toString() ?? ''; // 'Criar' ou 'Editar'

    bool handled = false;

    if (targetAction == 'deletar_relatorio') {
      // Regra 1: Se for deleção:
      // - Se existia uma criação pendente ('adicionar' e 'Criar') para o mesmo ID,
      //   o relatório nunca foi para a nuvem. Então a gente simplesmente remove a criação
      //   e ignora a deleção (não manda nada para a fila).
      // - Se existia uma edição pendente, removemos a edição e colocamos apenas a deleção.
      final hasPendingCreate = parsedQueue.any(
        (item) =>
            item['id']?.toString() == targetId &&
            item['acao'] == 'adicionar' &&
            item['acao_tipo'] == 'Criar',
      );

      if (hasPendingCreate) {
        parsedQueue.removeWhere((item) => item['id']?.toString() == targetId);
        handled = true;
        debugPrint(
          'Deduplicação offline: Relatório $targetId deletado localmente antes de subir. Fila limpa para este ID.',
        );
      } else {
        parsedQueue.removeWhere((item) => item['id']?.toString() == targetId);
        parsedQueue.add(pendingData);
        handled = true;
        debugPrint(
          'Deduplicação offline: Relatório $targetId marcado para deleção na nuvem. Fila limpa de updates anteriores.',
        );
      }
    } else if (targetAction == 'adicionar') {
      // Regra 2: Se for adicionar (Criar ou Editar):
      // - Se existia uma criação pendente ('adicionar' e 'Criar') para o mesmo ID:
      //   mantemos como 'Criar' mas atualizamos todo o payload com os novos dados.
      // - Se existia um update pendente ('adicionar' e 'Editar') para o mesmo ID:
      //   atualizamos o payload com os novos dados e mantemos como 'Editar'.
      for (int i = 0; i < parsedQueue.length; i++) {
        final item = parsedQueue[i];
        if (item['id']?.toString() == targetId && item['acao'] == 'adicionar') {
          final String originalActionType =
              item['acao_tipo']?.toString() ?? 'Criar';
          final originalPendingCreatedAt = item['_pendingCreatedAt']
              ?.toString();
          parsedQueue[i] = Map<String, dynamic>.from(pendingData);
          parsedQueue[i]['acao_tipo'] = originalActionType;
          if (originalPendingCreatedAt != null &&
              originalPendingCreatedAt.isNotEmpty) {
            parsedQueue[i]['_pendingCreatedAt'] = originalPendingCreatedAt;
          }
          handled = true;
          debugPrint(
            'Deduplicação offline: Payload atualizado da operação "$originalActionType" pendente do relatório $targetId.',
          );
          break;
        }
      }
    }

    if (!handled) {
      parsedQueue.add(pendingData);
      debugPrint(
        'Deduplicação offline: Nova operação "${targetAction == 'adicionar' ? targetActionType : 'Deletar'}" adicionada para o relatório $targetId.',
      );
    }

    await _saveOfflineQueue(parsedQueue);
    if (targetAction == 'adicionar') {
      await _upsertLocalPendingReportFromPayload(
        pendingData,
        syncStatus: targetActionType == 'Editar'
            ? 'pending_update'
            : 'pending_create',
      );
    }
    debugPrint(
      'Relatório salvo na fila offline. Total na fila: ${parsedQueue.length}',
    );
  }

  /// Lê a fila offline de forma segura do SharedPreferences.
  /// Se a chave contiver um tipo incompatível (ex: List salvo por setStringList
  /// em versão antiga), captura o TypeError, limpa a chave corrompida e
  /// retorna lista vazia — sem derrubar a app nem apagar local_reports.
  Future<List<Map<String, dynamic>>> _getOfflineQueue() async {
    final prefs = await SharedPreferences.getInstance();

    try {
      // Primeiro tenta ler como String JSON (formato atual correto)
      final rawString = await LocalStore.getString(_offlineQueueKey);

      if (rawString == null || rawString.trim().isEmpty) {
        // Sem dado na chave principal — verifica chaves legadas
        return await _migrateLegacyQueue(prefs);
      }

      final decoded = jsonDecode(rawString);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }

      // JSON existe mas não é lista — corrompido
      debugPrint('Fila offline não é uma lista JSON. Limpando.');
      await LocalStore.remove(_offlineQueueKey);
      return [];
    } catch (e, stack) {
      // Captura TypeError de cast (List<dynamic> as String?) e qualquer outro erro
      debugPrint(
        'Fila offline corrompida ou tipo incompatível ($_offlineQueueKey). Limpando. Erro: $e',
      );
      debugPrintStack(stackTrace: stack);
      try {
        await LocalStore.remove(_offlineQueueKey);
      } catch (_) {}
      await _cleanupLegacyKeys(prefs);
      return [];
    }
  }

  /// Tenta migrar dados de chaves legadas (StringList ou String antiga) para o
  /// formato atual (String JSON em _offlineQueueKey). Chamado apenas quando a
  /// chave principal está vazia.
  Future<List<Map<String, dynamic>>> _migrateLegacyQueue(
    SharedPreferences prefs,
  ) async {
    for (final key in _legacyOfflineQueueKeys) {
      if (!prefs.containsKey(key)) continue;
      try {
        // Tenta como String JSON
        final asStr = prefs.getString(key);
        if (asStr != null && asStr.trim().isNotEmpty) {
          final decoded = jsonDecode(asStr);
          if (decoded is List) {
            final queue = decoded
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();
            await prefs.remove(key);
            if (queue.isNotEmpty) await _saveOfflineQueue(queue);
            debugPrint(
              'Migrado ${queue.length} item(s) da chave legada "$key".',
            );
            return queue;
          }
        }
      } catch (_) {}
      try {
        // Tenta como StringList
        final asList = prefs.getStringList(key);
        if (asList != null && asList.isNotEmpty) {
          final queue = <Map<String, dynamic>>[];
          for (final itemStr in asList) {
            try {
              final decoded = jsonDecode(itemStr);
              if (decoded is Map) queue.add(Map<String, dynamic>.from(decoded));
            } catch (_) {}
          }
          await prefs.remove(key);
          if (queue.isNotEmpty) await _saveOfflineQueue(queue);
          debugPrint(
            'Migrado ${queue.length} item(s) da StringList legada "$key".',
          );
          return queue;
        }
      } catch (_) {}
      // Chave existe mas não conseguimos ler — remover
      try {
        await prefs.remove(key);
      } catch (_) {}
    }
    return [];
  }

  /// Remove chaves legadas conhecidas (exceto a chave atual) de forma segura.
  Future<void> _cleanupLegacyKeys(SharedPreferences prefs) async {
    for (final key in _legacyOfflineQueueKeys) {
      try {
        if (prefs.containsKey(key)) await prefs.remove(key);
      } catch (_) {}
    }
  }

  /// Salva a fila offline SEMPRE como String JSON usando setString.
  /// Nunca usa setStringList para evitar conflitos de tipo no SharedPreferences.
  Future<void> _saveOfflineQueue(List<Map<String, dynamic>> queue) async {
    if (queue.isEmpty) {
      await LocalStore.remove(_offlineQueueKey);
    } else {
      // setString garante que getString nunca lançará TypeError
      await LocalStore.setString(_offlineQueueKey, jsonEncode(queue));
    }
  }

  Future<List<ReportModel>> _loadLocalReports() async {
    final reportsJson = await LocalStore.getString(_localReportsKey);
    if (reportsJson == null || reportsJson.trim().isEmpty) return [];

    try {
      final decoded = jsonDecode(reportsJson);
      if (decoded is! List) return [];

      final reports = <ReportModel>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          reports.add(ReportModel.fromJson(Map<String, dynamic>.from(item)));
        } catch (e) {
          debugPrint('Erro ao parsear relatÃ³rio local: $e');
        }
      }
      return _dedupeReportsById(reports);
    } catch (e) {
      debugPrint('Erro ao ler $_localReportsKey: $e');
      return [];
    }
  }

  Future<void> _saveLocalReports(List<ReportModel> reports) async {
    final uniqueReports = _dedupeReportsById(reports);
    await LocalStore.setString(
      _localReportsKey,
      jsonEncode(uniqueReports.map((report) => report.toJson()).toList()),
    );
  }

  Future<Set<String>> _ensurePendingReportsInLocalReports(
    List<Map<String, dynamic>> queue,
  ) async {
    final reports = await _loadLocalReports();
    final reportsById = {
      for (final report in reports)
        if (report.id.trim().isNotEmpty) report.id.trim(): report,
    };
    var changed = false;

    for (final payload in queue) {
      final action = (payload['acao'] ?? payload['action'])?.toString() ?? '';
      final canonicalAction = action == 'sendReport' || action == 'updateReport'
          ? 'adicionar'
          : action;
      if (canonicalAction != 'adicionar') {
        continue;
      }

      final id =
          (payload['id'] ?? payload['reportId'] ?? payload['report_id'])
              ?.toString()
              .trim() ??
          '';
      if (id.isEmpty) continue;

      final actionType =
          payload['acao_tipo']?.toString() == 'Editar' ||
              action == 'updateReport'
          ? 'Editar'
          : 'Criar';
      final syncStatus = actionType == 'Editar'
          ? 'pending_update'
          : 'pending_create';
      final existing = reportsById[id];

      if (existing == null) {
        final report = _reportFromOfflinePayload(
          payload,
          syncStatus: syncStatus,
        );
        if (report != null) {
          reportsById[id] = report;
          changed = true;
        }
        continue;
      }

      if (existing.syncStatus != syncStatus) {
        reportsById[id] = existing.copyWith(
          syncStatus: syncStatus,
          localUpdatedAt: existing.localUpdatedAt ?? DateTime.now(),
        );
        changed = true;
      }
    }

    if (changed) {
      await _saveLocalReports(reportsById.values.toList());
    }

    return reportsById.keys.toSet();
  }

  Future<void> _upsertLocalPendingReportFromPayload(
    Map<String, dynamic> payload, {
    required String syncStatus,
  }) async {
    final enrichedPayload = Map<String, dynamic>.from(payload);
    enrichedPayload['acao'] = 'adicionar';
    enrichedPayload['acao_tipo'] = syncStatus == 'pending_update'
        ? 'Editar'
        : 'Criar';
    await _ensurePendingReportsInLocalReports([enrichedPayload]);
  }

  /// Remove APENAS a fila offline corrompida/antiga, sem tocar em local_reports
  /// ou qualquer outro dado do app. Útil para recuperação manual.
  Future<void> clearOfflineQueueOnly() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await LocalStore.remove(_offlineQueueKey);
    } catch (_) {}
    await _cleanupLegacyKeys(prefs);
    debugPrint('Fila offline limpa manualmente via clearOfflineQueueOnly.');
  }

  bool _isValidPendingItem(Map<String, dynamic>? item) {
    if (item == null || item.isEmpty) return false;

    final action = (item['acao'] ?? item['action'] ?? '').toString().trim();
    if (action.isEmpty) return false;

    final id = (item['id'] ?? item['reportId'] ?? item['report_id'] ?? '')
        .toString()
        .trim();
    if (id.isEmpty) return false;

    final status = (item['status'] ?? item['syncStatus'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    if (status == 'synced' || status == 'success') return false;

    if (item['alreadySynced'] == true) return false;

    return true;
  }

  Future<int> cleanupAllOfflineQueuesAndReturnCount() async {
    final prefs = await SharedPreferences.getInstance();

    // Obter IDs dos relatórios locais para verificação

    final List<Map<String, dynamic>> consolidatedQueue = [];

    // Lista de todas as chaves de filas a inspecionar
    final List<String> allKeysToClean = [
      _offlineQueueKey,
      'pending_schools',
      'pending_technicians',
      'offline_schools',
      'offline_technicians',
      'pending_deletes',
      'deleted_reports',
      'unsynced_reports',
      'pending_operations',
      ..._legacyOfflineQueueKeys,
    ];

    for (final key in allKeysToClean) {
      // A fila principal fica no LocalStore (IndexedDB na web); as demais
      // chaves são legadas e ficam no SharedPreferences.
      final isMainQueue = key == _offlineQueueKey;
      if (!isMainQueue && !prefs.containsKey(key)) continue;

      try {
        final Object? value = isMainQueue
            ? await LocalStore.getString(key)
            : prefs.get(key);
        if (value == null) continue;
        List<dynamic> rawItems = [];

        if (value is List) {
          rawItems = value;
        } else if (value is String) {
          if (value.trim().isNotEmpty) {
            final decoded = jsonDecode(value);
            if (decoded is List) {
              rawItems = decoded;
            } else if (decoded is Map) {
              rawItems = [decoded];
            }
          }
        }

        final List<Map<String, dynamic>> validItems = [];
        for (var item in rawItems) {
          if (item is! Map) continue;
          final mapItem = Map<String, dynamic>.from(item);

          if (!_isValidPendingItem(mapItem)) {
            continue;
          }

          validItems.add(mapItem);
        }

        if (validItems.isEmpty) {
          if (isMainQueue) {
            await LocalStore.remove(key);
          } else {
            await prefs.remove(key);
          }
        } else {
          if (key == _offlineQueueKey) {
            consolidatedQueue.addAll(validItems);
          } else {
            consolidatedQueue.addAll(validItems);
            await prefs.remove(key);
          }
        }
      } catch (e) {
        debugPrint(
          'cleanupAllOfflineQueuesAndReturnCount: Erro ao limpar a chave $key: $e. Removendo chave.',
        );
        // Não apaga a fila principal por causa de um erro de leitura.
        if (!isMainQueue) {
          try {
            await prefs.remove(key);
          } catch (_) {}
        }
      }
    }

    await _ensurePendingReportsInLocalReports(consolidatedQueue);
    final List<Map<String, dynamic>> normalizedQueue =
        _normalizeConsolidatedQueue(consolidatedQueue);
    await _saveOfflineQueue(normalizedQueue);

    return normalizedQueue.length;
  }

  List<Map<String, dynamic>> _normalizeConsolidatedQueue(
    List<Map<String, dynamic>> queue,
  ) {
    List<Map<String, dynamic>> parsedQueue = [];
    for (var item in queue) {
      final action = (item['acao'] ?? item['action'] ?? '').toString().trim();
      if (action.isEmpty) continue;

      final id = (item['id'] ?? item['reportId'] ?? item['report_id'] ?? '')
          .toString()
          .trim();
      if (id.isEmpty) continue;

      final canonicalAction = action == 'sendReport' || action == 'updateReport'
          ? 'adicionar'
          : action == 'deleteReport' || action == 'deletar_relatorio'
          ? 'deletar_relatorio'
          : action;

      item['acao'] = canonicalAction;
      item['id'] = id;
      if (canonicalAction == 'adicionar' &&
          (item['acao_tipo'] == null ||
              item['acao_tipo'].toString().trim().isEmpty)) {
        item['acao_tipo'] = action == 'sendReport' ? 'Criar' : 'Editar';
      }
      parsedQueue.add(item);
    }

    final Map<String, List<Map<String, dynamic>>> opsById = {};
    for (final item in parsedQueue) {
      final id = item['id'].toString();
      opsById.putIfAbsent(id, () => []).add(item);
    }

    final List<Map<String, dynamic>> normalizedList = [];

    opsById.forEach((id, ops) {
      if (ops.isEmpty) return;
      if (ops.length == 1) {
        normalizedList.add(ops.first);
        return;
      }

      Map<String, dynamic>? currentOp;
      for (final nextOp in ops) {
        if (currentOp == null) {
          currentOp = nextOp;
          continue;
        }

        final currAcao = currentOp['acao']?.toString();
        final currAcaoTipo = currentOp['acao_tipo']?.toString();
        final nextAcao = nextOp['acao']?.toString();
        final nextAcaoTipo = nextOp['acao_tipo']?.toString();

        if (currAcao == 'adicionar' && currAcaoTipo == 'Criar') {
          if (nextAcao == 'adicionar' && nextAcaoTipo == 'Editar') {
            currentOp = Map<String, dynamic>.from(nextOp);
            currentOp['acao_tipo'] = 'Criar';
          } else if (nextAcao == 'deletar_relatorio') {
            currentOp = null;
          } else {
            currentOp = nextOp;
          }
        } else if (currAcao == 'adicionar' && currAcaoTipo == 'Editar') {
          if (nextAcao == 'adicionar' && nextAcaoTipo == 'Editar') {
            currentOp = nextOp;
          } else if (nextAcao == 'deletar_relatorio') {
            currentOp = nextOp;
          } else {
            currentOp = nextOp;
          }
        } else if (currAcao == 'deletar_relatorio') {
          if (nextAcao == 'adicionar' && nextAcaoTipo == 'Criar') {
            currentOp = nextOp;
          } else if (nextAcao == 'adicionar' && nextAcaoTipo == 'Editar') {
            currentOp = nextOp;
          } else {
            currentOp = nextOp;
          }
        } else {
          currentOp = nextOp;
        }
      }

      if (currentOp != null) {
        normalizedList.add(currentOp);
      }
    });

    return normalizedList;
  }

  /// Normaliza a fila offline conforme as regras de negócio inteligentes do aplicativo
  Future<List<Map<String, dynamic>>> normalizeOfflineQueue() async {
    final List<Map<String, dynamic>> rawQueue = await _getOfflineQueue();

    // Obter IDs dos relatórios locais para verificação
    final localReportIds = await _ensurePendingReportsInLocalReports(rawQueue);

    List<Map<String, dynamic>> parsedQueue = [];
    for (final mapItem in rawQueue) {
      if (!_isValidPendingItem(mapItem)) {
        continue;
      }

      final action = (mapItem['acao'] ?? mapItem['action'] ?? '')
          .toString()
          .trim();
      if (action.isEmpty) continue;

      final id =
          (mapItem['id'] ?? mapItem['reportId'] ?? mapItem['report_id'] ?? '')
              .toString()
              .trim();
      if (id.isEmpty) continue;

      final canonicalAction = action == 'sendReport' || action == 'updateReport'
          ? 'adicionar'
          : action == 'deleteReport' || action == 'deletar_relatorio'
          ? 'deletar_relatorio'
          : action;

      // Regra: remover item cujo relatório não existe e action não é delete
      final isReportAction =
          canonicalAction == 'adicionar' ||
          canonicalAction == 'deletar_relatorio';
      if (isReportAction &&
          canonicalAction != 'deletar_relatorio' &&
          !localReportIds.contains(id)) {
        continue;
      }

      mapItem['acao'] = canonicalAction;
      mapItem['id'] = id;
      if (canonicalAction == 'adicionar' &&
          (mapItem['acao_tipo'] == null ||
              mapItem['acao_tipo'].toString().trim().isEmpty)) {
        mapItem['acao_tipo'] = action == 'sendReport' ? 'Criar' : 'Editar';
      }
      parsedQueue.add(mapItem);
    }

    // Mapear operações por ID para condensar de acordo com as regras solicitadas
    final Map<String, List<Map<String, dynamic>>> opsById = {};
    for (final item in parsedQueue) {
      final id = item['id'].toString();
      opsById.putIfAbsent(id, () => []).add(item);
    }

    final List<Map<String, dynamic>> normalizedList = [];

    opsById.forEach((id, ops) {
      if (ops.isEmpty) return;
      if (ops.length == 1) {
        normalizedList.add(ops.first);
        return;
      }

      Map<String, dynamic>? currentOp;
      for (final nextOp in ops) {
        if (currentOp == null) {
          currentOp = nextOp;
          continue;
        }

        final currAcao = currentOp['acao']?.toString();
        final currAcaoTipo = currentOp['acao_tipo']?.toString();
        final nextAcao = nextOp['acao']?.toString();
        final nextAcaoTipo = nextOp['acao_tipo']?.toString();

        if (currAcao == 'adicionar' && currAcaoTipo == 'Criar') {
          if (nextAcao == 'adicionar' && nextAcaoTipo == 'Editar') {
            // create + update = create com dados mais recentes
            currentOp = Map<String, dynamic>.from(nextOp);
            currentOp['acao_tipo'] = 'Criar';
          } else if (nextAcao == 'deletar_relatorio') {
            // create + delete antes de subir = remover tudo
            currentOp = null;
          } else {
            currentOp = nextOp;
          }
        } else if (currAcao == 'adicionar' && currAcaoTipo == 'Editar') {
          if (nextAcao == 'adicionar' && nextAcaoTipo == 'Editar') {
            // update + update = último update
            currentOp = nextOp;
          } else if (nextAcao == 'deletar_relatorio') {
            // update + delete = delete
            currentOp = nextOp;
          } else {
            currentOp = nextOp;
          }
        } else if (currAcao == 'deletar_relatorio') {
          if (nextAcao == 'adicionar' && nextAcaoTipo == 'Criar') {
            // delete + create = manter a última válida
            currentOp = nextOp;
          } else if (nextAcao == 'adicionar' && nextAcaoTipo == 'Editar') {
            currentOp = nextOp;
          } else {
            currentOp = nextOp;
          }
        } else {
          currentOp = nextOp;
        }
      }

      if (currentOp != null) {
        normalizedList.add(currentOp);
      }
    });

    await _saveOfflineQueue(normalizedList);
    return normalizedList;
  }

  /// Tenta enviar uma operação individual para o Apps Script
  Map<String, dynamic> _payloadForSync(Map<String, dynamic> op) {
    final payload = Map<String, dynamic>.from(op);
    payload.removeWhere((key, _) => key.startsWith('_pending'));
    return payload;
  }

  Future<Map<String, dynamic>> _sendOperation(Map<String, dynamic> op) async {
    final decoded = await _postJson(
      _payloadForSync(op),
      timeout: const Duration(seconds: 40),
    );
    if (!_isSuccessResponse(decoded)) {
      final msg = decoded['message']?.toString() ?? '';
      final action = op['acao']?.toString() ?? '';

      // Se for deleção e o relatório já não existe no Sheets, consideramos sincronizado com sucesso!
      if (action == 'deletar_relatorio' &&
          (msg.toLowerCase().contains('não encontrado') ||
              msg.toLowerCase().contains('nao encontrado'))) {
        debugPrint(
          'Deleção offline: Relatório já não existe no Sheets. Tratando como sucesso.',
        );
        return {'status': 'success', 'success': true, 'message': msg};
      }

      throw Exception(
        msg.isNotEmpty ? msg : 'Erro desconhecido no Apps Script',
      );
    }
    return decoded;
  }

  bool _sameQueueItem(Map<String, dynamic> a, Map<String, dynamic> b) {
    return a['id']?.toString() == b['id']?.toString() &&
        a['acao']?.toString() == b['acao']?.toString() &&
        a['acao_tipo']?.toString() == b['acao_tipo']?.toString();
  }

  Future<List<Map<String, dynamic>>> _removeReportsAlreadyInSheets(
    List<Map<String, dynamic>> queue,
  ) async {
    final candidateIds = queue
        .map((op) => op['id']?.toString().trim() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    if (candidateIds.isEmpty) return queue;

    try {
      final cloudReports = await fetchReports();
      final cloudIds = cloudReports.map((report) => report.id.trim()).toSet();
      return queue.where((op) {
        final action = op['acao']?.toString() ?? '';
        final id = op['id']?.toString().trim() ?? '';
        if (action != 'deletar_relatorio' && cloudIds.contains(id)) {
          debugPrint(
            'Relatorio $id ja existe no Sheets. Removendo da fila offline.',
          );
          return false;
        }
        if (action == 'deletar_relatorio' && !cloudIds.contains(id)) {
          debugPrint(
            'Relatorio $id ja nao existe no Sheets. Removendo delete da fila offline.',
          );
          return false;
        }
        return true;
      }).toList();
    } catch (e) {
      debugPrint(
        'Nao foi possivel confirmar relatorios ja enviados no Sheets: $e',
      );
      return queue;
    }
  }

  Future<void> _markLocalReportsSynced(Set<String> syncedIds) async {
    if (syncedIds.isEmpty) return;

    final reportsJson = await LocalStore.getString('local_reports');
    if (reportsJson == null || reportsJson.trim().isEmpty) return;

    try {
      final decoded = jsonDecode(reportsJson);
      if (decoded is! List) return;

      var changed = false;
      final now = DateTime.now();
      final updatedReports = <Map<String, dynamic>>[];

      for (final item in decoded) {
        if (item is! Map) continue;

        final map = Map<String, dynamic>.from(item);
        final id = map['id']?.toString().trim() ?? '';
        if (syncedIds.contains(id)) {
          map['syncStatus'] = 'synced';
          map['lastSyncedAt'] = now.toIso8601String();
          map.remove('pending');
          map.remove('isPending');
          map.remove('needsSync');
          changed = true;
        }
        updatedReports.add(map);
      }

      if (changed) {
        await LocalStore.setString('local_reports', jsonEncode(updatedReports));
        debugPrint(
          'local_reports atualizado como synced: ${syncedIds.length} item(s)',
        );
      }
    } catch (e) {
      debugPrint('Erro ao marcar local_reports como sincronizado: $e');
    }
  }

  /// Sincroniza a fila offline enviando item a item
  Future<void> syncOfflineData() async {
    final queue = await normalizeOfflineQueue();

    if (queue.isEmpty) {
      return;
    }

    var remaining = List<Map<String, dynamic>>.from(queue);
    final syncedIds = <String>{};

    for (final op in queue) {
      final id = op['id']?.toString() ?? '';
      final action = op['acao']?.toString() ?? '';

      try {
        final decoded = await _sendOperation(op);
        if (_isSuccessResponse(decoded)) {
          remaining.removeWhere((item) => _sameQueueItem(item, op));
          if (action != 'deletar_relatorio' && id.isNotEmpty) {
            syncedIds.add(id);
          }
          await _markLocalReportsSynced(syncedIds);
          await _saveOfflineQueue(remaining);
        }
      } catch (e) {
        debugPrint('Falha ao sincronizar op $id: $e');
      }
    }

    final beforeReconcileIds = remaining
        .where((op) => op['acao']?.toString() != 'deletar_relatorio')
        .map((op) => op['id']?.toString().trim() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    remaining = await _removeReportsAlreadyInSheets(remaining);
    final afterReconcileIds = remaining
        .where((op) => op['acao']?.toString() != 'deletar_relatorio')
        .map((op) => op['id']?.toString().trim() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    syncedIds.addAll(beforeReconcileIds.difference(afterReconcileIds));
    await _markLocalReportsSynced(syncedIds);
    await _saveOfflineQueue(remaining);
  }

  /// Aliases mantidos para chamadas antigas de sincronizacao offline.
  Future<void> syncOfflineQueue() => syncOfflineData();

  Future<void> syncPendingReports() => syncOfflineData();

  Future<void> syncReportsBatch() async {
    final queue = await normalizeOfflineQueue();

    if (queue.isEmpty) {
      return;
    }

    try {
      final decoded = await _postJson({
        'action': 'syncReportsBatch',
        'reports': queue.map(_payloadForSync).toList(),
      }, timeout: const Duration(seconds: 80));

      List<Map<String, dynamic>> remaining;
      if (_isSuccessResponse(decoded)) {
        remaining = [];
      } else {
        remaining = _failedBatchItems(queue, decoded);
        remaining = await _removeReportsAlreadyInSheets(remaining);
      }

      final remainingIds = remaining
          .where((op) => op['acao']?.toString() != 'deletar_relatorio')
          .map((op) => op['id']?.toString().trim() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();
      final syncedIds = queue
          .where((op) => op['acao']?.toString() != 'deletar_relatorio')
          .map((op) => op['id']?.toString().trim() ?? '')
          .where((id) => id.isNotEmpty && !remainingIds.contains(id))
          .toSet();
      await _markLocalReportsSynced(syncedIds);
      await _saveOfflineQueue(remaining);
    } catch (e) {
      debugPrint('Falha ao sincronizar lote offline: $e');
      rethrow;
    }
  }

  List<Map<String, dynamic>> _failedBatchItems(
    List<Map<String, dynamic>> queue,
    Map<String, dynamic> decoded,
  ) {
    final results = decoded['results'];
    if (results is! List || results.isEmpty) return queue;

    final failed = <Map<String, dynamic>>[];
    final queueById = {
      for (final item in queue)
        if ((item['id']?.toString().trim() ?? '').isNotEmpty)
          item['id'].toString().trim(): item,
    };

    for (var i = 0; i < results.length; i++) {
      final item = results[i];
      if (_isSuccessResponse(item)) continue;

      Map<String, dynamic>? failedOp;
      if (item is Map) {
        final id = (item['id'] ?? item['reportId'] ?? item['report_id'])
            ?.toString()
            .trim();
        if (id != null && id.isNotEmpty) {
          failedOp = queueById[id];
        }
      }
      failed.add(failedOp ?? (i < queue.length ? queue[i] : queue.last));
    }

    return failed;
  }

  /// Limpa chaves legadas e antigas do SharedPreferences (metodo publico mantido
  /// por compatibilidade, delega ao helper privado).
  Future<void> cleanupLegacyOfflineQueueKeys() async {
    final prefs = await SharedPreferences.getInstance();
    await _cleanupLegacyKeys(prefs);
  }

  Future<Map<String, dynamic>> _postJson(
    Map<String, dynamic> data, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final response = await _postAppsScript(
      Uri.parse(_scriptUrl),
      payload: data,
      timeout: timeout,
    );

    if (response.statusCode == 200 ||
        response.statusCode == 302 ||
        response.statusCode == 301 ||
        response.statusCode == 303) {
      return _parseAndValidateResponse(response);
    }
    throw Exception('Erro HTTP ${response.statusCode}');
  }

  Future<http.Response> _postAppsScript(
    Uri uri, {
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 45),
  }) {
    // `uri` é mantido só por compatibilidade com os chamadores antigos.
    return AppsScriptClient.post(payload, timeout: timeout);
  }

  bool _isSuccessResponse(dynamic decoded) {
    if (decoded is! Map) return false;

    final status = decoded['status']?.toString().toLowerCase().trim();
    final success = decoded['success'];

    if (status == 'success') return true;
    if (success == true) return true;
    if (success?.toString().toLowerCase() == 'true') return true;

    final results = decoded['results'];
    if (results is List && results.isNotEmpty) {
      return results.every((item) {
        if (item is! Map) return false;
        final itemStatus = item['status']?.toString().toLowerCase().trim();
        final itemSuccess = item['success'];
        return itemStatus == 'success' ||
            itemSuccess == true ||
            itemSuccess?.toString().toLowerCase() == 'true';
      });
    }

    return false;
  }

  bool _isSuccess(Map<String, dynamic> decoded) {
    return _isSuccessResponse(decoded);
  }

  List<Map<String, dynamic>> _readMapList(dynamic rawData, String context) {
    final list = <Map<String, dynamic>>[];
    if (rawData == null) return list;
    if (rawData is! List) {
      throw Exception('Apps Script retornou data invalido em $context');
    }

    for (final item in rawData) {
      if (item is Map) {
        list.add(Map<String, dynamic>.from(item));
      }
    }
    return list;
  }

  /// Retorna o número de itens na fila offline aguardando sincronização.
  /// Nunca lança exceção: se a fila estiver corrompida, retorna 0.
  Future<int> getPendingSyncCount() async {
    try {
      final queue = await normalizeOfflineQueue();
      return queue.length;
    } catch (e) {
      debugPrint('Erro ao contar pendências offline (fila inválida): $e');
      return 0;
    }
  }

  /// Retorna os IDs dos relatórios pendentes de criação
  Future<List<PendingSyncItem>> getPendingSyncItems() async {
    final queue = await normalizeOfflineQueue();
    if (queue.isEmpty) return [];

    final localReports = await _loadLocalReports();
    final reportsById = {for (final report in localReports) report.id: report};

    return queue.map((op) {
      final id = (op['id'] ?? op['reportId'] ?? op['report_id'] ?? '')
          .toString()
          .trim();
      final action = (op['acao'] ?? op['action'] ?? '').toString().trim();
      final actionType = (op['acao_tipo'] ?? '').toString().trim();
      final report = reportsById[id];
      final queuedAt =
          _pendingQueuedAt(op) ??
          report?.localUpdatedAt ??
          report?.updatedAt ??
          report?.lastSyncedAt;

      return PendingSyncItem(
        id: id,
        entityType: _pendingEntityType(action),
        actionLabel: _pendingActionLabel(action, actionType),
        reportNumber: ReportModel.asString(
          op['numero_relatorio'] ??
              op['reportNumber'] ??
              op['numeroRelatorio'] ??
              report?.reportNumber ??
              id,
        ),
        title: ReportModel.asString(
          op['escola'] ??
              op['schoolName'] ??
              op['nome'] ??
              op['name'] ??
              report?.schoolName ??
              'Item sem nome',
        ),
        queuedAt: queuedAt,
        status: 'Pendente',
        rawData: Map<String, dynamic>.from(op),
      );
    }).toList()..sort((a, b) {
      final aDate = a.queuedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bDate = b.queuedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bDate.compareTo(aDate);
    });
  }

  String _pendingEntityType(String action) {
    final lower = action.toLowerCase();
    if (lower.contains('escola')) return 'Escola';
    if (lower.contains('tecnico') || lower.contains('técnico')) {
      return 'Técnico';
    }
    return 'Relatório';
  }

  String _pendingActionLabel(String action, String actionType) {
    final lowerAction = action.toLowerCase();
    final lowerType = actionType.toLowerCase();
    if (lowerAction.contains('deletar') || lowerAction.contains('delete')) {
      return 'Excluir';
    }
    if (lowerType.contains('criar') || lowerAction == 'sendreport') {
      return 'Criar';
    }
    if (lowerType.contains('editar') || lowerAction.contains('update')) {
      return 'Editar';
    }
    return 'Editar';
  }

  DateTime? _pendingQueuedAt(Map<String, dynamic> op) {
    final candidates = [
      op['_pendingCreatedAt'],
      op['queuedAt'],
      op['createdAt'],
      op['created_at'],
      op['data_pendencia'],
      op['timestamp'],
      op['localUpdatedAt'],
      op['updatedAt'],
    ];

    for (final value in candidates) {
      final text = ReportModel.asString(value).trim();
      if (text.isEmpty) continue;
      final parsed = DateTime.tryParse(text);
      if (parsed != null) return parsed;
    }
    return null;
  }

  Future<Set<String>> getPendingCreateIds() async {
    final queue = await normalizeOfflineQueue();
    Set<String> ids = {};
    for (final item in queue) {
      try {
        if (item['acao'] == 'adicionar' && item['acao_tipo'] == 'Criar') {
          final id = item['id']?.toString();
          if (id != null && id.isNotEmpty) {
            ids.add(id);
          }
        }
      } catch (e) {
        debugPrint('Erro ao parsear item da fila offline: $e');
      }
    }
    return ids;
  }

  /// Retorna os IDs dos relatórios pendentes de edição/atualização
  Future<Set<String>> getPendingUpdateIds() async {
    final queue = await normalizeOfflineQueue();
    Set<String> ids = {};
    for (final item in queue) {
      try {
        if (item['acao'] == 'adicionar' && item['acao_tipo'] == 'Editar') {
          final id = item['id']?.toString();
          if (id != null && id.isNotEmpty) {
            ids.add(id);
          }
        }
      } catch (e) {
        debugPrint('Erro ao parsear item da fila offline: $e');
      }
    }
    return ids;
  }

  /// Retorna os IDs dos relatórios pendentes de exclusão
  Future<Set<String>> getPendingDeleteIds() async {
    final queue = await normalizeOfflineQueue();
    Set<String> ids = {};
    for (final item in queue) {
      try {
        if (item['acao'] == 'deletar_relatorio') {
          final id = item['id']?.toString();
          if (id != null && id.isNotEmpty) {
            ids.add(id);
          }
        }
      } catch (e) {
        debugPrint('Erro ao parsear item da fila offline: $e');
      }
    }
    return ids;
  }

  /// Retorna os relatórios locais que possuem pendências de criação ou edição
  Future<List<ReportModel>> getPendingCreateOrUpdateReports() async {
    final createIds = await getPendingCreateIds();
    final updateIds = await getPendingUpdateIds();
    final pendingIds = {...createIds, ...updateIds};
    if (pendingIds.isEmpty) return [];

    final reportsById = <String, ReportModel>{};
    try {
      final String? reportsJson = await LocalStore.getString('local_reports');
      if (reportsJson != null) {
        final List<dynamic> decodedList = jsonDecode(reportsJson);
        for (var item in decodedList) {
          try {
            final report = ReportModel.fromJson(
              Map<String, dynamic>.from(item),
            );
            if (pendingIds.contains(report.id)) {
              reportsById[report.id] = report;
            }
          } catch (e) {
            debugPrint('Erro ao parsear relatório local: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('Erro ao ler local_reports: $e');
    }

    final queue = await normalizeOfflineQueue();
    for (final payload in queue) {
      try {
        final id = payload['id']?.toString() ?? '';
        if (!pendingIds.contains(id) || reportsById.containsKey(id)) continue;

        final report = _reportFromOfflinePayload(
          payload,
          syncStatus: createIds.contains(id)
              ? 'pending_create'
              : 'pending_update',
        );
        if (report != null) {
          reportsById[id] = report;
        }
      } catch (e) {
        debugPrint('Erro ao reconstruir relatÃ³rio pendente da fila: $e');
      }
    }

    return reportsById.values.toList();
  }

  /// Retorna a lista de relatórios locais cujos IDs estão na fila de sincronização pendente
  Future<List<ReportModel>> getPendingOfflineReports() async {
    final queue = await normalizeOfflineQueue();
    Set<String> pendingIds = {};
    for (final item in queue) {
      try {
        if (item['acao'] == 'adicionar') {
          final id = item['id']?.toString();
          if (id != null && id.isNotEmpty) {
            pendingIds.add(id);
          }
        }
      } catch (e) {
        debugPrint('Erro ao parsear item da fila offline: $e');
      }
    }

    if (pendingIds.isEmpty) return [];

    List<ReportModel> localReports = [];
    try {
      final String? reportsJson = await LocalStore.getString('local_reports');
      if (reportsJson != null) {
        final List<dynamic> decodedList = jsonDecode(reportsJson);
        for (var item in decodedList) {
          try {
            if (item is! Map) continue;
            localReports.add(
              ReportModel.fromJson(Map<String, dynamic>.from(item)),
            );
          } catch (e) {
            debugPrint('Erro ao parsear relatório local: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('Erro ao ler local_reports: $e');
    }

    return localReports.where((r) => pendingIds.contains(r.id)).toList();
  }

  ReportModel? _reportFromOfflinePayload(
    Map<String, dynamic> payload, {
    required String syncStatus,
  }) {
    final id = payload['id']?.toString().trim() ?? '';
    if (id.isEmpty) return null;

    final fotosArray = payload['fotosArray'];
    final photos = <PhotoItem>[];
    if (fotosArray is List) {
      for (final item in fotosArray) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final base64 = map['base64']?.toString();
        if (base64 == null || base64.isEmpty) continue;
        photos.add(
          PhotoItem(path: base64, comment: map['comentario']?.toString()),
        );
      }
    }

    // Normalização rigorosa conforme Regra 5:
    final normalizedSubjects = JsonUtils.asStringList(
      payload['subjects'] ?? payload['motivos'],
    );
    final normalizedTechnicians = JsonUtils.asStringList(
      payload['technicians'] ?? payload['tecnicos'],
    );

    final normalizedUrlFotos = JsonUtils.asNullableString(
      payload['urlFotos'] ?? payload['Link Foto'],
    );
    final normalizedFotosJson = JsonUtils.asNullableString(
      payload['fotosJson'] ?? payload['fotos_json'],
    );
    final normalizedSignatureUrl = JsonUtils.asNullableString(
      payload['signatureUrl'] ?? payload['urlAssinatura'],
    );

    return ReportModel.fromJson({
      'id': id,
      'reportNumber': payload['numero_relatorio'],
      'creator': payload['usuario_logado'],
      'schoolName': payload['escola'],
      'schoolAddress': payload['endereco_escola'],
      'schoolCity': payload['municipio'],
      'schoolInep': payload['inep'],
      'visitDate': payload['data_visita'],
      'tipo': payload['tipo_relatorio'],
      'subjects': normalizedSubjects,
      'motivos': normalizedSubjects,
      'observations': payload['observacoes'],
      'materiais_ti_json':
          payload['materiais_ti_json'] ??
          payload['materiaisTiJson'] ??
          payload['tiMaterials'],
      'gre': payload['gre'],
      'technicians': normalizedTechnicians,
      'tecnicos': normalizedTechnicians,
      'responsiblePerson': payload['responsavel'],
      'signatureBytes': payload['assinaturaBase64'],
      'signatureBytesList': payload['signatureBytesList'],
      'assinaturaBase64List': payload['assinaturaBase64List'],
      'signatureUrl': normalizedSignatureUrl,
      'signatureUrlList': payload['signatureUrlList'],
      'urlAssinatura': normalizedSignatureUrl,
      'photos': photos.map((photo) => photo.toJson()).toList(),
      'urlFotos': normalizedUrlFotos,
      'fotosJson': normalizedFotosJson,
      'fotos_json': normalizedFotosJson,
      'syncStatus': syncStatus,
      'localUpdatedAt': DateTime.now().toIso8601String(),
    });
  }

  // ============================================================================
  // SINCRONIZAÇÃO DE ESCOLAS E TÉCNICOS
  // ============================================================================

  Future<void> sendSchool(SchoolModel school, String acao) async {
    final Map<String, dynamic> data = {
      'acao': acao, // 'salvar_escola' ou 'deletar_escola'
      'id': school.id,
      'inep': school.inep,
      'nome': school.name,
      'endereco': school.address,
      'municipio': school.city,
      'uf': school.uf,
      'gre': school.gre,
    };
    try {
      await _postAppsScript(Uri.parse(_scriptUrl), payload: data);
    } catch (e) {
      debugPrint('Erro ao sincronizar escola: $e');
    }
  }

  Future<List<SchoolModel>> fetchSchools() async {
    final Map<String, dynamic> data = {'acao': 'buscar_escolas'};
    try {
      final decoded = await _postJson(
        data,
        timeout: const Duration(seconds: 40),
      );
      if (_isSuccess(decoded)) {
        return _readMapList(
          decoded['data'],
          'fetchSchools',
        ).map((item) => SchoolModel.fromJson(item)).toList();
      }
    } catch (e) {
      debugPrint('Erro ao buscar escolas: $e');
    }
    return [];
  }

  /// Login validado no servidor (PWA): a senha não fica gravada no navegador.
  /// Devolve o técnico logado, ou null se e-mail/senha estiverem incorretos.
  /// Lança exceção se não for possível falar com o servidor.
  Future<TechnicianModel?> loginRemote(String email, String senha) async {
    final response = await _postAppsScript(
      Uri.parse(_scriptUrl),
      payload: {'acao': 'login', 'email': email, 'senha': senha},
      timeout: const Duration(seconds: 40),
    );
    if (response.statusCode != 200) {
      throw Exception('Servidor respondeu HTTP ${response.statusCode}');
    }
    final decoded = _parseAndValidateResponse(response);
    if (!_isSuccess(decoded)) return null;

    final token = decoded['token']?.toString();
    AppsScriptClient.sessionToken =
        (token != null && token.isNotEmpty) ? token : null;

    final t = decoded['tecnico'];
    if (t is! Map) return null;
    return TechnicianModel(
      id: t['id']?.toString() ?? '',
      name: fixMojibake(t['nome']?.toString() ?? ''),
      registration: fixMojibake(t['matricula']?.toString() ?? ''),
      email: t['email']?.toString() ?? '',
      permissions: t['permissao']?.toString() ?? 'USR',
    );
  }

  static final Map<String, Uint8List> _driveFileCache = {};

  /// Baixa um arquivo da pasta de fotos pelo Apps Script (base64). Necessário
  /// no navegador, onde o Drive bloqueia o download direto (CORS).
  Future<Uint8List?> fetchDriveFileBytes(String urlOrId) async {
    final key = urlOrId.trim();
    if (key.isEmpty) return null;
    final cached = _driveFileCache[key];
    if (cached != null) return cached;
    try {
      final response = await _postAppsScript(
        Uri.parse(_scriptUrl),
        payload: {'acao': 'buscar_arquivo', 'id': key},
        timeout: const Duration(seconds: 40),
      );
      if (response.statusCode != 200) return null;
      final decoded = _parseAndValidateResponse(response);
      if (!_isSuccess(decoded)) return null;
      final b64 = decoded['base64']?.toString() ?? '';
      if (b64.isEmpty) return null;
      final bytes = base64Decode(b64);
      _driveFileCache[key] = bytes;
      return bytes;
    } catch (e) {
      debugPrint('Falha ao baixar arquivo do Drive: $e');
      return null;
    }
  }

  Future<void> sendTechnician(TechnicianModel tech, String acao) async {
    debugPrint('Usando aba de técnicos: ${Constants.techniciansSheetName}');
    final Map<String, dynamic> data = {
      'acao': acao, // 'salvar_tecnico' ou 'deletar_tecnico'
      'sheetName': Constants.techniciansSheetName,
      'id': tech.id,
      'nome': tech.name,
      'matricula': tech.registration,
      'email': tech.email,
      'permissao': tech.permissions,
      'senha': tech.password,
    };
    try {
      await _postAppsScript(Uri.parse(_scriptUrl), payload: data);
    } catch (e) {
      debugPrint('Erro ao sincronizar tecnico: $e');
    }
  }

  // ============================================================================
  // SINCRONIZAÇÃO DE VERSÃO
  // ============================================================================
  Future<Map<String, dynamic>> checkVersion() async {
    final Map<String, dynamic> data = {'acao': 'checar_versao'};
    try {
      final http.Response finalResponse = await AppsScriptClient.post(
        data,
        timeout: const Duration(seconds: 30),
      );

      if (finalResponse.statusCode == 200) {
        final decoded = _parseAndValidateResponse(finalResponse);
        if (_isSuccess(decoded)) {
          final Map<String, dynamic> resultMap = {};
          decoded.forEach((key, value) {
            resultMap[key.toString()] = value;
          });
          return resultMap;
        }
      }
    } catch (e) {
      debugPrint('Erro ao checar versão: $e');
    }
    return {};
  }

  List<ReportModel> _dedupeReportsById(List<ReportModel> reports) {
    final byId = <String, ReportModel>{};
    for (final report in reports) {
      final id = report.id.trim();
      if (id.isEmpty) continue;

      final existing = byId[id];
      if (existing == null) {
        byId[id] = report;
        continue;
      }

      final existingDate =
          existing.updatedAt ??
          existing.localUpdatedAt ??
          existing.lastSyncedAt ??
          existing.visitDate;
      final newDate =
          report.updatedAt ??
          report.localUpdatedAt ??
          report.lastSyncedAt ??
          report.visitDate;
      if (newDate.isAfter(existingDate) ||
          newDate.isAtSameMomentAs(existingDate)) {
        byId[id] = report;
      }
    }
    return byId.values.toList();
  }

  // ============================================================================
  // BUSCAR RELATÓRIOS DA NUVEM
  // ============================================================================
  Future<List<ReportModel>> fetchReports() async {
    final Map<String, dynamic> data = {
      'action': 'buscar_relatorios',
      'payload': <String, dynamic>{},
    };
    try {
      final http.Response finalResponse = await AppsScriptClient.post(
        data,
        timeout: const Duration(seconds: 40),
      );

      if (finalResponse.statusCode == 200) {
        final body = utf8.decode(finalResponse.bodyBytes);

        if (body.trimLeft().startsWith('<')) {
          throw Exception('Apps Script retornou HTML em vez de JSON.');
        }

        final decoded = fixMojibakeDeep(jsonDecode(body));
        if (decoded is! Map) {
          throw Exception('Resposta JSON inesperada do Apps Script');
        }

        final ok = _isSuccessResponse(decoded);

        if (!ok) {
          throw Exception(
            decoded['message'] ??
                decoded['error'] ??
                'Erro ao baixar relatórios',
          );
        }

        // Garante que escolas estejam carregadas antes de inferir município
        await SchoolService().loadSchoolsIfNeeded();

        final rawData = decoded['data'];
        final rows = <Map<String, dynamic>>[];
        if (rawData is List) {
          for (final item in rawData) {
            if (item is Map) {
              rows.add(Map<String, dynamic>.from(item));
            }
          }
        }
        final List<ReportModel> reports = [];
        for (final row in rows) {
          try {
            // ─── NORMALIZAÇÃO DEFENSIVA: converter TODOS os campos ambíguos ───
            // O Apps Script pode retornar qualquer campo como List ou String
            // dependendo da versão deployada. JsonUtils trata ambos sem cast.

            // Listas → garantir List<String>
            row['subjects'] = JsonUtils.asStringList(
              row['subjects'] ??
                  row['motivos'] ??
                  row['subjectsList'] ??
                  row['Motivos / Assuntos'],
            );
            row['technicians'] = JsonUtils.asStringList(
              row['technicians'] ??
                  row['tecnicos'] ??
                  row['techniciansList'] ??
                  row['Técnicos Presentes'] ??
                  row['Tecnicos Presentes'],
            );
            row['motivos'] = row['subjects']; // alias consistente
            row['tecnicos'] = row['technicians']; // alias consistente
            row['subjectsList'] = row['subjects']; // evitar re-parse
            row['techniciansList'] = row['technicians'];

            // Strings opcionais → garantir String? (nunca List)
            row['fotosJson'] = JsonUtils.asNullableString(
              row['fotosJson'] ??
                  row['fotos_json'] ??
                  row['Fotos JSON'] ??
                  row['FOTOS_JSON'],
            );
            row['fotos_json'] = row['fotosJson'];
            row['materiais_ti_json'] = JsonUtils.asNullableString(
              row['materiais_ti_json'] ??
                  row['tiMaterials'] ??
                  row['MATERIAIS_TI_JSON'],
            );
            row['urlFotos'] = JsonUtils.asNullableString(
              row['urlFotos'] ??
                  row['Link Foto'] ??
                  row['Link Fotos'] ??
                  row['url_fotos'],
            );
            row['signatureUrl'] = JsonUtils.asNullableString(
              row['signatureUrl'] ??
                  row['urlAssinatura'] ??
                  row['Link Assinatura'] ??
                  row['URL_ASSINATURA'],
            );
            row['urlAssinatura'] = row['signatureUrl'];

            // photos: se vier como List<dynamic> de Maps, mantém; se String, trata como urlFotos
            // (parsePhotosFromJson do model já lida com ambos)
            if (row['photos'] is String) {
              // já está como string — parsePhotosFromJson vai processar
            } else if (row['photos'] is! List) {
              row['photos'] = <dynamic>[];
            }

            // Resolve cidade com todos os aliases possíveis
            String? city = _firstNonEmpty(row, [
              'schoolCity',
              'municipio',
              'município',
              'municipioEscola',
              'cidade',
              'city',
              'Município',
              'Municipio',
              'Cidade',
              'Município da Escola',
              'Cidade da Escola',
            ]);

            // Lê INEP com todos os aliases possíveis
            final String? inep = _firstNonEmpty(row, [
              'schoolInep',
              'inep',
              'INEP',
              'codigoInep',
              'códigoInep',
              'codInep',
              'inepEscola',
              'INEP Escola',
              'Código INEP',
            ]);

            // Se cidade veio vazia mas INEP existe, busca no SchoolService
            if ((city == null || city.isEmpty) &&
                inep != null &&
                inep.isNotEmpty) {
              city = findCityByInep(inep);
            }

            row['schoolCity'] = city;
            row['schoolInep'] = inep;

            final parsedReport = ReportModel.fromJson(row);
            final report = parsedReport.copyWith(
              syncStatus: 'synced',
              lastSyncedAt: DateTime.now(),
            );

            reports.add(report);
          } catch (e) {
            debugPrint('ERRO AO CONVERTER RELATÓRIO: $e');
            throw Exception('Falha ao ler relatório do Sheets: $e');
          }
        }

        return _dedupeReportsById(reports);
      }
      throw Exception('Status code: ${finalResponse.statusCode}');
    } catch (e) {
      debugPrint('Erro ao buscar relatórios: $e');
      rethrow;
    }
  }

  // ============================================================================
  // BUSCAR FUNCIONÁRIOS DA ABA "Funcionarios" DO SHEETS
  // ============================================================================
  Future<List<Map<String, String>>> fetchFuncionarios() async {
    final Map<String, dynamic> data = {'acao': 'buscar_funcionarios'};
    try {
      final http.Response finalResponse = await AppsScriptClient.post(
        data,
        timeout: const Duration(seconds: 40),
      );

      if (finalResponse.statusCode == 200) {
        final decoded = _parseAndValidateResponse(finalResponse);
        if (_isSuccess(decoded)) {
          final rows = _readMapList(decoded['data'], 'fetchFuncionarios');
          return rows
              .map(
                (item) => {
                  'matricula': item['matricula']?.toString() ?? '',
                  'nome': item['nome']?.toString() ?? '',
                },
              )
              .toList();
        }
      }
    } catch (e) {
      debugPrint('Erro ao buscar funcionários: $e');
    }
    return [];
  }

  // ============================================================================
  // BUSCAR TÉCNICOS DA NUVEM
  // ============================================================================
  Future<List<TechnicianModel>> fetchTechnicians() async {
    debugPrint('Usando aba de técnicos: ${Constants.techniciansSheetName}');
    final Map<String, dynamic> data = {
      'acao': 'buscar_tecnicos',
      'sheetName': Constants.techniciansSheetName,
    };
    try {
      final http.Response finalResponse = await AppsScriptClient.post(
        data,
        timeout: const Duration(seconds: 40),
      );

      if (finalResponse.statusCode == 200) {
        final decoded = _parseAndValidateResponse(finalResponse);
        if (_isSuccess(decoded)) {
          List<TechnicianModel> loaded = [];
          for (final item in _readMapList(
            decoded['data'],
            'fetchTechnicians',
          )) {
            loaded.add(
              TechnicianModel(
                id: item['id'] ?? '',
                name: fixMojibake(item['nome']?.toString() ?? ''),
                registration: fixMojibake(item['matricula']?.toString() ?? ''),
                email: fixMojibake(item['email']?.toString() ?? ''),
                permissions: fixMojibake(item['permissao']?.toString() ?? ''),
                password: item['senha']?.toString().isEmpty == false
                    ? item['senha']
                    : null,
              ),
            );
          }
          return loaded;
        }
      }
    } catch (e) {
      debugPrint('Erro ao buscar técnicos: $e');
    }
    return [];
  }

  // ============================================================================
  // HELPERS: INEP e MUNICÍPIO
  // ============================================================================

  /// Retorna o primeiro valor não-vazio dentre as chaves fornecidas no mapa.
  static String? _firstNonEmpty(Map<String, dynamic> row, List<String> keys) {
    for (final key in keys) {
      final raw = row[key];
      if (raw == null) continue;
      final value = ReportModel.asString(raw).trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  /// Normaliza INEP removendo tudo que não for dígito.
  static String _normalizeInep(String? value) {
    return value?.replaceAll(RegExp(r'[^0-9]'), '').trim() ?? '';
  }

  /// Busca a cidade de uma escola pelo INEP no SchoolService.
  /// Retorna null se não encontrar.
  static String? findCityByInep(String? inep) {
    final cleanInep = _normalizeInep(inep);
    if (cleanInep.isEmpty) return null;

    for (final school in SchoolService().schools) {
      if (_normalizeInep(school.inep) == cleanInep) {
        final city = school.city.trim();
        if (city.isNotEmpty) return city;
      }
    }
    return null;
  }

  /// Busca o INEP de uma escola pelo nome normalizado no SchoolService.
  static String? findInepBySchoolName(String? name) {
    if (name == null || name.trim().isEmpty) return null;
    final nameLower = name.trim().toLowerCase();
    for (final school in SchoolService().schools) {
      if (school.name.trim().toLowerCase() == nameLower) {
        final inep = school.inep.trim();
        if (inep.isNotEmpty) return inep;
      }
    }
    return null;
  }

  // ============================================================================
  // CORRIGIR MUNICÍPIOS ANTIGOS NA ABA RELATORIOS (Apps Script)
  // ============================================================================

  /// Chama a rotina no Apps Script que percorre a aba RELATORIOS e preenche
  /// a coluna "municipio" nos registros que estão com esse campo vazio.
  /// Requer que a action 'corrigirMunicipiosRelatorios' esteja implementada no GAS.
  Future<Map<String, dynamic>> corrigirMunicipiosRelatorios() async {
    final Map<String, dynamic> data = {'acao': 'corrigirMunicipiosRelatorios'};
    try {
      final http.Response finalResponse = await AppsScriptClient.post(
        data,
        timeout: const Duration(seconds: 60),
      );

      if (finalResponse.statusCode == 200) {
        final decoded = _parseAndValidateResponse(finalResponse);
        return Map<String, dynamic>.from(decoded);
      }
    } catch (e) {
      debugPrint('Erro ao corrigir municípios antigos: $e');
    }
    return {'success': false, 'message': 'Erro de conexão'};
  }

  Map<String, dynamic> _parseAndValidateResponse(http.Response response) {
    final body = utf8.decode(response.bodyBytes);
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';

    final trimmedLeft = body.trimLeft();
    final lowerBody = trimmedLeft.toLowerCase();
    if (contentType.contains('text/html') ||
        lowerBody.startsWith('<!doctype html') ||
        lowerBody.startsWith('<html') ||
        lowerBody.startsWith('<body') ||
        lowerBody.startsWith('<')) {
      throw Exception(
        'Apps Script retornou HTML em vez de JSON após redirect.',
      );
    }

    dynamic rawDecoded;
    try {
      rawDecoded = jsonDecode(body);
    } catch (e) {
      debugPrint('Erro ao decodificar resposta do Apps Script: $e');
      rethrow;
    }

    try {
      final decoded = fixMojibakeDeep(rawDecoded);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      throw Exception('Resposta JSON inesperada do Apps Script');
    } catch (e) {
      throw Exception(
        'A API retornou uma resposta que não pôde ser decodificada como JSON. Detalhes: $e',
      );
    }
  }
}
