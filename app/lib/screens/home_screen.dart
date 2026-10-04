import '../utils/friendly_error.dart';
import '../services/local_store.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../main.dart'; // Para acessar o themeNotifier
import '../models/report_model.dart';
import '../models/technician_model.dart';
import '../utils/pdf_generator.dart';
import '../widgets/app_ui.dart';
import '../services/apps_script_client.dart';
import '../services/google_sheets_service.dart';
import '../services/technician_service.dart';
import 'unified_report_screen.dart';
import 'login_screen.dart';
import 'school_list_screen.dart';
import 'technician_list_screen.dart';
import 'historico_screen.dart';
import 'sync_pending_screen.dart';
import '../services/school_service.dart';

enum NavigationLevel { regional, city, school, reports }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final List<ReportModel> _reports = [];
  final GoogleSheetsService _sheetsService = GoogleSheetsService();
  String _loggedUser = 'Técnico';
  String _userPermission = 'USR';
  String _loggedUserId = '';
  int _pendingSyncCount = 0;
  final Set<String> _pendingOfflineReportIds = {};
  bool _isSyncing = false;
  bool _isAutoSyncing = false;
  bool _hasAutoSyncedOnStart = false;
  String _syncStatusMessage = '';
  DateTime? _lastSyncAt;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  Timer? _periodicSyncTimer;
  bool _hasConnection = true;

  // Navigation State
  String _searchQuery = '';
  NavigationLevel _currentLevel = NavigationLevel.regional;
  String? _selectedRegional;
  String? _selectedCity;
  String? _selectedSchool;

  TechnicianModel? _currentTechnician;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadInitialData();
    _updateSyncCount();
    // Start automatic synchronization once when HomeScreen is first shown
    _autoSyncOnStart();
    _setupConnectivityRetry();
    _setupPeriodicSyncRetry();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySubscription?.cancel();
    _periodicSyncTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _retrySyncIfPending();
    }
  }

  void _setupConnectivityRetry() {
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen((results) {
      final hasConnection =
          results.any((result) => result != ConnectivityResult.none);
      // Only retry on the transition from offline to online, to avoid
      // firing a sync attempt on every connectivity event.
      if (hasConnection && !_hasConnection) {
        _retrySyncIfPending();
      }
      _hasConnection = hasConnection;
    });
  }

  void _setupPeriodicSyncRetry() {
    // Safety net in case a connectivity/resume event is missed.
    _periodicSyncTimer =
        Timer.periodic(const Duration(minutes: 3), (_) {
      _retrySyncIfPending();
    });
  }

  void _retrySyncIfPending() {
    if (!mounted || _isSyncing) return;
    if (_pendingSyncCount <= 0) return;
    _runSync(manual: false);
  }

    Future<void> _updateSyncCount() async {
    try {
      // Clean up all queues first
      await _sheetsService.cleanupAllOfflineQueuesAndReturnCount();
      // Count only pending creates and updates
      final createIds = await _sheetsService.getPendingCreateIds();
      final updateIds = await _sheetsService.getPendingUpdateIds();
      final count = await _sheetsService.getPendingSyncCount();
      final pendingIds = {...createIds, ...updateIds};
      var reportsChanged = false;

      if (mounted) {
        setState(() {
          _pendingSyncCount = count;
          _pendingOfflineReportIds
            ..clear()
            ..addAll(pendingIds);

          for (var i = 0; i < _reports.length; i++) {
            final report = _reports[i];
            if (!pendingIds.contains(report.id) &&
                report.syncStatus.toLowerCase().startsWith('pending')) {
              _reports[i] = report.copyWith(
                syncStatus: 'synced',
                lastSyncedAt: DateTime.now(),
              );
              reportsChanged = true;
            }
          }
        });
        if (reportsChanged) {
          await _saveReportsToPrefs();
        }
      }
    } catch (e) {
      debugPrint('Erro ao atualizar contador de pendências: $e');
      if (mounted) {
        setState(() {
          _pendingSyncCount = 0;
          _pendingOfflineReportIds.clear();
        });
      }
    }
  }


  Future<int> _updateSyncStatusFromCount() async {
    await _updateSyncCount();
    final pendingReports = await _sheetsService.getPendingCreateOrUpdateReports();
    if (pendingReports.isNotEmpty && mounted) {
      setState(() {
        _reports
          ..clear()
          ..addAll(_dedupeReportsById([..._reports, ...pendingReports]));
      });
      await _saveReportsToPrefs();
    }
    final count = await _sheetsService.getPendingSyncCount();

    if (mounted) {
      setState(() {
        _pendingSyncCount = count;
        _lastSyncAt = DateTime.now();
        _syncStatusMessage =
            count > 0 ? '$count pendência(s) para enviar' : 'Sincronizado agora';
      });
    }

    return count;
  }


  ReportModel _hydrateMissingCity(ReportModel report) {
    // Já tem cidade preenchida: retorna direto
    if (report.schoolCity != null && report.schoolCity!.trim().isNotEmpty) {
      return report;
    }

    // Tentativa 1: buscar pelo INEP (mais preciso)
    if (report.schoolInep != null && report.schoolInep!.trim().isNotEmpty) {
      final city = GoogleSheetsService.findCityByInep(report.schoolInep);
      if (city != null && city.isNotEmpty) {
        // Aproveita para preencher INEP se não estava
        return report.copyWith(schoolCity: city);
      }
    }

    // Tentativa 2: buscar pelo nome da escola
    try {
      final schoolNameLower = report.schoolName.trim().toLowerCase();
      final school = SchoolService().schools.firstWhere(
        (s) => s.name.trim().toLowerCase() == schoolNameLower,
      );
      if (school.city.trim().isNotEmpty) {
        return report.copyWith(
          schoolCity: school.city.trim(),
          schoolInep: (report.schoolInep == null || report.schoolInep!.isEmpty)
              ? school.inep.trim()
              : report.schoolInep,
        );
      }
    } catch (_) {}

    return report;
  }

  Future<void> _loadInitialData() async {
    final prefs = await SharedPreferences.getInstance();
    
    setState(() {
      _loggedUser = prefs.getString('logged_user') ?? 'Técnico';
      _userPermission = prefs.getString('logged_user_permission') ?? 'USR';
      _loggedUserId = prefs.getString('logged_user_id') ?? '';

      if (_loggedUserId.isNotEmpty) {
        final techs = TechnicianService().technicians;
        try {
          _currentTechnician = techs.firstWhere((t) => t.id == _loggedUserId);
        } catch (e) {
          _currentTechnician = null;
        }
      }
    });

    bool cacheModified = false;
    try {
      final String? reportsJson = await LocalStore.getString('local_reports');
      if (reportsJson != null) {
        final List<dynamic> decoded = jsonDecode(reportsJson);
        final loadedReports = <ReportModel>[];
        for (var item in decoded) {
          try {
            if (item is! Map) continue;
            var report = ReportModel.fromJson(Map<String, dynamic>.from(item));
            final hydrated = _hydrateMissingCity(report);
            if (hydrated.schoolCity != report.schoolCity) {
              cacheModified = true;
            }
            loadedReports.add(hydrated);
          } catch (e) {
            debugPrint('Erro ao carregar um relatório específico: $e');
          }
        }

        // Deduplica os relatórios carregados do cache local
        final uniqueLoaded = _dedupeReportsById(loadedReports);
        if (uniqueLoaded.length != loadedReports.length) {
          cacheModified = true;
        }

        // Filtrar pending_delete para não mostrar excluídos offline
        final pendingDeleteIds = await _sheetsService.getPendingDeleteIds();
        uniqueLoaded.removeWhere((r) => pendingDeleteIds.contains(r.id));

        setState(() {
          _reports.clear();
          _reports.addAll(uniqueLoaded);
        });

        if (cacheModified) {
          await _saveReportsToPrefs();
        }
      }
    } catch (e) {
      debugPrint('Erro fatal ao carregar relatórios: $e');
    }
    
    await _updateSyncCount();

    // Sincroniza e reconcilia os relatórios em segundo plano silenciosamente
    final initialPendingReports =
        await _sheetsService.getPendingCreateOrUpdateReports();
    if (initialPendingReports.isNotEmpty && mounted) {
      setState(() {
        _reports
          ..clear()
          ..addAll(_dedupeReportsById([..._reports, ...initialPendingReports]));
      });
      await _saveReportsToPrefs();
    }

    try {
      await _sheetsService.syncOfflineData();
      await _updateSyncCount();
      await _downloadReports(reconcile: true, silent: true);
    } catch (e) {
      debugPrint('Falha ao sincronizar em segundo plano na inicialização: $e');
    }
  }

  List<ReportModel> _dedupeReportsById(List<ReportModel> reports) {
    final map = <String, ReportModel>{};
    for (final report in reports) {
      final id = report.id.trim();
      if (id.isEmpty) continue;

      final existing = map[id];
      if (existing == null) {
        map[id] = report;
      } else {
        // Mantém a versão mais recente com base no localUpdatedAt ou visitDate
        final existingDate = existing.updatedAt ?? existing.localUpdatedAt ?? existing.lastSyncedAt ?? existing.visitDate;
        final newDate = report.updatedAt ?? report.localUpdatedAt ?? report.lastSyncedAt ?? report.visitDate;
        if (newDate.isAfter(existingDate)) {
          map[id] = report;
        }
      }
    }
    return map.values.toList();
  }

  Future<List<ReportModel>> _localReportsWithPendingQueue() async {
    final pendingReports = await _sheetsService.getPendingCreateOrUpdateReports();
    return _dedupeReportsById([..._reports, ...pendingReports]);
  }

  Future<void> _saveReportsToPrefs() async {
    final uniqueList = _dedupeReportsById(_reports);
    final String encoded = jsonEncode(uniqueList.map((r) => r.toJson()).toList());
    await LocalStore.setString('local_reports', encoded);
  }

  void _addNewReport(ReportModel report) {
    setState(() {
      _reports.insert(0, report);
    });
    _saveReportsToPrefs();
  }

  void _updateReport(int index, ReportModel report) {
    setState(() {
      _reports[index] = report;
    });
    _saveReportsToPrefs();
  }

  void _deleteReport(int index) async {
    final report = _reports[index];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir Relatório'),
        content: Text('Tem certeza que deseja excluir o relatório "${report.reportNumber}" da escola "${report.schoolName}"?\n\n'
                 'Esta ação removerá o registro localmente e da planilha na nuvem permanentemente.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('Cancelar', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() {
        _reports.removeAt(index);
      });
      await _saveReportsToPrefs();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Excluindo da nuvem...')),
        );
      }
      
      try {
        await _sheetsService.deleteReport(report.id, _loggedUser, report);
      } catch (e) {
        debugPrint('Erro ao deletar relatório: $e');
      }
      await _updateSyncCount();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Relatório ${report.reportNumber} excluído com sucesso!')),
        );
      }
    }
  }

  // ignore: unused_element
  Future<void> _syncAndReconcileReports() async {
    if (_isSyncing) return;
    setState(() {
      _isSyncing = true;
      _syncStatusMessage = 'Sincronizando...';
    });
    
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    
    if (mounted) {
      scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text('Sincronizando relatórios...')),
      );
    }

    try {
      // 1. Tenta enviar todas as pendências da fila offline
      await _sheetsService.syncOfflineData();
      await _updateSyncCount();

      // 2. Baixa a versão mais atual do Google Sheets
      final cloudReports = await _sheetsService.fetchReports();

      // 3. Reconciliação robusta
      final pendingCreateIds = await _sheetsService.getPendingCreateIds();
      final pendingUpdateIds = await _sheetsService.getPendingUpdateIds();
      final pendingDeleteIds = await _sheetsService.getPendingDeleteIds();

      final List<ReportModel> merged = [];
      final cloudMap = {for (var r in cloudReports) r.id: r};

      final localReports = await _localReportsWithPendingQueue();
      for (var local in localReports) {
        final id = local.id;
        if (pendingDeleteIds.contains(id)) continue;
        if (pendingCreateIds.contains(id) || pendingUpdateIds.contains(id)) {
          merged.add(local);
          cloudMap.remove(id);
        } else {
          final cloud = cloudMap[id];
          if (cloud != null) {
            merged.add(cloud);
            cloudMap.remove(id);
          }
        }
      }
      merged.addAll(cloudMap.values);

      final uniqueMerged = _dedupeReportsById(merged);

      setState(() {
        _reports.clear();
        _reports.addAll(uniqueMerged);
      });

      await _saveReportsToPrefs();
      await _updateSyncStatusFromCount();
      
      if (mounted) {
        scaffoldMessenger.showSnackBar(
          const SnackBar(content: Text('Sincronização concluída com sucesso!')),
        );
      }
    } catch (e) {
      debugPrint('Erro na sincronização: $e');
      final remainingCount = await _sheetsService.getPendingSyncCount();
      if (remainingCount == 0) {
        await _updateSyncStatusFromCount();
        if (mounted) {
          scaffoldMessenger.showSnackBar(
            const SnackBar(content: Text('Sincronizado agora')),
          );
        }
        return;
      }
      if (mounted) {
        setState(() {
          _syncStatusMessage = '';
        });
        final errText = _formatErrorMessage(e);
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text(errText),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
      await _updateSyncCount();
    }
  }

  Future<void> _syncAndReconcileCore() async {
    await _sheetsService.syncOfflineData();
    await _updateSyncCount();

    final cloudReports = await _sheetsService.fetchReports();

    final pendingCreateIds = await _sheetsService.getPendingCreateIds();
    final pendingUpdateIds = await _sheetsService.getPendingUpdateIds();
    final pendingDeleteIds = await _sheetsService.getPendingDeleteIds();

    final List<ReportModel> merged = [];
    final cloudMap = {for (var r in cloudReports) r.id: r};

    final localReports = await _localReportsWithPendingQueue();
    for (var local in localReports) {
      final id = local.id;
      if (pendingDeleteIds.contains(id)) continue;
      if (pendingCreateIds.contains(id) || pendingUpdateIds.contains(id)) {
        merged.add(local);
        cloudMap.remove(id);
      } else {
        final cloud = cloudMap[id];
        if (cloud != null) {
          merged.add(cloud);
          cloudMap.remove(id);
        }
      }
    }
    merged.addAll(cloudMap.values);

    final uniqueMerged = _dedupeReportsById(merged);

    if (mounted) {
      setState(() {
        _reports.clear();
        _reports.addAll(uniqueMerged);
      });
    }

    await _saveReportsToPrefs();
  }

  Future<void> _runSync({bool manual = false}) async {
    if (_isSyncing) return;

    if (mounted) {
      setState(() {
        _isSyncing = true;
        _isAutoSyncing = !manual;
        _syncStatusMessage = 'Sincronizando...';
      });
    }

    try {
      await _syncAndReconcileCore();

      final count = await _sheetsService.getPendingSyncCount();

      if (!mounted) return;

      setState(() {
        _pendingSyncCount = count;
        _lastSyncAt = DateTime.now();
        _syncStatusMessage =
            count > 0 ? '$count pendência(s) para enviar' : 'Sincronizado agora';
      });

      if (manual) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sincronizado agora')),
        );
      }
    } catch (e) {
      if (!mounted) return;

      final msg = e.toString().toLowerCase();
      setState(() {
        if (msg.contains('socket') ||
            msg.contains('timeout') ||
            msg.contains('connection') ||
            msg.contains('failed host lookup') ||
            msg.contains('network')) {
          _syncStatusMessage = 'Sem conexão. Usando dados salvos.';
        } else if (manual) {
          _syncStatusMessage = 'Não foi possível sincronizar agora.';
        } else if (_pendingSyncCount > 0) {
          // Preserve visibility of pending items instead of blanking the
          // status message on a silent automatic-sync failure.
          _syncStatusMessage = '$_pendingSyncCount pendência(s) para enviar';
        } else {
          _syncStatusMessage = '';
        }
      });

      if (manual) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_formatErrorMessage(e)),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _isAutoSyncing = false;
        });
      }
      await _updateSyncCount();
    }
  }

  Future<void> _syncOffline() async {
    await _runSync(manual: true);
  }

  Future<void> _openPendingSyncScreen() async {
    final pendingCount = await _sheetsService.getPendingSyncCount();
    await _updateSyncCount();

    if (!mounted) return;

    if (pendingCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nenhuma pendência para sincronizar.')),
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => SyncPendingScreen(onSyncNow: _syncOffline),
      ),
    );
    await _updateSyncCount();
  }

  /// Performs automatic synchronization when HomeScreen is first displayed.
  /// Ensures it runs only once and updates UI with status messages.
  Future<void> _autoSyncOnStart() async {
    if (_hasAutoSyncedOnStart) return;
    _hasAutoSyncedOnStart = true;
    await _runSync(manual: false);
  }

  String _formatErrorMessage(dynamic error) {
    final errStr = error.toString().toLowerCase();
    
    if (errStr.contains('subtype') || 
        errStr.contains('type cast') || 
        errStr.contains('null') || 
        errStr.contains('format') || 
        errStr.contains('typeerror') || 
        error is FormatException || 
        error is TypeError) {
      return 'Erro de integridade de dados. Falha ao ler um registro do Sheets: $error';
    }

    if (error is SocketException || 
        error is HttpException || 
        error is HandshakeException || 
        errStr.contains('socketexception') || 
        errStr.contains('httpclient') || 
        errStr.contains('failed host lookup') || 
        errStr.contains('timeout') || 
        errStr.contains('connection timed out')) {
      return 'Sem conexão. Verifique sua internet e tente novamente.';
    }
    
    if (errStr.contains('html') || errStr.contains('doctype') || errStr.contains('script url')) {
      return 'Resposta inválida do servidor (HTML). Verifique se o Apps Script está implantado corretamente e a URL está correta.';
    }
    
    return 'Erro ao sincronizar com a nuvem: $error';
  }

  Future<void> _downloadReports({bool reconcile = false, bool silent = false}) async {
    if (!silent && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Baixando relatórios da nuvem...')),
      );
    }

    try {
      final cloudReports = await _sheetsService.fetchReports();

      final uniqueCloud = _dedupeReportsById(cloudReports);

      if (reconcile) {
        final pendingCreateIds = await _sheetsService.getPendingCreateIds();
        final pendingUpdateIds = await _sheetsService.getPendingUpdateIds();
        final pendingDeleteIds = await _sheetsService.getPendingDeleteIds();

        final List<ReportModel> merged = [];
        final cloudMap = {for (var r in uniqueCloud) r.id: r};

        final localReports = await _localReportsWithPendingQueue();
        for (var local in localReports) {
          final id = local.id;
          if (pendingDeleteIds.contains(id)) continue;
          if (pendingCreateIds.contains(id) || pendingUpdateIds.contains(id)) {
            merged.add(local);
            cloudMap.remove(id);
          } else {
            final cloud = cloudMap[id];
            if (cloud != null) {
              merged.add(cloud);
              cloudMap.remove(id);
            }
          }
        }
        merged.addAll(cloudMap.values);
        
        final uniqueMerged = _dedupeReportsById(merged);
        setState(() {
          _reports.clear();
          _reports.addAll(uniqueMerged);
        });
      } else {
        setState(() {
          _reports.clear();
          _reports.addAll(uniqueCloud);
        });
      }

      await _saveReportsToPrefs();
      
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Download concluído com sucesso!')),
        );
      }
    } catch (e) {
      debugPrint('Erro ao baixar relatórios: $e');
      if (!silent && mounted) {
        final errText = _formatErrorMessage(e);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(errText),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  void _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('logged_user');
    await prefs.remove('logged_user_permission');
    await prefs.remove('logged_user_id');
    await prefs.remove('session_token');
    AppsScriptClient.sessionToken = null;
    
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (ctx) => const LoginScreen()),
      );
    }
  }

  void _changePassword() {
    final formKey = GlobalKey<FormState>();
    final passwordController = TextEditingController();
    bool obscure = true;
    bool saving = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStateDialog) => AlertDialog(
          title: const Text('Trocar Senha'),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: passwordController,
              obscureText: obscure,
              decoration: InputDecoration(
                labelText: 'Nova Senha',
                prefixIcon: const Icon(Icons.lock_outline),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () {
                    setStateDialog(() {
                      obscure = !obscure;
                    });
                  },
                ),
              ),
              validator: (v) => (v == null || v.isEmpty) ? 'Informe uma senha válida' : null,
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(ctx).pop(),
              child: Text('Cancelar', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ),
            ElevatedButton(
              onPressed: saving ? null : () async {
                if (formKey.currentState!.validate()) {
                  setStateDialog(() => saving = true);
                  final techService = TechnicianService();
                  final techs = techService.technicians;
                  final idx = techs.indexWhere((t) => t.id == _loggedUserId);
                  if (idx != -1) {
                    final updatedTech = techs[idx];
                    updatedTech.password = passwordController.text;
                    await techService.updateTechnician(updatedTech);
                    if (!mounted) return;
                    if (!ctx.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Senha atualizada com sucesso! A alteração será refletida na nuvem.')),
                    );
                    Navigator.of(ctx).pop();
                  }
                }
              },
              child: saving 
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickProfilePhoto() async {
    if (_currentTechnician == null) return;

    final ImagePicker picker = ImagePicker();
    
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galeria'),
              onTap: () => Navigator.of(context).pop(ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Câmera'),
              onTap: () => Navigator.of(context).pop(ImageSource.camera),
            ),
          ],
        ),
      ),
    );

    if (source != null) {
      final XFile? image = await picker.pickImage(source: source, maxWidth: 512, maxHeight: 512, imageQuality: 70);
      if (image != null) {
        String pathToSave = image.path;
        if (kIsWeb) {
          final bytes = await image.readAsBytes();
          pathToSave = base64Encode(bytes);
        }
        
        setState(() {
          _currentTechnician!.photoPath = pathToSave;
        });
        
        await TechnicianService().updateTechnician(_currentTechnician!);
      }
    }
  }

  void _openUnifiedScreen({ReportModel? existingReport, int? index}) async {
    final report = await Navigator.of(context).push<ReportModel>(
      MaterialPageRoute(
        builder: (context) => UnifiedReportScreen(existingReport: existingReport, loggedUser: _loggedUser),
      ),
    );

    if (report != null) {
      if (index != null) {
        final originalJson = jsonEncode(existingReport?.toJson());
        final newJson = jsonEncode(report.toJson());
        
        if (originalJson == newJson) return; 

        // Atualização: Marca temporariamente como pending_update localmente
        final pendingReport = report.copyWith(
          syncStatus: 'pending_update',
          localUpdatedAt: DateTime.now(),
        );
        
        _updateReport(index, pendingReport);
        
        // Tenta enviar para o Google Sheets com try-catch robusto
        try {
          await _sheetsService.sendReport(pendingReport, _loggedUser, isEdit: true);
        } catch (e) {
          debugPrint('Falha ao enviar relatório, mantendo offline: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Não foi possível enviar agora (${friendlyError(e)}). O relatório está salvo no aparelho e será enviado automaticamente quando houver conexão.'),
                backgroundColor: Theme.of(context).colorScheme.error,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        }
        
        // Atualiza contador de pendências
        await _updateSyncCount();
        
        // Verifica se foi enviado com sucesso ou ficou pendente na fila offline
        final pendingUpdateIds = await _sheetsService.getPendingUpdateIds();
        if (!pendingUpdateIds.contains(pendingReport.id)) {
          // Enviado com sucesso! Transaciona para synced
          final syncedReport = pendingReport.copyWith(
            syncStatus: 'synced',
            lastSyncedAt: DateTime.now(),
            localUpdatedAt: null,
          );
          final foundIndex = _reports.indexWhere((r) => r.id == pendingReport.id);
          if (foundIndex != -1) {
            _updateReport(foundIndex, syncedReport);
          }
        }
      } else {
        // Criação: Marca temporariamente como pending_create localmente
        final pendingReport = report.copyWith(
          syncStatus: 'pending_create',
          localUpdatedAt: DateTime.now(),
        );

        _addNewReport(pendingReport);

        // Tenta enviar para o Google Sheets com try-catch robusto
        try {
          await _sheetsService.sendReport(pendingReport, _loggedUser, isEdit: false);
        } catch (e) {
          debugPrint('Falha ao enviar relatório, mantendo offline: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Não foi possível enviar agora (${friendlyError(e)}). O relatório está salvo no aparelho e será enviado automaticamente quando houver conexão.'),
                backgroundColor: Theme.of(context).colorScheme.error,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        }

        // Atualiza contador de pendências
        await _updateSyncCount();

        // Verifica se foi enviado com sucesso ou ficou pendente na fila offline
        final pendingCreateIds = await _sheetsService.getPendingCreateIds();
        if (!pendingCreateIds.contains(pendingReport.id)) {
          // Enviado com sucesso! Transaciona para synced
          final syncedReport = pendingReport.copyWith(
            syncStatus: 'synced',
            lastSyncedAt: DateTime.now(),
            localUpdatedAt: null,
          );
          final foundIndex = _reports.indexWhere((r) => r.id == pendingReport.id);
          if (foundIndex != -1) {
            _updateReport(foundIndex, syncedReport);
          }
        }
      }
    }
  }

  void _exportPdf(ReportModel report) async {
    if (report.photos.isNotEmpty) {
      final bool? includeImages = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Incluir Imagens?'),
          content: const Text('Este relatório possui fotos anexadas. Deseja incluí-las no PDF gerado?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('Não', style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Sim, incluir'),
            ),
          ],
        ),
      );

      if (includeImages != null) {
        PdfGenerator.generateAndPreviewPdf(report, includeImages: includeImages);
      }
    } else {
      PdfGenerator.generateAndPreviewPdf(report, includeImages: false);
    }
  }

  // ====================== WIDGETS BUILDERS ======================

  List<Widget> _buildAppBarActions() {
    return [
      IconButton(
        icon: _pendingSyncCount > 0
            ? Badge(
                label: Text('$_pendingSyncCount'),
                child: const Icon(Icons.sync_rounded),
              )
            : const Icon(Icons.sync_rounded),
        onPressed: _isSyncing ? null : _openPendingSyncScreen,
        tooltip: 'Pendências de sincronização',
      ),
    ];
  }

  Widget _buildDrawer() {
    final colorScheme = Theme.of(context).colorScheme;
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [colorScheme.primary, colorScheme.primaryContainer],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: _pickProfilePhoto,
                  child: CircleAvatar(
                    radius: 32,
                    backgroundColor: colorScheme.onPrimary.withValues(alpha: 0.24),
                    backgroundImage: (_currentTechnician?.photoPath != null && _currentTechnician!.photoPath!.isNotEmpty)
                        ? (_currentTechnician!.photoPath!.length > 500 
                            ? MemoryImage(base64Decode(_currentTechnician!.photoPath!)) 
                            : (kIsWeb ? NetworkImage(_currentTechnician!.photoPath!) : FileImage(File(_currentTechnician!.photoPath!)))) as ImageProvider
                        : null,
                    child: (_currentTechnician?.photoPath == null || _currentTechnician!.photoPath!.isEmpty)
                        ? Icon(Icons.camera_alt_outlined, size: 30, color: colorScheme.onPrimary)
                        : null,
                  ),
                ),
                const SizedBox(height: 8),
                Text('Nexus Relatórios', style: TextStyle(color: colorScheme.onPrimary, fontSize: 20, fontWeight: FontWeight.bold)),
                Text('${_currentTechnician?.name ?? _loggedUser} - $_userPermission', style: TextStyle(color: colorScheme.onPrimary.withValues(alpha: 0.7), fontSize: 14)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 8, bottom: 8),
            child: Builder(builder: (ctx) {
              final cs = Theme.of(ctx).colorScheme;
              return Text('GESTÃO', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: cs.onSurfaceVariant));
            }),
          ),
          ListTile(
            leading: const Icon(Icons.school_outlined),
            title: const Text('Gerenciar Escolas'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(MaterialPageRoute(builder: (ctx) => const SchoolListScreen()));
            },
          ),
          if (_isAdmin) ...[
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 16, bottom: 8),
              child: Builder(builder: (ctx) {
                final cs = Theme.of(ctx).colorScheme;
                return Text('ADMINISTRAÇÃO', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: cs.onSurfaceVariant));
              }),
            ),
            ListTile(
              leading: const Icon(Icons.people_outline),
              title: const Text('Gerenciar Técnicos'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (ctx) => const TechnicianListScreen()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.history_rounded),
              title: const Text('Histórico de Relatórios'),
              subtitle: const Text('Edições e exclusões', style: TextStyle(fontSize: 11)),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(builder: (ctx) => const HistoricoScreen()));
              },
            ),
          ],
          const Divider(),
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 8, bottom: 8),
            child: Builder(builder: (ctx) {
              final cs = Theme.of(ctx).colorScheme;
              return Text('PREFERÊNCIAS', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: cs.onSurfaceVariant));
            }),
          ),
          ListTile(
            leading: const Icon(Icons.vpn_key_outlined),
            title: const Text('Trocar Senha'),
            onTap: () {
              Navigator.of(context).pop();
              _changePassword();
            },
          ),
          ValueListenableBuilder<ThemeMode>(
            valueListenable: themeNotifier,
            builder: (context, currentMode, child) {
              return SwitchListTile(
                secondary: const Icon(Icons.dark_mode_outlined),
                title: const Text('Modo Escuro'),
                value: currentMode == ThemeMode.dark,
                onChanged: (value) async {
                  themeNotifier.value = value ? ThemeMode.dark : ThemeMode.light;
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setBool('is_dark_mode', value);
                },
              );
            },
          ),
          ListTile(
            leading: Icon(Icons.logout, color: colorScheme.error),
            title: Text('Sair', style: TextStyle(color: colorScheme.error)),
            onTap: () {
              Navigator.of(context).pop();
              _logout();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildProfileHeader() {
    final colorScheme = Theme.of(context).colorScheme;
    
    String nivel = '';
    if (_isAdmin) { nivel = 'Administrador'; }
    else if (_userPermission == 'OPE') { nivel = 'Operador'; }
    else { nivel = 'Técnico'; }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        border: Border(bottom: BorderSide(color: colorScheme.surfaceContainerHighest)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: _pickProfilePhoto,
            child: CircleAvatar(
              radius: 40,
              backgroundColor: colorScheme.primaryContainer,
              backgroundImage: (_currentTechnician?.photoPath != null && _currentTechnician!.photoPath!.isNotEmpty)
                  ? (_currentTechnician!.photoPath!.length > 500 
                      ? MemoryImage(base64Decode(_currentTechnician!.photoPath!)) 
                      : (kIsWeb ? NetworkImage(_currentTechnician!.photoPath!) : FileImage(File(_currentTechnician!.photoPath!)))) as ImageProvider
                  : null,
              child: (_currentTechnician?.photoPath == null || _currentTechnician!.photoPath!.isEmpty)
                  ? Icon(Icons.camera_alt_rounded, size: 32, color: colorScheme.onPrimaryContainer)
                  : null,
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bem-vindo(a), ${_currentTechnician?.name ?? _loggedUser}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Chip(
                      label: Text(nivel, style: TextStyle(fontSize: 11, color: colorScheme.onSecondaryContainer, fontWeight: FontWeight.w600)),
                      backgroundColor: colorScheme.secondaryContainer,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Matrícula: ${_currentTechnician?.registration ?? "N/A"}',
                        style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Rede Estadual da Paraíba',
                  style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _normalizeForCompare(String? value) {
    var text = (value ?? '').trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    const withDiacritics = 'àáâãäåòóôõöøèéêëçìíîïùúûüÿñ';
    const withoutDiacritics = 'aaaaaaooooooeeeeciiiiuuuuyn';
    for (int i = 0; i < withDiacritics.length; i++) {
      text = text.replaceAll(withDiacritics[i], withoutDiacritics[i]);
    }
    return text;
  }

  bool _isAdminPermission(String? permission) {
    final p = _normalizeForCompare(permission);
    return p == 'adm' || p == 'admin' || p == 'administrador' || p == 'administrator';
  }

  bool get _isAdmin => _isAdminPermission(_userPermission);

  Set<String> get _currentUserKeys {
    return {
      _loggedUser,
      _loggedUserId,
      _currentTechnician?.name,
      _currentTechnician?.email,
      _currentTechnician?.registration,
    }
        .whereType<String>()
        .map(_normalizeForCompare)
        .where((value) => value.isNotEmpty)
        .toSet();
  }

  bool _matchesCurrentUser(String? value) {
    final normalized = _normalizeForCompare(value);
    if (normalized.isEmpty) return false;
    return _currentUserKeys.any((key) =>
        key == normalized ||
        (key.length >= 3 && normalized.contains(key)) ||
        (normalized.length >= 3 && key.contains(normalized)));
  }

  List<ReportModel> get _visibleReports {
    if (_isAdmin) return _reports;
    return _reports.where((r) {
      final isCreator = _matchesCurrentUser(r.creator);
      final isCredited = r.technicians.any(_matchesCurrentUser);
      return isCreator || isCredited;
    }).toList();
  }

  List<ReportModel> get _searchedReports {
    final visible = _visibleReports;
    if (_searchQuery.isEmpty) return visible;
    final q = _searchQuery.toLowerCase();
    return visible.where((r) {
      return r.reportNumber.toLowerCase().contains(q) ||
          r.schoolName.toLowerCase().contains(q) ||
          (r.schoolCity?.toLowerCase().contains(q) ?? false) ||
          (r.gre?.toLowerCase().contains(q) ?? false) ||
          r.subjects.any((s) => s.toLowerCase().contains(q)) ||
          r.technicians.any((t) => t.toLowerCase().contains(q)) ||
          (r.observations?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  String _safeRegional(ReportModel r) {
    final value = r.gre?.trim() ?? '';
    return value.isEmpty ? 'Regional não informada' : value;
  }

  String _safeCity(ReportModel r) {
    // 1. Cidade já preenchida no relatório
    final city = r.schoolCity?.trim();
    if (city != null && city.isNotEmpty && city != 'Município não informado') {
      return city;
    }

    // 2. Inferir pelo INEP via SchoolService
    final cityByInep = GoogleSheetsService.findCityByInep(r.schoolInep);
    if (cityByInep != null && cityByInep.isNotEmpty) {
      return cityByInep;
    }

    return 'Município não informado';
  }

  String _safeSchool(ReportModel r) {
    final value = r.schoolName.trim();
    return value.isEmpty ? 'Escola não informada' : value;
  }

  void _navigateBack() {
    if (_currentLevel == NavigationLevel.reports) {
      setState(() {
        _currentLevel = NavigationLevel.school;
        _selectedSchool = null;
      });
    } else if (_currentLevel == NavigationLevel.school) {
      setState(() {
        _currentLevel = NavigationLevel.city;
        _selectedCity = null;
      });
    } else if (_currentLevel == NavigationLevel.city) {
      setState(() {
        _currentLevel = NavigationLevel.regional;
        _selectedRegional = null;
      });
    }
  }

  Widget _buildBreadcrumbs() {
    final colorScheme = Theme.of(context).colorScheme;
    
    List<Widget> crumbs = [];
    
    Widget buildCrumb(String label, String value, NavigationLevel level, {bool isLast = false}) {
      return InkWell(
        onTap: isLast ? null : () {
          setState(() {
            _currentLevel = level;
            if (level == NavigationLevel.regional) {
              _selectedRegional = null;
              _selectedCity = null;
              _selectedSchool = null;
            } else if (level == NavigationLevel.city) {
              _selectedCity = null;
              _selectedSchool = null;
            } else if (level == NavigationLevel.school) {
              _selectedSchool = null;
            }
          });
        },
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: RichText(
            text: TextSpan(
              style: TextStyle(
                fontSize: 13,
                color: isLast ? colorScheme.primary : colorScheme.onSurfaceVariant,
              ),
              children: [
                if (label.isNotEmpty)
                  TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.normal)),
                TextSpan(
                  text: value, 
                  style: TextStyle(fontWeight: isLast ? FontWeight.bold : FontWeight.w600)
                ),
              ],
            ),
          ),
        ),
      );
    }

    crumbs.add(buildCrumb('', 'Regionais', NavigationLevel.regional, isLast: _currentLevel == NavigationLevel.regional));
    
    if (_selectedRegional != null) {
      crumbs.add(Icon(Icons.chevron_right, size: 16, color: colorScheme.onSurfaceVariant));
      crumbs.add(buildCrumb('Regional', _selectedRegional!, NavigationLevel.city, isLast: _currentLevel == NavigationLevel.city));
    }
    if (_selectedCity != null) {
      crumbs.add(Icon(Icons.chevron_right, size: 16, color: colorScheme.onSurfaceVariant));
      crumbs.add(buildCrumb('Município', _selectedCity!, NavigationLevel.school, isLast: _currentLevel == NavigationLevel.school));
    }
    if (_selectedSchool != null) {
      crumbs.add(Icon(Icons.chevron_right, size: 16, color: colorScheme.onSurfaceVariant));
      crumbs.add(buildCrumb('Escola', _selectedSchool!, NavigationLevel.reports, isLast: _currentLevel == NavigationLevel.reports));
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: crumbs,
      ),
    );
  }

  Widget _buildFilters() {
    final searchField = AppSearchField(
      label: 'Pesquisar relatórios',
      hint: 'Escola, número, assunto, regional...',
      onChanged: (value) => setState(() => _searchQuery = value),
      onClear: () => setState(() => _searchQuery = ''),
      initialValue: _searchQuery,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: searchField,
    );
  }

  Widget _buildGroupTile({
    required String title,
    required int count,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              Icon(icon, color: colorScheme.primary, size: 24),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  count.toString(),
                  style: TextStyle(
                    color: colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.chevron_right, color: colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReportCard(ReportModel report, int originalIndex) {
    final colorScheme = Theme.of(context).colorScheme;
    final isLargeScreen = MediaQuery.of(context).size.width > 600;
    final isPending = _pendingOfflineReportIds.contains(report.id);
    final schoolCity = _safeCity(report);
    final hasCity = schoolCity.trim().isNotEmpty &&
        schoolCity != 'Município não informado' &&
        schoolCity != 'MunicÃ­pio nÃ£o informado';

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12, top: 4, left: 16, right: 16),
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openUnifiedScreen(existingReport: report, index: originalIndex),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.assignment_outlined, color: colorScheme.primary, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _buildReportNumberChip(report.reportNumber),
                        if (isPending) _buildPendingChip(),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      report.schoolName,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: colorScheme.onSurface,
                            height: 1.2,
                          ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _buildInfoChip(
                          Icons.calendar_today_rounded,
                          DateFormat('dd/MM/yyyy').format(report.visitDate),
                        ),
                        if (report.gre != null && report.gre!.isNotEmpty)
                          _buildInfoChip(Icons.map_rounded, report.gre!),
                        if (hasCity)
                          _buildInfoChip(Icons.location_city_rounded, schoolCity),
                        if (report.photos.isNotEmpty)
                          _buildInfoChip(
                            Icons.photo_library_rounded,
                            '${report.photos.length} fotos',
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      report.subjects.isEmpty ? 'Sem motivo registrado' : report.subjects.join(', '),
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.25,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (isLargeScreen)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(Icons.edit_outlined, color: colorScheme.primary),
                      tooltip: 'Editar',
                      onPressed: () => _openUnifiedScreen(existingReport: report, index: originalIndex),
                    ),
                    IconButton(
                      icon: Icon(Icons.picture_as_pdf_outlined, color: colorScheme.error),
                      tooltip: 'Exportar PDF',
                      onPressed: () => _exportPdf(report),
                    ),
                    if (_isAdmin)
                      IconButton(
                        icon: Icon(Icons.delete_outline, color: colorScheme.error),
                        tooltip: 'Excluir',
                        onPressed: () => _deleteReport(originalIndex),
                      ),
                  ],
                )
              else
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded),
                  onSelected: (value) {
                    if (value == 'edit') _openUnifiedScreen(existingReport: report, index: originalIndex);
                    if (value == 'pdf') _exportPdf(report);
                    if (value == 'delete') _deleteReport(originalIndex);
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(value: 'edit', child: Row(children: [Icon(Icons.edit_outlined, size: 20, color: colorScheme.primary), const SizedBox(width: 8), const Text('Editar')])),
                    PopupMenuItem(value: 'pdf', child: Row(children: [Icon(Icons.picture_as_pdf_outlined, size: 20, color: colorScheme.error), const SizedBox(width: 8), const Text('Exportar PDF')])),
                    if (_isAdmin)
                      PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 20, color: colorScheme.error), const SizedBox(width: 8), const Text('Excluir')])),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String label) {
    return InfoChip(
      label: label,
      icon: icon,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }

  Widget _buildReportNumberChip(String reportNumber) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.18)),
      ),
      child: Text(
        reportNumber,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w800,
              letterSpacing: 0,
            ),
      ),
    );
  }

  Widget _buildPendingChip() {
    final color = Colors.amber.shade800;
    return InfoChip(
      label: 'Pendente',
      icon: Icons.cloud_off_rounded,
      color: color,
      backgroundColor: Colors.amber.withValues(alpha: 0.14),
    );
  }

  Widget _buildSyncStatusChip() {
    if (_syncStatusMessage.isEmpty) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final message = _syncStatusMessage.toLowerCase();
    final hasError = message.contains('erro') || message.contains('não foi');
    final isOffline = message.contains('sem conexão') ||
        message.contains('offline') ||
        message.contains('dados salvos');
    final hasPending = message.contains('pendência');
    final isSynced = message.contains('sincronizado');

    late final IconData icon;
    late final Color color;

    if (_isSyncing) {
      icon = Icons.sync_rounded;
      color = colorScheme.primary;
    } else if (hasError) {
      icon = Icons.error_outline_rounded;
      color = colorScheme.error;
    } else if (isOffline) {
      icon = Icons.wifi_off_rounded;
      color = colorScheme.tertiary;
    } else if (hasPending) {
      icon = Icons.pending_actions_rounded;
      color = Colors.amber.shade800;
    } else if (isSynced) {
      icon = Icons.check_circle_outline_rounded;
      color = Colors.green.shade700;
    } else {
      icon = Icons.sync_rounded;
      color = colorScheme.primary;
    }

    final label = (!_isAutoSyncing && _lastSyncAt != null)
        ? '$_syncStatusMessage · ${_lastSyncAt!.hour.toString().padLeft(2, '0')}:${_lastSyncAt!.minute.toString().padLeft(2, '0')}'
        : _syncStatusMessage;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.22)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool hasFiltersActive) {
    return EmptyState(
      icon: hasFiltersActive ? Icons.search_off_rounded : Icons.assignment_outlined,
      title: hasFiltersActive ? 'Nenhum resultado encontrado' : 'Nenhum relatório ainda',
      message: hasFiltersActive 
          ? 'Tente remover os filtros ou buscar por outras palavras.'
          : 'Você ainda não possui relatórios vinculados à sua conta.',
      actionLabel: hasFiltersActive ? null : 'Criar Meu Primeiro Relatório',
      onAction: hasFiltersActive ? null : () => _openUnifiedScreen(),
    );
  }

  Widget _buildRegionalLevel(List<ReportModel> reports) {
    final grouped = <String, int>{};
    for (var r in reports) {
      final reg = _safeRegional(r);
      grouped[reg] = (grouped[reg] ?? 0) + 1;
    }

    final sortedRegionals = grouped.keys.toList()..sort();

    return RefreshIndicator(
      onRefresh: _syncOffline,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 80, top: 8),
        itemCount: sortedRegionals.length,
        itemBuilder: (context, index) {
          final reg = sortedRegionals[index];
          return _buildGroupTile(
            title: reg,
            count: grouped[reg]!,
            icon: Icons.map_outlined,
            onTap: () {
              setState(() {
                _selectedRegional = reg;
                _currentLevel = NavigationLevel.city;
              });
            },
          );
        },
      ),
    );
  }

  Widget _buildCityLevel(List<ReportModel> reports) {
    final filtered = reports.where((r) => _safeRegional(r) == _selectedRegional).toList();
    
    final grouped = <String, int>{};
    for (var r in filtered) {
      final city = _safeCity(r);
      grouped[city] = (grouped[city] ?? 0) + 1;
    }

    final sortedCities = grouped.keys.toList()..sort();

    return RefreshIndicator(
      onRefresh: _syncOffline,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 80, top: 8),
        itemCount: sortedCities.length,
        itemBuilder: (context, index) {
          final city = sortedCities[index];
          return _buildGroupTile(
            title: city,
            count: grouped[city]!,
            icon: Icons.location_city_outlined,
            onTap: () {
              setState(() {
                _selectedCity = city;
                _currentLevel = NavigationLevel.school;
              });
            },
          );
        },
      ),
    );
  }

  Widget _buildSchoolLevel(List<ReportModel> reports) {
    final filtered = reports.where((r) => _safeRegional(r) == _selectedRegional && _safeCity(r) == _selectedCity).toList();
    
    final grouped = <String, int>{};
    for (var r in filtered) {
      final school = _safeSchool(r);
      grouped[school] = (grouped[school] ?? 0) + 1;
    }

    final sortedSchools = grouped.keys.toList()..sort();

    return RefreshIndicator(
      onRefresh: _syncOffline,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 80, top: 8),
        itemCount: sortedSchools.length,
        itemBuilder: (context, index) {
          final school = sortedSchools[index];
          return _buildGroupTile(
            title: school,
            count: grouped[school]!,
            icon: Icons.school_outlined,
            onTap: () {
              setState(() {
                _selectedSchool = school;
                _currentLevel = NavigationLevel.reports;
              });
            },
          );
        },
      ),
    );
  }

  Widget _buildReportsLevel(List<ReportModel> reports) {
    final filtered = reports.where((r) => 
      _safeRegional(r) == _selectedRegional && 
      _safeCity(r) == _selectedCity && 
      _safeSchool(r) == _selectedSchool
    ).toList();

    filtered.sort((a, b) => b.visitDate.compareTo(a.visitDate));

    return RefreshIndicator(
      onRefresh: _syncOffline,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 80, top: 8),
        itemCount: filtered.length,
        itemBuilder: (context, index) {
          final report = filtered[index];
          final originalIndex = _reports.indexOf(report);
          return _buildReportCard(report, originalIndex);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final searched = _searchedReports;

    // Atualização pós-sincronização/pesquisa: Se o item selecionado não existir mais, volta o nível correspondente
    if (_currentLevel == NavigationLevel.reports && searched.where((r) => _safeRegional(r) == _selectedRegional && _safeCity(r) == _selectedCity && _safeSchool(r) == _selectedSchool).isEmpty) {
      _currentLevel = NavigationLevel.school;
      _selectedSchool = null;
    }
    if (_currentLevel == NavigationLevel.school && searched.where((r) => _safeRegional(r) == _selectedRegional && _safeCity(r) == _selectedCity).isEmpty) {
      _currentLevel = NavigationLevel.city;
      _selectedCity = null;
    }
    if (_currentLevel == NavigationLevel.city && searched.where((r) => _safeRegional(r) == _selectedRegional).isEmpty) {
      _currentLevel = NavigationLevel.regional;
      _selectedRegional = null;
    }

    final bool hasFiltersActive = _searchQuery.isNotEmpty;

    Widget bodyContent = const SizedBox();
    if (searched.isEmpty) {
      bodyContent = _buildEmptyState(hasFiltersActive);
    } else {
      switch (_currentLevel) {
        case NavigationLevel.regional:
          bodyContent = _buildRegionalLevel(searched);
          break;
        case NavigationLevel.city:
          bodyContent = _buildCityLevel(searched);
          break;
        case NavigationLevel.school:
          bodyContent = _buildSchoolLevel(searched);
          break;
        case NavigationLevel.reports:
          bodyContent = _buildReportsLevel(searched);
          break;
      }
    }

    return PopScope(
      canPop: _currentLevel == NavigationLevel.regional,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          _navigateBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Meus Relatórios', style: TextStyle(fontWeight: FontWeight.w600)),
              Text('Visão Geral', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
          actions: _buildAppBarActions(),
          leading: _currentLevel != NavigationLevel.regional 
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _navigateBack,
                )
              : null, // Deixa o padrão (Drawer icon) quando no nível regional
        ),
        drawer: _currentLevel == NavigationLevel.regional ? _buildDrawer() : null,
        body: Column(
          children: [
            _buildProfileHeader(),
            _buildSyncStatusChip(),
            _buildFilters(),
            _buildBreadcrumbs(),
            Expanded(child: bodyContent),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _openUnifiedScreen(),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Novo Relatório', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

}
