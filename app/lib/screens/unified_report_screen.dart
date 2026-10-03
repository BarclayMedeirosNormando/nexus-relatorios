import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signature/signature.dart';
import '../models/report_model.dart';
import '../widgets/multi_select_dialog.dart';
import '../services/school_service.dart';
import '../services/technician_service.dart';
import '../services/google_sheets_service.dart';
import '../utils/app_constants.dart';
import '../models/school_model.dart';
import '../models/technician_model.dart';
import '../models/employee_model.dart';
import '../services/employee_service.dart';
import '../widgets/app_ui.dart';

class UnifiedReportScreen extends StatefulWidget {
  final ReportModel? existingReport;
  final String loggedUser;

  const UnifiedReportScreen({super.key, this.existingReport, required this.loggedUser});

  @override
  State<UnifiedReportScreen> createState() => _UnifiedReportScreenState();
}

class _UnifiedReportScreenState extends State<UnifiedReportScreen> with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();

  static const String _draftPrefsKey = 'unified_report_draft_v1';
  Timer? _draftTimer;
  String? _lastSavedDraftJson;
  bool _draftSubmitted = false;

  DateTime? _selectedDate;
  String? _selectedSchool;
  String? _selectedSchoolAddress;
  String? _selectedSchoolCity;
  String? _selectedSchoolInep;
  String? _gre;
  String? _selectedResponsible;

  String? _filterRegional;
  String? _filterCity;

  List<String> _selectedSubjects = [];
  List<String> _selectedTechnicians = [];

  final _observationsController = TextEditingController();

  final List<PhotoItem> _selectedPhotos = [];
  final List<TiMaterialItem> _tiMaterials = [];
  final ImagePicker _picker = ImagePicker();
  final List<SignatureController> _signatureControllers = [];

  final SchoolService _schoolService = SchoolService();
  final TechnicianService _technicianService = TechnicianService();

  final List<String> _mockSubjects = [
    'Análise Técnica',
    'Manutenção Corretiva',
    'Manutenção Preventiva',
    'Internet Offline',
    'Instalação de Softwares',
    'Cabeamento Estruturado',
    'Redefinição de Senha',
    'Filtro de Conteúdo / Firewall',
    'Backup de Dados'
  ];

  bool get _isTechnicalAnalysis => _selectedSubjects.contains('Análise Técnica');

  static const List<String> _tiMaterialAmbientes = [
    'Secretaria',
    'Laboratório de Informática',
    'Sala dos Professores',
    'Diretoria',
    'Sala de Aula',
    'Biblioteca',
    'Coordenação',
    'Pátio',
    'Outro',
  ];

  static const List<String> _tiMaterialEquipamentos = [
    'Cabo de rede',
    'Conector RJ45',
    'Switch',
    'Roteador',
    'Access Point / AP',
    'Rack',
    'Patch panel',
    'Nobreak',
    'Fonte',
    'Canaleta',
    'Tomada de rede',
    'Ponto lógico',
    'Repetidor',
    'Conversor de mídia',
    'Outro',
  ];

  late final TextEditingController _schoolSearchController;
  late final FocusNode _schoolSearchFocusNode;

  bool _isLoadingTechnicians = false;
  String? _techniciansLoadError;
  List<TechnicianModel> _availableTechnicians = [];

  bool _isLoadingSchools = false;
  String? _schoolsLoadError;
  List<SchoolModel> _availableSchools = [];

  String _normalize(String? value) {
    if (value == null) return '';
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[áàâãäå]'), 'a')
        .replaceAll(RegExp(r'[éèêë]'), 'e')
        .replaceAll(RegExp(r'[íìîï]'), 'i')
        .replaceAll(RegExp(r'[óòôõöø]'), 'o')
        .replaceAll(RegExp(r'[úùûü]'), 'u')
        .replaceAll('ç', 'c')
        .replaceAll('ñ', 'n')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _normalizeFilterText(String value) => _normalize(value);

  bool _sameFilterText(String? left, String? right) {
    return _normalize(left) == _normalize(right);
  }

  bool _containsFilterText(Iterable<String> values, String? selected) {
    final normalized = _normalize(selected);
    if (normalized.isEmpty) return false;
    return values.any((value) => _normalize(value) == normalized);
  }

  Future<void> _loadTechnicians() async {
    if (!mounted) return;
    setState(() {
      _isLoadingTechnicians = true;
      _techniciansLoadError = null;
    });

    try {
      await _technicianService.loadTechnicians();
      
      try {
        await _technicianService.syncTechniciansFromCloud();
      } catch (e) {
        debugPrint('Erro ao sincronizar técnicos da nuvem: $e');
      }

      if (!mounted) return;
      setState(() {
        _availableTechnicians = List<TechnicianModel>.from(_technicianService.technicians)
          ..sort((a, b) => _normalize(a.name).compareTo(_normalize(b.name)));
        _isLoadingTechnicians = false;
      });
    } catch (e, stack) {
      debugPrint('Erro ao carregar técnicos da aba Técnicos: $e');
      debugPrintStack(stackTrace: stack);

      if (!mounted) return;
      setState(() {
        _availableTechnicians = List<TechnicianModel>.from(_technicianService.technicians)
          ..sort((a, b) => _normalize(a.name).compareTo(_normalize(b.name)));
        _isLoadingTechnicians = false;
        _techniciansLoadError = e.toString();
      });
    }
  }

  Future<void> _loadSchools() async {
    if (!mounted) return;
    setState(() {
      _isLoadingSchools = true;
      _schoolsLoadError = null;
    });

    try {
      await _schoolService.loadSchoolsIfNeeded();

      if (!mounted) return;
      setState(() {
        _availableSchools = List<SchoolModel>.from(_schoolService.schools)
          ..sort((a, b) => _normalize(a.name).compareTo(_normalize(b.name)));
        _isLoadingSchools = false;
      });
    } catch (e, stack) {
      debugPrint('Erro ao carregar escolas: $e');
      debugPrintStack(stackTrace: stack);

      if (!mounted) return;
      setState(() {
        _availableSchools = List<SchoolModel>.from(_schoolService.schools)
          ..sort((a, b) => _normalize(a.name).compareTo(_normalize(b.name)));
        _isLoadingSchools = false;
        _schoolsLoadError = e.toString();
      });
    }
  }

  List<String> get _availableRegionals {
    final set = <String>{};
    for (final s in _availableSchools) {
      final gre = s.gre.trim();
      if (gre.isNotEmpty) set.add(gre);
    }

    if (set.isEmpty) {
      set.addAll(Constants.regionals.where((r) => r.trim().isNotEmpty));
    }

    final list = set.toList();
    list.sort((a, b) => _normalize(a).compareTo(_normalize(b)));
    return list;
  }

  List<SchoolModel> get _schoolsBySelectedRegional {
    final reg = _normalize(_filterRegional);
    if (reg.isEmpty) return _availableSchools;
    return _availableSchools.where((s) => _normalize(s.gre) == reg).toList();
  }

  List<String> get _availableCities {
    final set = <String>{};
    for (final s in _schoolsBySelectedRegional) {
      final city = s.city.trim();
      if (city.isNotEmpty) set.add(city);
    }

    if (set.isEmpty && _availableSchools.isEmpty) {
      set.addAll(Constants.paraibaMunicipalities.where((c) => c.trim().isNotEmpty));
    }

    final list = set.toList();
    list.sort((a, b) => _normalize(a).compareTo(_normalize(b)));
    return list;
  }

  List<SchoolModel> _getFilteredSchools(String query) {
    var result = List<SchoolModel>.from(_availableSchools);
    final reg = _normalizeFilterText(_filterRegional ?? '');
    final city = _normalizeFilterText(_filterCity ?? '');
    final q = _normalizeFilterText(query);

    if (reg.isNotEmpty) {
      result = result
          .where((s) => _normalizeFilterText(s.gre) == reg)
          .toList();
    }

    if (city.isNotEmpty) {
      result = result
          .where((s) => _normalizeFilterText(s.city) == city)
          .toList();
    }

    if (q.isNotEmpty) {
      result = result.where((s) {
        return _normalizeFilterText(s.name).contains(q) ||
            _normalizeFilterText(s.inep).contains(q);
      }).toList();
    }

    result.sort((a, b) {
      final greCompare = _normalize(a.gre).compareTo(_normalize(b.gre));
      if (greCompare != 0) return greCompare;

      final cityCompare = _normalize(a.city).compareTo(_normalize(b.city));
      if (cityCompare != 0) return cityCompare;

      return _normalize(a.name).compareTo(_normalize(b.name));
    });

    return result;
  }

  List<String> _regionalsForCity(String? city) {
    final normalizedCity = _normalizeFilterText(city ?? '');
    if (normalizedCity.isEmpty) return [];

    final citySchools = _availableSchools
        .where((s) => _normalizeFilterText(s.city) == normalizedCity)
        .toList();

    if (citySchools.any((s) => s.gre.trim().isEmpty)) return [];

    final regionals = citySchools
        .map((s) => s.gre.trim())
        .where((gre) => gre.isNotEmpty)
        .toSet()
        .toList();

    regionals.sort((a, b) => _normalize(a).compareTo(_normalize(b)));
    return regionals;
  }

  void _handleRegionalChanged(String? regional) {
    setState(() {
      _filterRegional = regional;

      if (_filterCity != null &&
          !_containsFilterText(_availableCities, _filterCity)) {
        _filterCity = null;
      }

      _clearSelectedSchool();
    });
  }

  void _handleCityChanged(String? city) {
    setState(() {
      _filterCity = city;

      if (_normalizeFilterText(_filterRegional ?? '').isEmpty) {
        final cityRegionals = _regionalsForCity(city);
        if (cityRegionals.length == 1) {
          _filterRegional = cityRegionals.first;
        }
      }

      _clearSelectedSchool();
    });
  }

  void _clearSelectedSchool({bool clearSchoolText = true}) {
    _selectedSchool = null;
    _selectedSchoolAddress = null;
    _selectedSchoolCity = null;
    _selectedSchoolInep = null;
    _gre = null;
    if (clearSchoolText) {
      _schoolSearchController.clear();
    }
  }


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _schoolSearchController = TextEditingController();
    _schoolSearchFocusNode = FocusNode();

    if (widget.existingReport != null) {
      final r = widget.existingReport!;
      _selectedDate = r.visitDate;
      _selectedSchool = r.schoolName;
      _selectedSchoolAddress = r.schoolAddress;
      _selectedSchoolCity = r.schoolCity;
      _selectedSubjects = List.from(r.subjects);
      _observationsController.text = r.observations ?? '';
      _tiMaterials.addAll(r.tiMaterials);
      _gre = r.gre;
      _selectedPhotos.addAll(r.photos.map((p) => PhotoItem(path: p.path, comment: p.comment)));
      _selectedTechnicians = List.from(r.technicians);
      _selectedResponsible = r.responsiblePerson;
      
      _filterRegional = r.gre;
      _filterCity = r.schoolCity;
      _schoolSearchController.text = r.schoolName;
      _syncSignatureControllersWithTechnicians();

      // Carregar INEP do relatório existente
      _selectedSchoolInep = r.schoolInep;

      // Tentar inferir a cidade e INEP para relatórios antigos caso estejam vazios
      if ((_selectedSchoolCity == null || _selectedSchoolCity!.trim().isEmpty) && _selectedSchool != null) {
        try {
          final schoolNameLower = _selectedSchool!.trim().toLowerCase();
          final school = SchoolService().schools.firstWhere(
            (s) => s.name.trim().toLowerCase() == schoolNameLower,
          );
          if (school.city.trim().isNotEmpty) {
            _selectedSchoolCity = school.city.trim();
            _filterCity = _selectedSchoolCity;
          }
          if (_selectedSchoolInep == null || _selectedSchoolInep!.trim().isEmpty) {
            _selectedSchoolInep = school.inep.trim();
          }
        } catch (_) {}
      }

      // Fallback: buscar INEP pelo nome via GoogleSheetsService
      if (_selectedSchoolInep == null || _selectedSchoolInep!.trim().isEmpty) {
        _selectedSchoolInep = GoogleSheetsService.findInepBySchoolName(_selectedSchool);
      }
    }

    _loadSchools();
    _loadTechnicians();
    _syncSignatureControllersWithTechnicians();

    // Rascunho automático: só para relatórios novos (edição já parte de dados
    // reais salvos no servidor, então não precisa de rascunho local).
    if (widget.existingReport == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkForSavedDraft());
      _draftTimer = Timer.periodic(const Duration(seconds: 2), (_) => _saveDraftIfChanged());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _saveDraftIfChanged();
    }
  }

  Map<String, dynamic> _buildDraftSnapshot() {
    return {
      'selectedDate': _selectedDate?.toIso8601String(),
      'selectedSchool': _selectedSchool,
      'selectedSchoolAddress': _selectedSchoolAddress,
      'selectedSchoolCity': _selectedSchoolCity,
      'selectedSchoolInep': _selectedSchoolInep,
      'gre': _gre,
      'selectedResponsible': _selectedResponsible,
      'filterRegional': _filterRegional,
      'filterCity': _filterCity,
      'selectedSubjects': _selectedSubjects,
      'selectedTechnicians': _selectedTechnicians,
      'observations': _observationsController.text,
      'schoolSearchText': _schoolSearchController.text,
      'photos': _selectedPhotos.map((p) => p.toJson()).toList(),
      'tiMaterials': _tiMaterials.map((m) => m.toJson()).toList(),
      'savedAt': DateTime.now().toIso8601String(),
    };
  }

  bool _isDraftSnapshotEmpty(Map<String, dynamic> snapshot) {
    return (snapshot['selectedSchool'] == null || (snapshot['selectedSchool'] as String).trim().isEmpty) &&
        (snapshot['selectedSubjects'] as List).isEmpty &&
        (snapshot['selectedTechnicians'] as List).isEmpty &&
        (snapshot['selectedResponsible'] == null) &&
        (snapshot['observations'] as String).trim().isEmpty &&
        (snapshot['photos'] as List).isEmpty &&
        (snapshot['tiMaterials'] as List).isEmpty;
  }

  Future<void> _saveDraftIfChanged() async {
    if (_draftSubmitted) return;
    try {
      final snapshot = _buildDraftSnapshot();
      if (_isDraftSnapshotEmpty(snapshot)) return;

      final encoded = jsonEncode(snapshot);
      if (encoded == _lastSavedDraftJson) return;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_draftPrefsKey, encoded);
      _lastSavedDraftJson = encoded;
    } catch (e) {
      debugPrint('Erro ao salvar rascunho do relatório: $e');
    }
  }

  Future<void> _clearDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_draftPrefsKey);
      _lastSavedDraftJson = null;
    } catch (e) {
      debugPrint('Erro ao limpar rascunho do relatório: $e');
    }
  }

  Future<void> _checkForSavedDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_draftPrefsKey);
      if (raw == null || raw.trim().isEmpty) return;

      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (_isDraftSnapshotEmpty(decoded)) {
        await prefs.remove(_draftPrefsKey);
        return;
      }
      if (!mounted) return;

      final schoolLabel = (decoded['selectedSchool'] as String?)?.trim();
      final savedAtRaw = decoded['savedAt'] as String?;
      String savedAtLabel = '';
      if (savedAtRaw != null) {
        final savedAt = DateTime.tryParse(savedAtRaw);
        if (savedAt != null) {
          savedAtLabel = ' (${savedAt.day.toString().padLeft(2, '0')}/${savedAt.month.toString().padLeft(2, '0')} às ${savedAt.hour.toString().padLeft(2, '0')}:${savedAt.minute.toString().padLeft(2, '0')})';
        }
      }

      final shouldRestore = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Rascunho encontrado'),
          content: Text(
            (schoolLabel != null && schoolLabel.isNotEmpty)
                ? 'Você tem um relatório não finalizado de "$schoolLabel"$savedAtLabel. Deseja continuar de onde parou?'
                : 'Você tem um relatório não finalizado$savedAtLabel. Deseja continuar de onde parou?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Começar novo'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Continuar rascunho'),
            ),
          ],
        ),
      );

      if (shouldRestore == true) {
        _applyDraftSnapshot(decoded);
      } else {
        await prefs.remove(_draftPrefsKey);
      }
    } catch (e) {
      debugPrint('Erro ao verificar rascunho salvo: $e');
    }
  }

  void _applyDraftSnapshot(Map<String, dynamic> snapshot) {
    setState(() {
      final dateStr = snapshot['selectedDate'] as String?;
      _selectedDate = dateStr != null ? DateTime.tryParse(dateStr) : null;
      _selectedSchool = snapshot['selectedSchool'] as String?;
      _selectedSchoolAddress = snapshot['selectedSchoolAddress'] as String?;
      _selectedSchoolCity = snapshot['selectedSchoolCity'] as String?;
      _selectedSchoolInep = snapshot['selectedSchoolInep'] as String?;
      _gre = snapshot['gre'] as String?;
      _selectedResponsible = snapshot['selectedResponsible'] as String?;
      _filterRegional = snapshot['filterRegional'] as String?;
      _filterCity = snapshot['filterCity'] as String?;
      _selectedSubjects = List<String>.from(snapshot['selectedSubjects'] as List? ?? []);
      _selectedTechnicians = List<String>.from(snapshot['selectedTechnicians'] as List? ?? []);
      _observationsController.text = snapshot['observations'] as String? ?? '';
      _schoolSearchController.text = snapshot['schoolSearchText'] as String? ?? (snapshot['selectedSchool'] as String? ?? '');
      _selectedPhotos
        ..clear()
        ..addAll((snapshot['photos'] as List? ?? [])
            .map((p) => PhotoItem.fromJson(Map<String, dynamic>.from(p as Map))));
      _tiMaterials
        ..clear()
        ..addAll((snapshot['tiMaterials'] as List? ?? [])
            .map((m) => TiMaterialItem.fromJson(Map<String, dynamic>.from(m as Map))));
      _lastSavedDraftJson = jsonEncode(snapshot);
      _syncSignatureControllersWithTechnicians();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rascunho restaurado. Confira os dados e desenhe a assinatura novamente antes de salvar.')),
      );
    }
  }

  void _syncSignatureControllersWithTechnicians() {
    final keepCount = _isTechnicalAnalysis ? _selectedTechnicians.length : 1;
    final existingCount = _signatureControllers.length;
    final newControllers = <SignatureController>[];

    for (var index = 0; index < keepCount; index++) {
      if (index < existingCount) {
        newControllers.add(_signatureControllers[index]);
      } else {
        newControllers.add(SignatureController(
          penStrokeWidth: 3,
          penColor: Colors.black,
          exportBackgroundColor: Colors.white,
        ));
      }
    }

    for (var index = keepCount; index < existingCount; index++) {
      _signatureControllers[index].dispose();
    }

    _signatureControllers
      ..clear()
      ..addAll(newControllers);

    if (mounted) {
      setState(() {});
    }
  }

  void _presentDatePicker() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme,
          ),
          child: child!,
        );
      },
    );
    if (pickedDate != null) {
      setState(() => _selectedDate = pickedDate);
    }
  }

  void _openMultiSelect(String title, List<String> options, List<String> selected, Function(List<String>) onConfirm) async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => MultiSelectDialog(
        title: title,
        options: options,
        initialSelectedOptions: selected,
      ),
    );

    if (result != null) {
      setState(() => onConfirm(result));
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final pickedFile = await _picker.pickImage(source: source, imageQuality: 80);
      if (pickedFile != null) {
        setState(() => _selectedPhotos.add(PhotoItem(path: pickedFile.path, comment: '')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro ao carregar foto: $e')));
    }
  }

  void _submitData() async {
    if (_formKey.currentState!.validate() && _selectedDate != null && _selectedSchool != null) {
      final signatureBytesList = <Uint8List>[];
      for (var controller in _signatureControllers) {
        if (controller.isNotEmpty) {
          final bytes = await controller.toPngBytes();
          if (bytes != null && bytes.isNotEmpty) {
            signatureBytesList.add(bytes);
          }
        }
      }

      if (signatureBytesList.isEmpty && widget.existingReport != null) {
        if (widget.existingReport!.signatureBytesList != null &&
            widget.existingReport!.signatureBytesList!.isNotEmpty) {
          signatureBytesList.addAll(widget.existingReport!.signatureBytesList!);
        } else if (widget.existingReport!.signatureBytes != null) {
          signatureBytesList.add(widget.existingReport!.signatureBytes!);
        }
      }

      final hasExistingSignatureUrl = widget.existingReport != null &&
          ((widget.existingReport!.signatureUrl != null &&
                  widget.existingReport!.signatureUrl!.trim().isNotEmpty) ||
              (widget.existingReport!.signatureUrlList != null &&
                  widget.existingReport!.signatureUrlList!.isNotEmpty));

      if (signatureBytesList.isEmpty && !hasExistingSignatureUrl) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A assinatura é obrigatória para novos relatórios.')),
        );
        return;
      }

      final report = ReportModel(
        id: widget.existingReport?.id ?? DateTime.now().toString(),
        reportNumber: widget.existingReport?.reportNumber,
        isTechnicalAnalysis: _isTechnicalAnalysis,
        creator: widget.existingReport?.creator ?? widget.loggedUser,
        schoolName: _selectedSchool!,
        schoolAddress: _selectedSchoolAddress,
        schoolCity: _selectedSchoolCity,
        schoolInep: _selectedSchoolInep,
        visitDate: _selectedDate!,
        subjects: _selectedSubjects,
        observations: _observationsController.text,
        tiMaterials: _isTechnicalAnalysis ? List<TiMaterialItem>.from(_tiMaterials) : const [],
        gre: _gre,
        photos: _selectedPhotos,
        technicians: _selectedTechnicians,
        responsiblePerson: !_isTechnicalAnalysis ? _selectedResponsible : null,
        signatureBytes: signatureBytesList.isNotEmpty ? signatureBytesList.first : widget.existingReport?.signatureBytes,
        signatureBytesList: signatureBytesList.isNotEmpty ? signatureBytesList : widget.existingReport?.signatureBytesList,
        signatureUrl: widget.existingReport?.signatureUrl,
        signatureUrlList: widget.existingReport?.signatureUrlList ??
            (widget.existingReport?.signatureUrl != null ? [widget.existingReport!.signatureUrl!] : null),
      );

      _draftSubmitted = true;
      await _clearDraft();

      if (!mounted) return;
      Navigator.of(context).pop(report);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Preencha todos os campos obrigatórios.')),
      );
    }
  }

  Widget _buildHeader() {
    final theme = Theme.of(context);
    final isEditing = widget.existingReport != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isEditing ? theme.colorScheme.tertiaryContainer : theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  isEditing ? 'Edição' : 'Novo',
                  style: TextStyle(
                    color: isEditing ? theme.colorScheme.onTertiaryContainer : theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            isEditing ? 'Editar Relatório' : 'Novo Relatório',
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface),
          ),
          const SizedBox(height: 4),
          Text(
            'Preencha as informações da visita técnica',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildDateSection() {
    final theme = Theme.of(context);
    final hasError = _selectedDate == null && _formKey.currentState != null && !_formKey.currentState!.validate();

    return SectionCard(
      title: 'Dados da Visita',
      icon: Icons.event_note_outlined,
      child: InkWell(
        onTap: _presentDatePicker,
        borderRadius: BorderRadius.circular(12),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: 'Data do chamado',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            prefixIcon: Icon(Icons.calendar_month_rounded, color: theme.colorScheme.primary),
            errorText: hasError ? 'Selecione a data da visita' : null,
          ),
          child: Text(
            _selectedDate == null ? 'Selecione a data...' : DateFormat('dd/MM/yyyy').format(_selectedDate!),
            style: TextStyle(
              fontSize: 16,
              color: _selectedDate == null ? theme.colorScheme.onSurfaceVariant : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRegionalFilterField() {
    return DropdownButtonFormField<String>(
      key: ValueKey('regional_$_filterRegional'),
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Filtrar por Regional',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        prefixIcon: const Icon(Icons.map_outlined),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
      initialValue: _containsFilterText(_availableRegionals, _filterRegional)
          ? _filterRegional
          : null,
      items: [
        const DropdownMenuItem(
          value: null,
          child: Text('Todas as Regionais'),
        ),
        ..._availableRegionals.map(
          (regional) => DropdownMenuItem(
            value: regional,
            child: Text(regional, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: _handleRegionalChanged,
    );
  }

  Widget _buildCityFilterField() {
    return DropdownButtonFormField<String>(
      key: ValueKey('city_$_filterCity'),
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Filtrar por Município',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        prefixIcon: const Icon(Icons.location_city_outlined),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
      initialValue:
          _containsFilterText(_availableCities, _filterCity) ? _filterCity : null,
      items: [
        const DropdownMenuItem(
          value: null,
          child: Text('Todos os Municípios'),
        ),
        ..._availableCities.map(
          (city) => DropdownMenuItem(
            value: city,
            child: Text(city, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: _handleCityChanged,
    );
  }

  Widget _buildSchoolCounterChip(IconData icon, String label) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildSchoolSection() {
    final theme = Theme.of(context);
    final isLargeScreen = MediaQuery.of(context).size.width > 600;
    final filteredSchoolCount =
        _getFilteredSchools(_schoolSearchController.text).length;

    return SectionCard(
      title: 'Escola',
      icon: Icons.school_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_isLoadingSchools) ...[
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Carregando base de escolas...'),
                  ],
                ),
              ),
            ),
          ] else if (_availableSchools.isEmpty && _schoolsLoadError != null) ...[
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Column(
                  children: [
                    Icon(Icons.error_outline, color: theme.colorScheme.error, size: 40),
                    const SizedBox(height: 12),
                    Text('Erro ao carregar escolas: $_schoolsLoadError', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: _loadSchools,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tentar Novamente'),
                    ),
                  ],
                ),
              ),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (isLargeScreen)
                    Row(
                      children: [
                        Expanded(child: _buildRegionalFilterField()),
                        const SizedBox(width: 12),
                        Expanded(child: _buildCityFilterField()),
                      ],
                    )
                  else ...[
                    _buildRegionalFilterField(),
                    const SizedBox(height: 12),
                    _buildCityFilterField(),
                  ],
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _buildSchoolCounterChip(
                        Icons.location_city_outlined,
                        '${_availableCities.length} município(s)',
                      ),
                      _buildSchoolCounterChip(
                        Icons.school_outlined,
                        '$filteredSchoolCount escola(s)',
                      ),
                      if (_filterRegional != null || _filterCity != null)
                        TextButton.icon(
                          onPressed: () {
                            setState(() {
                              _filterRegional = null;
                              _filterCity = null;
                              _clearSelectedSchool();
                            });
                          },
                          icon: const Icon(Icons.clear_all_rounded, size: 16),
                          label: const Text('Limpar Filtros'),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),

            if (_filterRegional != null && _schoolsBySelectedRegional.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
                child: Text(
                  'Nenhuma escola cadastrada para esta regional.',
                  style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              )
            else if (_filterRegional != null && _filterCity != null && _getFilteredSchools('').isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8.0, bottom: 8.0),
                child: Text(
                  'Nenhuma escola encontrada para este município.',
                  style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.bold, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),

            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                return Autocomplete<SchoolModel>(
                  key: ValueKey('school_search_${_filterRegional}_$_filterCity'),
                  textEditingController: _schoolSearchController,
                  focusNode: _schoolSearchFocusNode,
                  displayStringForOption: (option) => option.name,
                  optionsBuilder: (TextEditingValue textEditingValue) {
                    return _getFilteredSchools(textEditingValue.text);
                  },
                  onSelected: (SchoolModel selection) {
                    setState(() {
                      _selectedSchool = selection.name;
                      _gre = selection.gre;
                      _selectedSchoolAddress = selection.address;
                      _selectedSchoolCity = selection.city;
                      _selectedSchoolInep = selection.inep;
                      if (_filterRegional == null || _filterRegional!.isEmpty) {
                        _filterRegional =
                            _containsFilterText(_availableRegionals, selection.gre)
                                ? selection.gre
                                : null;
                      }
                      if (_filterCity == null || _filterCity!.isEmpty) {
                        _filterCity =
                            _containsFilterText(_availableCities, selection.city)
                                ? selection.city
                                : null;
                      }
                      _schoolSearchController.text = selection.name;
                    });
                  },
                  fieldViewBuilder: (context, controller, focusNode, onEditingComplete) {
                    return TextFormField(
                      controller: controller,
                      focusNode: focusNode,
                      decoration: InputDecoration(
                        labelText: 'Buscar Escola (Nome ou INEP)',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        filled: true,
                        fillColor: theme.colorScheme.surface,
                        prefixIcon: const Icon(Icons.school_outlined),
                        suffixIcon: const Icon(Icons.search_rounded),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                      onEditingComplete: onEditingComplete,
                      validator: (value) => _selectedSchool == null ? 'Selecione uma escola da lista' : null,
                      onChanged: (v) {
                        setState(() {
                          if (_selectedSchool != null &&
                              !_sameFilterText(v, _selectedSchool)) {
                            _clearSelectedSchool(clearSchoolText: false);
                          }
                        });
                      },
                    );
                  },
                  optionsViewBuilder: (context, onSelected, options) {
                    return Align(
                      alignment: Alignment.topLeft,
                      child: Material(
                        elevation: 8.0,
                        borderRadius: BorderRadius.circular(12),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: 250, maxWidth: constraints.maxWidth),
                          child: ListView.separated(
                            padding: EdgeInsets.zero,
                            itemCount: options.length,
                            separatorBuilder: (_, _) => const Divider(height: 1),
                            itemBuilder: (BuildContext context, int index) {
                              final option = options.elementAt(index);
                              return ListTile(
                                title: Text(option.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                                subtitle: Text('${option.inep} • ${option.city}\n${option.gre}'),
                                onTap: () => onSelected(option),
                              );
                            },
                          ),
                        ),
                      ),
                    );
                  },
                );
              }
            ),
            if (_selectedSchool != null) ...[
              const SizedBox(height: 16),
              Card(
                elevation: 0,
                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.2)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.check_circle_rounded, color: theme.colorScheme.primary, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _selectedSchool!,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildSelectedSchoolChip(Icons.map_outlined, _gre ?? 'GRE não informada'),
                          _buildSelectedSchoolChip(Icons.location_city_outlined, _selectedSchoolCity ?? 'Município não informado'),
                          _buildSelectedSchoolChip(Icons.numbers_rounded, _selectedSchoolInep ?? 'INEP não informado'),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.location_on_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${_selectedSchoolAddress ?? "N/A"} - ${_selectedSchoolCity ?? "N/A"}',
                              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_isTechnicalAnalysis) ...[
              const SizedBox(height: 16),
              TextFormField(
                key: ValueKey('gre_$_gre'),
                initialValue: _gre,
                decoration: InputDecoration(
                  labelText: 'GRE (Gerência Regional de Educação)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.account_balance_outlined),
                ),
                onChanged: (v) => _gre = v,
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildSelectedSchoolChip(IconData icon, String label) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colorScheme.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubjectsSection() {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'Motivos / Assuntos',
      icon: Icons.category_outlined,
      child: InkWell(
        onTap: () => _openMultiSelect('Motivo do Chamado', _mockSubjects, _selectedSubjects, (res) {
          _selectedSubjects = res;
          _syncSignatureControllersWithTechnicians();
        }),
        borderRadius: BorderRadius.circular(12),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: 'Motivos do Chamado',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            prefixIcon: Icon(Icons.category_outlined, color: theme.colorScheme.primary),
            suffixIcon: Icon(Icons.add_circle_outline, color: theme.colorScheme.primary),
          ),
          child: _selectedSubjects.isEmpty
              ? Text('Selecionar motivos', style: TextStyle(fontSize: 16, color: theme.colorScheme.onSurfaceVariant))
              : Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: _selectedSubjects.map((subject) => Chip(
                    label: Text(subject, style: const TextStyle(fontSize: 12)),
                    backgroundColor: theme.colorScheme.secondaryContainer,
                    side: BorderSide.none,
                  )).toList(),
                ),
        ),
      ),
    );
  }

  Widget _buildTechniciansSection() {
    final theme = Theme.of(context);

    return SectionCard(
      title: 'Técnicos Presentes',
      icon: Icons.engineering_outlined,
      actions: [
        TextButton.icon(
          onPressed: _openTechniciansSelector,
          icon: _isLoadingTechnicians
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_circle_outline, size: 18),
          label: const Text('Adicionar'),
        ),
      ],
      child: InkWell(
        onTap: _openTechniciansSelector,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.18),
          ),
          child: _selectedTechnicians.isEmpty
              ? Row(
                  children: [
                    Icon(Icons.person_add_alt_1_outlined, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Selecionar técnicos',
                        style: TextStyle(fontSize: 16, color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                )
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _selectedTechnicians.map((technician) => Chip(
                    avatar: Icon(
                      Icons.person_rounded,
                      size: 16,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                    label: Text(technician, style: const TextStyle(fontSize: 12)),
                    backgroundColor: theme.colorScheme.secondaryContainer,
                    side: BorderSide.none,
                  )).toList(),
                ),
        ),
      ),
    );
  }

  void _openTechniciansSelector() {
    if (_isLoadingTechnicians) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Carregando técnicos...')),
      );
      return;
    }

    if (_availableTechnicians.isEmpty && _techniciansLoadError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Erro ao carregar técnicos da aba Técnicos: $_techniciansLoadError'),
          action: SnackBarAction(
            label: 'Tentar novamente',
            onPressed: _loadTechnicians,
          ),
        ),
      );
      return;
    }

    if (_availableTechnicians.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Nenhum técnico encontrado na aba Técnicos.'),
          action: SnackBarAction(
            label: 'Recarregar',
            onPressed: _loadTechnicians,
          ),
        ),
      );
      return;
    }

    final setOfNames = _availableTechnicians
        .map((t) => t.name.trim())
        .where((name) => name.isNotEmpty)
        .toSet();

    // Preservar técnicos antigos selecionados mesmo se não estiverem na lista atual
    for (var existingName in _selectedTechnicians) {
      if (existingName.trim().isNotEmpty) {
        setOfNames.add(existingName.trim());
      }
    }

    final technicianNames = setOfNames.toList()
      ..sort((a, b) => _normalize(a).compareTo(_normalize(b)));

    _openMultiSelect(
      'Técnico(s)',
      technicianNames,
      _selectedTechnicians,
      (res) {
        _selectedTechnicians = res;
        _syncSignatureControllersWithTechnicians();
      },
    );
  }

  Future<void> _openTiMaterialDialog({TiMaterialItem? item, int? index}) async {
    final result = await showDialog<TiMaterialItem>(
      context: context,
      builder: (dialogContext) => _TiMaterialDialog(
        item: item,
        ambientes: _tiMaterialAmbientes,
        equipamentos: _tiMaterialEquipamentos,
      ),
    );

    if (!mounted || result == null) return;
    setState(() {
      if (index != null && index >= 0 && index < _tiMaterials.length) {
        _tiMaterials[index] = result;
      } else {
        _tiMaterials.add(result);
      }
    });
  }

  Widget _buildTiMaterialsSection() {
    if (!_isTechnicalAnalysis) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final grouped = <String, List<MapEntry<int, TiMaterialItem>>>{};
    for (var i = 0; i < _tiMaterials.length; i++) {
      final material = _tiMaterials[i];
      grouped.putIfAbsent(material.ambiente, () => []).add(MapEntry(i, material));
    }

    return SectionCard(
      title: 'Materiais de TI necessários',
      subtitle: 'Informe os materiais por ambiente para execução da análise técnica.',
      icon: Icons.inventory_2_outlined,
      actions: [
        TextButton.icon(
          onPressed: () => _openTiMaterialDialog(),
          icon: const Icon(Icons.add_circle_outline, size: 18),
          label: const Text('Adicionar material de TI'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton.icon(
            onPressed: () => _openTiMaterialDialog(),
            icon: const Icon(Icons.add_rounded),
            label: const Text('Adicionar material de TI'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          if (_tiMaterials.isEmpty) ...[
            const SizedBox(height: 14),
            Text(
              'Nenhum material informado.',
              style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ] else ...[
            const SizedBox(height: 16),
            ...grouped.entries.map((entry) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.key,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ...List<MapEntry<int, TiMaterialItem>>.from(entry.value).map((indexedMaterial) {
                      final index = indexedMaterial.key;
                      final material = indexedMaterial.value;
                      final marca = material.marcaModelo.trim();
                      final observacao = material.observacao.trim();
                      return Container(
                        key: ValueKey('${material.ambiente}_${material.equipamento}_${material.quantidade}_$index'),
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.55)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.memory_outlined, color: colorScheme.primary, size: 20),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    marca.isEmpty ? material.equipamento : '${material.equipamento} $marca',
                                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Quantidade: ${material.quantidade}',
                                    style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                                  ),
                                  if (observacao.isNotEmpty) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      observacao,
                                      style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Editar',
                              onPressed: () => _openTiMaterialDialog(item: material, index: index),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                            IconButton(
                              tooltip: 'Remover',
                              onPressed: () {
                                if (index < 0 || index >= _tiMaterials.length) return;
                                setState(() {
                                  _tiMaterials.removeAt(index);
                                });
                              },
                              icon: Icon(Icons.delete_outline, color: colorScheme.error),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildResponsibleSection() {
    if (_isTechnicalAnalysis) return const SizedBox.shrink();

    return SectionCard(
      title: 'Responsável',
      icon: Icons.badge_outlined,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Autocomplete<EmployeeModel>(
            displayStringForOption: (option) => option.name,
            optionsBuilder: (TextEditingValue textEditingValue) {
              final q = textEditingValue.text.trim();
              if (q.length < 2) return const Iterable<EmployeeModel>.empty();
              final service = EmployeeService();
              if (RegExp(r'^\d+$').hasMatch(q)) {
                final res = service.all.where((e) => e.matricula.startsWith(q)).take(15).toList();
                res.sort((a, b) {
                  if (a.matricula == q) return -1;
                  if (b.matricula == q) return 1;
                  return a.matricula.compareTo(b.matricula);
                });
                return res;
              }
              return service.searchByName(q).take(15);
            },
            onSelected: (EmployeeModel selection) {
              setState(() {
                _selectedResponsible = selection.name;
              });
            },
            fieldViewBuilder: (context, controller, focusNode, onEditingComplete) {
              if (_selectedResponsible != null && controller.text != _selectedResponsible && !focusNode.hasFocus) {
                controller.text = _selectedResponsible!;
              }
              return TextFormField(
                controller: controller,
                focusNode: focusNode,
                decoration: InputDecoration(
                  labelText: 'Responsável pela escola (Matrícula ou Nome)',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  prefixIcon: const Icon(Icons.person_search_outlined),
                  suffixIcon: const Icon(Icons.search_rounded),
                ),
                onEditingComplete: onEditingComplete,
                validator: (value) => _selectedResponsible == null ? 'Campo obrigatório' : null,
                onChanged: (v) {
                  if (_selectedResponsible != null && v != _selectedResponsible) {
                    setState(() => _selectedResponsible = null);
                  }
                },
              );
            },
            optionsViewBuilder: (context, onSelected, options) {
              return Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 8.0,
                  borderRadius: BorderRadius.circular(12),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: 250, maxWidth: constraints.maxWidth),
                    child: ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: options.length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) {
                        final option = options.elementAt(index);
                        return ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.badge_outlined)),
                          title: Text(option.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                          subtitle: Text('Matrícula: ${option.matricula}', style: const TextStyle(fontSize: 12)),
                          onTap: () => onSelected(option),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          );
        }
      ),
    );
  }

  Widget _buildObservationsSection() {
    return SectionCard(
      title: 'Diagnóstico / Observações',
      icon: Icons.notes_outlined,
      child: TextFormField(
        controller: _observationsController,
        maxLines: 5,
        minLines: 5,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: 'Descreva os detalhes da visita',
          hintText: 'Ex: Foi realizada a manutenção...',
          alignLabelWithHint: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          prefixIcon: const Padding(
            padding: EdgeInsets.only(bottom: 80), // Alinha o ícone no topo
            child: Icon(Icons.notes_outlined),
          ),
        ),
        validator: (value) => (value == null || value.trim().isEmpty) ? 'Campo obrigatório' : null,
      ),
    );
  }

  Widget _buildPhotosSection() {
    final theme = Theme.of(context);
    final isLargeScreen = MediaQuery.of(context).size.width > 600;
    final bool canUseCamera = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    final photoCount = _selectedPhotos.length;

    return SectionCard(
      title: 'Anexos Fotográficos',
      icon: Icons.photo_library_outlined,
      actions: [
        _buildPhotoCountChip(photoCount),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (isLargeScreen)
            Row(
              children: [
                if (canUseCamera) ...[
                  Expanded(child: _buildPhotoButton(Icons.camera_alt_outlined, 'Câmera', ImageSource.camera)),
                  const SizedBox(width: 16),
                ],
                Expanded(child: _buildPhotoButton(Icons.add_photo_alternate_outlined, 'Adicionar Foto', ImageSource.gallery)),
              ],
            )
          else ...[
            if (canUseCamera) ...[
              _buildPhotoButton(Icons.camera_alt_outlined, 'Câmera', ImageSource.camera),
              const SizedBox(height: 12),
            ],
            _buildPhotoButton(Icons.add_photo_alternate_outlined, 'Adicionar Foto', ImageSource.gallery),
          ],
          if (_selectedPhotos.isNotEmpty) ...[
            const SizedBox(height: 18),
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _selectedPhotos.length,
              itemBuilder: (ctx, idx) {
                final photo = _selectedPhotos[idx];
                return Card(
                  elevation: 0,
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12.0),
                    child: isLargeScreen 
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildPhotoPreview(photo, idx, theme),
                          const SizedBox(width: 16),
                          Expanded(child: _buildPhotoComment(photo, theme)),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _buildPhotoPreview(photo, idx, theme),
                          const SizedBox(height: 12),
                          _buildPhotoComment(photo, theme),
                        ],
                    ),
                  ),
                );
              },
            ),
          ]
        ],
      ),
    );
  }

  Widget _buildPhotoButton(IconData icon, String label, ImageSource source) {
    return OutlinedButton.icon(
      onPressed: () => _pickImage(source),
      icon: Icon(icon),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        minimumSize: const Size(double.infinity, 50),
      ),
    );
  }

  Widget _buildPhotoCountChip(int count) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count foto(s)',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w800,
            ),
      ),
    );
  }

  Widget _buildPhotoPreview(PhotoItem photo, int idx, ThemeData theme) {
    final path = photo.path.trim();
    final bool isNetwork = path.startsWith('http://') || path.startsWith('https://');
    final bool isBase64 = path.startsWith('data:image') ||
        (RegExp(r'^[a-zA-Z0-9+/=]+$').hasMatch(path) && path.length > 100);

    Widget imageWidget;
    final placeholder = Container(
      width: 100,
      height: 100,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(Icons.broken_image_outlined, color: theme.colorScheme.onSurfaceVariant),
    );

    if (isBase64) {
      try {
        final clean = path.contains(',') ? path.split(',').last : path;
        imageWidget = Image.memory(base64Decode(clean), width: 100, height: 100, fit: BoxFit.cover);
      } catch (_) {
        imageWidget = placeholder;
      }
    } else if (isNetwork || kIsWeb) {
      imageWidget = Image.network(
        path,
        width: 100,
        height: 100,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => placeholder,
      );
    } else {
      imageWidget = Image.file(
        File(path),
        width: 100,
        height: 100,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => placeholder,
      );
    }
      
    return Stack(
      alignment: Alignment.topRight,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: imageWidget,
        ),
        GestureDetector(
          onTap: () => setState(() => _selectedPhotos.removeAt(idx)),
          child: Container(
            margin: const EdgeInsets.all(4),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: theme.colorScheme.error, shape: BoxShape.circle),
            child: Icon(Icons.close_rounded, size: 16, color: theme.colorScheme.onError),
          ),
        )
      ],
    );
  }

  Widget _buildPhotoComment(PhotoItem photo, ThemeData theme) {
    return TextFormField(
      initialValue: photo.comment,
      maxLines: 3,
      minLines: 3,
      textCapitalization: TextCapitalization.sentences,
      decoration: InputDecoration(
        labelText: 'Comentário da Foto',
        alignLabelWithHint: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: theme.colorScheme.surface,
      ),
      onChanged: (v) => photo.comment = v,
    );
  }

  Widget _buildSignatureSection() {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return SectionCard(
      title: _isTechnicalAnalysis ? 'Assinatura do Técnico' : 'Assinatura do Responsável',
      icon: Icons.draw_outlined,
      child: _isTechnicalAnalysis
          ? _buildTechnicianSignatures(theme, isDark)
          : _buildResponsibleSignature(theme, isDark),
    );
  }

  Widget _buildSavedSignaturePreview(String? url, ThemeData theme) {
    if (url == null || url.trim().isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Assinatura salva anteriormente:',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
              color: Colors.white,
            ),
            child: Image.network(
              url,
              height: 100,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) => Container(
                height: 100,
                alignment: Alignment.center,
                child: Icon(Icons.broken_image_outlined, color: theme.colorScheme.onSurfaceVariant),
              ),
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return SizedBox(
                  height: 100,
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTechnicianSignatures(ThemeData theme, bool isDark) {
    if (_selectedTechnicians.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceVariant.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.35)),
        ),
        child: Text(
          'Selecione pelo menos um técnico para capturar a assinatura.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    final hasAnyExistingSignature = widget.existingReport != null &&
        (((widget.existingReport!.signatureBytesList?.isNotEmpty) ?? false) ||
            ((widget.existingReport!.signatureUrlList?.isNotEmpty) ?? false)) &&
        _signatureControllers.every((c) => c.isEmpty);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasAnyExistingSignature)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.tertiary.withOpacity(0.25)),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: theme.colorScheme.tertiary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Assinaturas salvas anteriormente. Desenhe abaixo apenas se quiser alterar as assinaturas atuais.',
                    style: TextStyle(color: theme.colorScheme.tertiary, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _selectedTechnicians.length,
          separatorBuilder: (_, __) => const SizedBox(height: 18),
          itemBuilder: (context, index) {
            final technician = _selectedTechnicians[index];
            debugPrint('Construindo assinatura para técnico #$index: $technician');
            final controller = index < _signatureControllers.length
                ? _signatureControllers[index]
                : SignatureController(
                    penStrokeWidth: 3,
                    penColor: Colors.black,
                    exportBackgroundColor: Colors.white,
                  );

            final existingUrlList = widget.existingReport?.signatureUrlList;
            final existingUrl = (controller.isEmpty &&
                    existingUrlList != null &&
                    index < existingUrlList.length)
                ? existingUrlList[index]
                : null;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        'Assinatura de $technician',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => controller.clear(),
                      icon: const Icon(Icons.cleaning_services_rounded, size: 16),
                      label: const Text('Limpar'),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        minimumSize: Size.zero,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildSavedSignaturePreview(existingUrl, theme),
                Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Signature(
                    controller: controller,
                    height: 180,
                    backgroundColor: isDark ? const Color(0xFFE0E0E0) : theme.colorScheme.surface,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildResponsibleSignature(ThemeData theme, bool isDark) {
    if (_selectedResponsible == null || _selectedResponsible!.trim().isEmpty) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceVariant.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant.withOpacity(0.35)),
        ),
        child: Text(
          'Selecione o responsável pela escola para capturar a assinatura.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }

    final controller = _signatureControllers.isNotEmpty
        ? _signatureControllers.first
        : SignatureController(
            penStrokeWidth: 3,
            penColor: Colors.black,
            exportBackgroundColor: Colors.white,
          );

    final hasExistingResponsibleSignature = widget.existingReport != null &&
        (((widget.existingReport!.signatureBytesList?.isNotEmpty) ?? false) ||
            (widget.existingReport!.signatureUrl != null &&
                widget.existingReport!.signatureUrl!.trim().isNotEmpty) ||
            ((widget.existingReport!.signatureUrlList?.isNotEmpty) ?? false)) &&
        controller.isEmpty;

    final existingResponsibleUrl = hasExistingResponsibleSignature
        ? (widget.existingReport!.signatureUrl ??
            (widget.existingReport!.signatureUrlList?.isNotEmpty == true
                ? widget.existingReport!.signatureUrlList!.first
                : null))
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasExistingResponsibleSignature)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiary.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: theme.colorScheme.tertiary.withOpacity(0.25)),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: theme.colorScheme.tertiary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Assinatura salva anteriormente. Desenhe abaixo apenas se quiser alterar a assinatura atual.',
                    style: TextStyle(color: theme.colorScheme.tertiary, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                'Assinatura de $_selectedResponsible',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () => controller.clear(),
              icon: const Icon(Icons.cleaning_services_rounded, size: 16),
              label: const Text('Limpar'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: Size.zero,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildSavedSignaturePreview(existingResponsibleUrl, theme),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Signature(
            controller: controller,
            height: 180,
            backgroundColor: isDark ? const Color(0xFFE0E0E0) : theme.colorScheme.surface,
          ),
        ),
      ],
    );
  }

  Widget _buildSubmitButton() {
    final theme = Theme.of(context);
    final isLargeScreen = MediaQuery.of(context).size.width > 600;

    final saveButton = PrimaryActionButton(
      label: widget.existingReport != null ? 'Atualizar Relatório' : 'Salvar Relatório',
      icon: Icons.save_rounded,
      onPressed: _submitData,
    );

    final backButton = OutlinedButton.icon(
      onPressed: () => Navigator.of(context).maybePop(),
      icon: const Icon(Icons.arrow_back_rounded),
      label: const Text('Voltar'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(double.infinity, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );

    return SectionCard(
      title: 'Ações Finais',
      icon: Icons.task_alt_outlined,
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.cloud_queue_rounded, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Sem conexão, o relatório será mantido como pendente para sincronizar depois.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (isLargeScreen)
            Row(
              children: [
                Expanded(child: backButton),
                const SizedBox(width: 12),
                Expanded(flex: 2, child: saveButton),
              ],
            )
          else ...[
            saveButton,
            const SizedBox(height: 12),
            backButton,
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLargeScreen = MediaQuery.of(context).size.width > 700;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Formulário de Relatório'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(isLargeScreen ? 24.0 : 16.0),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(),
                  _buildDateSection(),
                  _buildSchoolSection(),
                  _buildSubjectsSection(),
                  _buildTechniciansSection(),
                  _buildTiMaterialsSection(),
                  _buildResponsibleSection(),
                  _buildObservationsSection(),
                  _buildPhotosSection(),
                  _buildSignatureSection(),
                  _buildSubmitButton(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    if (!_draftSubmitted) {
      // Última tentativa de salvar o progresso antes da tela ser destruída
      // (ex.: usuário saiu sem enviar). Não precisa aguardar.
      unawaited(_saveDraftIfChanged());
    }
    WidgetsBinding.instance.removeObserver(this);
    _schoolSearchController.dispose();
    _schoolSearchFocusNode.dispose();
    _observationsController.dispose();
    for (var controller in _signatureControllers) {
      controller.dispose();
    }
    super.dispose();
  }
}

class _TiMaterialDialog extends StatefulWidget {
  final TiMaterialItem? item;
  final List<String> ambientes;
  final List<String> equipamentos;

  const _TiMaterialDialog({
    this.item,
    required this.ambientes,
    required this.equipamentos,
  });

  @override
  State<_TiMaterialDialog> createState() => _TiMaterialDialogState();
}

class _TiMaterialDialogState extends State<_TiMaterialDialog> {
  final _formKey = GlobalKey<FormState>();
  final _ambienteController = TextEditingController();
  final _equipamentoController = TextEditingController();
  final _marcaModeloController = TextEditingController();
  final _quantidadeController = TextEditingController();
  final _observacaoController = TextEditingController();
  final _ambienteFocusNode = FocusNode();
  final _equipamentoFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    if (item != null) {
      _ambienteController.text = item.ambiente;
      _equipamentoController.text = item.equipamento;
      _marcaModeloController.text = item.marcaModelo;
      _quantidadeController.text = item.quantidade;
      _observacaoController.text = item.observacao;
    }
  }

  @override
  void dispose() {
    _ambienteController.dispose();
    _equipamentoController.dispose();
    _marcaModeloController.dispose();
    _quantidadeController.dispose();
    _observacaoController.dispose();
    _ambienteFocusNode.dispose();
    _equipamentoFocusNode.dispose();
    super.dispose();
  }

  String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[áàâãäå]'), 'a')
        .replaceAll(RegExp(r'[éèêë]'), 'e')
        .replaceAll(RegExp(r'[íìîï]'), 'i')
        .replaceAll(RegExp(r'[óòôõöø]'), 'o')
        .replaceAll(RegExp(r'[úùûü]'), 'u')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Iterable<String> _filterOptions(List<String> options, TextEditingValue value) {
    final query = _normalize(value.text);
    if (query.isEmpty) return options;
    return options.where((option) => _normalize(option).contains(query));
  }

  Widget _buildAutocompleteField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required List<String> options,
    required String label,
    required IconData icon,
    String? hintText,
    TextCapitalization textCapitalization = TextCapitalization.sentences,
    String? Function(String?)? validator,
  }) {
    return RawAutocomplete<String>(
      textEditingController: controller,
      focusNode: focusNode,
      optionsBuilder: (value) => _filterOptions(options, value),
      onSelected: (selection) => controller.text = selection,
      fieldViewBuilder: (context, fieldController, fieldFocusNode, onFieldSubmitted) {
        return TextFormField(
          controller: fieldController,
          focusNode: fieldFocusNode,
          textCapitalization: textCapitalization,
          decoration: InputDecoration(
            labelText: label,
            hintText: hintText,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            prefixIcon: Icon(icon),
          ),
          validator: validator,
          onFieldSubmitted: (_) => onFieldSubmitted(),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 520),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final option = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    title: Text(option),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  String? _requiredValidator(String? value) {
    return value == null || value.trim().isEmpty ? 'Campo obrigatório' : null;
  }

  String? _quantityValidator(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Campo obrigatório';
    final number = num.tryParse(text.replaceAll(',', '.'));
    if (number != null && number < 1) return 'Informe quantidade maior ou igual a 1';
    return null;
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final item = TiMaterialItem(
      ambiente: _ambienteController.text.trim(),
      equipamento: _equipamentoController.text.trim(),
      marcaModelo: _marcaModeloController.text.trim(),
      quantidade: _quantidadeController.text.trim(),
      observacao: _observacaoController.text.trim(),
    );
    Navigator.of(context).pop(item);
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.item != null;
    return AlertDialog(
      title: Text(isEditing ? 'Editar material de TI' : 'Adicionar material de TI'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildAutocompleteField(
                  controller: _ambienteController,
                  focusNode: _ambienteFocusNode,
                  options: widget.ambientes,
                  label: 'Ambiente',
                  icon: Icons.meeting_room_outlined,
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                _buildAutocompleteField(
                  controller: _equipamentoController,
                  focusNode: _equipamentoFocusNode,
                  options: widget.equipamentos,
                  label: 'Equipamento / Material',
                  icon: Icons.router_outlined,
                  validator: _requiredValidator,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _marcaModeloController,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: 'Marca / Modelo',
                    hintText: 'Ex: TP-Link TL-SG108',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    prefixIcon: const Icon(Icons.sell_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _quantidadeController,
                  keyboardType: TextInputType.text,
                  decoration: InputDecoration(
                    labelText: 'Quantidade',
                    hintText: 'Ex: 2, 30m, 2 caixas',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    prefixIcon: const Icon(Icons.numbers_outlined),
                  ),
                  validator: _quantityValidator,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _observacaoController,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Observação',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    prefixIcon: const Padding(
                      padding: EdgeInsets.only(bottom: 42),
                      child: Icon(Icons.notes_outlined),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: Icon(isEditing ? Icons.check_rounded : Icons.add_rounded, size: 18),
          label: Text(isEditing ? 'Salvar' : 'Adicionar'),
        ),
      ],
    );
  }
}
