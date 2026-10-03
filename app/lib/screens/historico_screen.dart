import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/google_sheets_service.dart';
import '../models/report_model.dart';
import '../utils/pdf_generator.dart';
import '../utils/json_utils.dart';
import '../widgets/app_ui.dart';

class HistoricoScreen extends StatefulWidget {
  const HistoricoScreen({super.key});

  @override
  State<HistoricoScreen> createState() => _HistoricoScreenState();
}

class _HistoricoScreenState extends State<HistoricoScreen> {
  final GoogleSheetsService _sheetsService = GoogleSheetsService();
  final _searchController = TextEditingController();

  List<Map<String, dynamic>> _allHistory = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String? _selectedReportNumber;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);
    try {
      final data = await _sheetsService.fetchHistory();
      if (mounted) {
        setState(() {
          _allHistory = data;
          _applyFilter();
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Erro ao carregar histórico: $e');
      if (mounted) {
        setState(() {
          _allHistory = [];
          _filtered = [];
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao carregar histórico: $e')),
        );
      }
    }
  }

  String _fmt(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    try {
      return DateFormat(
        'dd/MM/yyyy HH:mm',
      ).format(DateTime.parse(iso).toLocal());
    } catch (_) {
      return iso;
    }
  }

  String _fmtDate(String? iso) {
    if (iso == null || iso.isEmpty) return '—';
    try {
      return DateFormat('dd/MM/yyyy').format(DateTime.parse(iso).toLocal());
    } catch (_) {
      return iso;
    }
  }

  void _applyFilter() {
    if (_searchQuery.isEmpty) {
      _filtered = List.from(_allHistory);
    } else {
      final q = _normalizeSearchText(_searchQuery);
      _filtered = _allHistory.where((h) {
        final searchable = _normalizeSearchText(
          [
            _safeReportNumber(h),
            h['escola'],
            h['schoolName'],
            h['usuario'],
            h['editadoPor'],
            h['tecnicos'],
            h['technicians'],
            h['Técnicos Presentes'],
            h['Tecnicos Presentes'],
          ].whereType<Object>().join(' '),
        );
        return searchable.contains(q);
      }).toList();
    }
  }

  String _normalizeSearchText(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[áàâãä]'), 'a')
        .replaceAll(RegExp(r'[éèêë]'), 'e')
        .replaceAll(RegExp(r'[íìîï]'), 'i')
        .replaceAll(RegExp(r'[óòôõö]'), 'o')
        .replaceAll(RegExp(r'[úùûü]'), 'u')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _safeReportNumber(Map<String, dynamic> h) {
    final numRel =
        h['numeroRelatorio'] ??
        h['numero_relatorio'] ??
        h['reportNumber'] ??
        h['Número do Relatório'] ??
        h['Numero do Relatorio'] ??
        '';
    final String strVal = numRel.toString().trim();
    if (strVal.isNotEmpty) return strVal;
    // fallback to ID
    final idVal = h['id'] ?? h['ID do Relatório'] ?? '';
    final String idStr = idVal.toString().trim();
    return idStr.isNotEmpty ? idStr : 'Sem número';
  }

  Map<String, List<Map<String, dynamic>>> _groupHistoryByReportNumber(
    List<Map<String, dynamic>> list,
  ) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final item in list) {
      final numRel = _safeReportNumber(item);
      if (!grouped.containsKey(numRel)) {
        grouped[numRel] = [];
      }
      grouped[numRel]!.add(item);
    }
    return grouped;
  }

  DateTime _parseSnapshotDate(Map<String, dynamic> h) {
    final snap = h['dataSnapshot'] ?? h['updatedAt'] ?? h['dataVisita'] ?? '';
    final str = snap.toString().trim();
    if (str.isEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    return DateTime.tryParse(str) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  List<String> _getSortedReportNumbers(
    Map<String, List<Map<String, dynamic>>> grouped,
  ) {
    final keys = grouped.keys.toList();
    keys.sort((a, b) {
      final listA = grouped[a]!;
      final listB = grouped[b]!;
      final dateA = listA.isNotEmpty
          ? _parseSnapshotDate(listA.first)
          : DateTime.fromMillisecondsSinceEpoch(0);
      final dateB = listB.isNotEmpty
          ? _parseSnapshotDate(listB.first)
          : DateTime.fromMillisecondsSinceEpoch(0);
      return dateB.compareTo(dateA); // most recent first
    });
    return keys;
  }

  bool _isGoogleDriveFolderUrl(String value) {
    return value.contains('drive.google.com/drive/folders');
  }

  String? _extractDriveFileId(String url) {
    final idMatch1 = RegExp(r'/d/([a-zA-Z0-9_-]+)').firstMatch(url);
    if (idMatch1 != null) return idMatch1.group(1);

    final idMatch2 = RegExp(r'[?&]id=([a-zA-Z0-9_-]+)').firstMatch(url);
    if (idMatch2 != null) return idMatch2.group(1);

    return null;
  }

  String _toDirectDriveDownloadUrl(String fileId) {
    return 'https://drive.google.com/uc?export=download&id=$fileId';
  }

  void _processPhotoList(List<dynamic> list, List<PhotoItem> photos) {
    for (var item in list) {
      if (item == null) continue;
      if (item is Map) {
        final path =
            (item['path'] ??
                    item['url'] ??
                    item['link'] ??
                    item['fileUrl'] ??
                    item['downloadUrl'] ??
                    '')
                .toString()
                .trim();
        final comment =
            (item['comment'] ??
                    item['comentario'] ??
                    item['comentários'] ??
                    item['descricao'] ??
                    item['description'] ??
                    item['legenda'] ??
                    '')
                .toString()
                .trim();
        if (path.isNotEmpty) {
          photos.add(
            PhotoItem(path: path, comment: comment.isNotEmpty ? comment : null),
          );
        }
      } else if (item is String) {
        final trimmed = item.trim();
        if (trimmed.isNotEmpty && !_isGoogleDriveFolderUrl(trimmed)) {
          photos.add(PhotoItem(path: trimmed));
        }
      }
    }
  }

  void _processPhotoJsonString(String jsonStr, List<PhotoItem> photos) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is List) {
        _processPhotoList(decoded, photos);
      } else if (decoded is Map) {
        _processPhotoList([decoded], photos);
      }
    } catch (_) {
      _processPhotoSimpleString(jsonStr, photos);
    }
  }

  void _processPhotoSimpleString(String str, List<PhotoItem> photos) {
    final trimmedStr = str.trim();
    if (trimmedStr.isEmpty) return;

    if (trimmedStr.startsWith('[') || trimmedStr.startsWith('{')) {
      _processPhotoJsonString(trimmedStr, photos);
      return;
    }

    List<String> rawParts = [];
    if (trimmedStr.contains('\n')) {
      rawParts = trimmedStr.split('\n');
    } else if (trimmedStr.contains(';')) {
      rawParts = trimmedStr.split(';');
    } else if (trimmedStr.contains(',')) {
      rawParts = trimmedStr.split(',');
    } else {
      rawParts = [trimmedStr];
    }

    for (var part in rawParts) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      if (_isGoogleDriveFolderUrl(trimmed)) continue;

      String finalPath = trimmed;
      final driveId = _extractDriveFileId(trimmed);
      if (driveId != null) {
        finalPath = _toDirectDriveDownloadUrl(driveId);
      }

      photos.add(PhotoItem(path: finalPath));
    }
  }

  List<PhotoItem> _extractPhotosFromHistory(Map<String, dynamic> h) {
    List<PhotoItem> photos = [];

    // 1. check h['fotosJson'] (from our new Apps Script update)
    final fotosJson = h['fotosJson'];
    if (fotosJson != null) {
      if (fotosJson is List) {
        _processPhotoList(fotosJson, photos);
      } else if (fotosJson is String) {
        _processPhotoJsonString(fotosJson, photos);
      }
    }

    // 2. check h['photos']
    final photosField = h['photos'];
    if (photosField != null && photos.isEmpty) {
      if (photosField is List) {
        _processPhotoList(photosField, photos);
      } else if (photosField is String) {
        _processPhotoJsonString(photosField, photos);
      }
    }

    // 3. check h['fotos']
    final fotosField = h['fotos'];
    if (fotosField != null && photos.isEmpty) {
      if (fotosField is List) {
        _processPhotoList(fotosField, photos);
      } else if (fotosField is String) {
        _processPhotoJsonString(fotosField, photos);
      }
    }

    // 4. check h['urlFotos']
    final urlFotosField = h['urlFotos'];
    if (urlFotosField != null && photos.isEmpty) {
      if (urlFotosField is List) {
        _processPhotoList(urlFotosField, photos);
      } else if (urlFotosField is String) {
        _processPhotoSimpleString(urlFotosField, photos);
      }
    }

    return photos;
  }

  ReportModel _histToReport(
    Map<String, dynamic> h, {
    bool includeImages = false,
  }) {
    DateTime visitDate = DateTime.now();
    try {
      final dataVisita = ReportModel.asString(
        h['dataVisita'] ?? h['visitDate'],
      );
      if (dataVisita.isNotEmpty) {
        visitDate = DateTime.parse(dataVisita).toLocal();
      }
    } catch (_) {}

    final motivos = ReportModel.asStringList(
      h['motivos'] ?? h['subjects'] ?? h['Motivos / Assuntos'],
    );
    final tecnicos = ReportModel.asStringList(
      h['tecnicos'] ??
          h['technicians'] ??
          h['Técnicos Presentes'] ??
          h['Tecnicos Presentes'],
    );
    final isTecnico = ReportModel.asString(
      h['tipo'] ?? h['tipo_relatorio'],
    ).toLowerCase().contains('tecnico');

    return ReportModel(
      id: ReportModel.asString(h['id'] ?? h['ID do Relatório']),
      reportNumber: _safeReportNumber(h),
      isTechnicalAnalysis: isTecnico,
      creator: ReportModel.asString(
        h['usuario'] ?? h['creator'] ?? h['usuario_logado'],
      ),
      schoolName: ReportModel.asString(h['escola'] ?? h['schoolName']),
      schoolAddress: ReportModel.asNullableString(
        h['endereco'] ?? h['schoolAddress'] ?? h['endereco_escola'],
      ),
      visitDate: visitDate,
      subjects: motivos,
      observations: ReportModel.asNullableString(
        h['observacoes'] ?? h['observations'] ?? h['Observações'],
      ),
      tiMaterials: ReportModel.parseTiMaterialsFromJson(h),
      gre: ReportModel.asNullableString(h['gre']),
      technicians: tecnicos,
      responsiblePerson: ReportModel.asNullableString(
        h['responsavel'] ??
            h['responsiblePerson'] ??
            h['Responsável da Escola'],
      ),
      photos: includeImages ? ReportModel.parsePhotosFromJson(h) : const [],
      signatureBytes: null,
      signatureUrl: ReportModel.asNullableString(
        h['urlAssinatura'] ?? h['signatureUrl'] ?? h['Link Assinatura'],
      ),
    );
  }

  bool _isExportingPdf = false;

  Future<void> _exportPdfFromHistory(
    Map<String, dynamic> h, {
    required bool includeImages,
  }) async {
    if (_isExportingPdf) return;
    setState(() => _isExportingPdf = true);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Preparando PDF...'),
          duration: Duration(seconds: 2),
        ),
      );
    }

    try {
      final report = _histToReport(h, includeImages: includeImages);

      if (includeImages && report.photos.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Este registro não possui URLs individuais de fotos para inserir no PDF. O PDF será gerado sem imagens.',
              ),
            ),
          );
        }
      }

      final failedPhotos = await PdfGenerator.generateAndPreviewPdf(
        report,
        includeImages: includeImages && report.photos.isNotEmpty,
      );

      if (mounted && includeImages && failedPhotos) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Não foi possível carregar algumas fotos. O PDF foi gerado com as imagens disponíveis.',
            ),
          ),
        );
      }
    } catch (e, stack) {
      debugPrint('Erro ao exportar PDF do histórico: $e');
      debugPrintStack(stackTrace: stack);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erro ao gerar PDF: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isExportingPdf = false);
      }
    }
  }

  void _showExportOptions(Map<String, dynamic> h) {
    final photos = _extractPhotosFromHistory(h);
    final urlFotos = h['urlFotos']?.toString() ?? '';
    final isFolderOnly = photos.isEmpty && _isGoogleDriveFolderUrl(urlFotos);
    final hasPhotos = photos.isNotEmpty;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Exportar relatório',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Escolha como deseja gerar o PDF deste registro.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (!hasPhotos && !isFolderOnly) ...[
                  const Text(
                    'Sem fotos disponíveis neste registro.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('Exportar sem fotos'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      _exportPdfFromHistory(h, includeImages: false);
                    },
                  ),
                ] else if (isFolderOnly) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Text(
                      'Este histórico possui um link de pasta de fotos, mas não contém URLs individuais das imagens. '
                      'Para inserir fotos no PDF, o histórico precisa salvar cada foto individualmente.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('Ver Fotos'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      _openUrl(urlFotos);
                    },
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('Exportar sem fotos'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      _exportPdfFromHistory(h, includeImages: false);
                    },
                  ),
                ] else ...[
                  Text(
                    '${photos.length} foto(s) disponível(is) neste registro.',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.green,
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('Exportar sem fotos'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      _exportPdfFromHistory(h, includeImages: false);
                    },
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    icon: const Icon(Icons.photo_library),
                    label: const Text('Exportar com fotos'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      _exportPdfFromHistory(h, includeImages: true);
                    },
                  ),
                ],
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancelar'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openUrl(String url) async {
    if (url.isEmpty) return;
    final uri = Uri.parse(url);
    try {
      bool launched = false;
      if (await canLaunchUrl(uri)) {
        try {
          launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {}
      }
      if (!launched) {
        await launchUrl(uri);
      }
    } catch (e) {
      debugPrint('Erro ao abrir URL: $e');
    }
  }

  // ─── Build Methods ────────────────────────────────────────────────────────

  Widget _buildSearchCard() {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Card(
          elevation: 0,
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppSearchField(
                  controller: _searchController,
                  label: 'Buscar histórico',
                  hint: 'Número, escola, técnico ou usuário',
                  onChanged: (v) => setState(() {
                    _searchQuery = v;
                    _applyFilter();
                  }),
                  onClear: () {
                    _searchController.clear();
                    setState(() {
                      _searchQuery = '';
                      _applyFilter();
                    });
                  },
                ),
                if (!_isLoading) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 14,
                        color: colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Builder(
                        builder: (context) {
                          // Quando está vendo versões de um número: conta versões filtradas
                          // Quando está na lista de grupos: conta grupos, não registros individuais
                          final String infoText;
                          if (_selectedReportNumber != null) {
                            final grouped = _groupHistoryByReportNumber(
                              _filtered,
                            );
                            final versions =
                                grouped[_selectedReportNumber] ?? [];
                            final n = versions.length;
                            infoText = _searchQuery.isNotEmpty
                                ? '$n versão${n != 1 ? 'ões' : ''} para "$_searchQuery"'
                                : '$n versão${n != 1 ? 'ões' : ''} deste relatório';
                          } else {
                            final grouped = _groupHistoryByReportNumber(
                              _filtered,
                            );
                            final n = grouped.length;
                            infoText = _searchQuery.isNotEmpty
                                ? '$n relatório${n != 1 ? 's' : ''} para "$_searchQuery"'
                                : '$n relatório${n != 1 ? 's' : ''} no histórico';
                          }
                          return Text(
                            infoText,
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: colorScheme.primary),
          const SizedBox(height: 20),
          Text(
            'Carregando histórico...',
            style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final hasQuery = _searchQuery.isNotEmpty;
    return EmptyState(
      icon: hasQuery
          ? Icons.search_off_rounded
          : Icons.history_toggle_off_rounded,
      title: hasQuery
          ? 'Nenhum resultado encontrado'
          : 'Nenhum histórico encontrado',
      message: hasQuery
          ? 'Nenhum registro corresponde a "$_searchQuery".\nTente outros termos.'
          : 'As versões editadas dos relatórios aparecerão aqui.',
      actionLabel: !hasQuery ? 'Atualizar' : null,
      onAction: !hasQuery ? _loadHistory : null,
      actionIcon: Icons.refresh_rounded,
    );
  }

  Widget _buildGroupCard(
    String reportNumber,
    List<Map<String, dynamic>> versions,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final latest = versions.first; // já ordenado: mais recente primeiro
    // Busca escola e editor da versão mais recente que tenha o campo preenchido
    final escola = versions
        .map((v) => v['escola']?.toString().trim() ?? '')
        .firstWhere((s) => s.isNotEmpty, orElse: () => 'Escola não informada');
    final editadoPor = versions
        .map((v) => (v['editadoPor'] ?? v['usuario'] ?? '').toString().trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => 'Não informado');
    final dataSnap = _fmt(latest['dataSnapshot']);

    return Card(
      elevation: 0,
      color: colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          setState(() {
            _selectedReportNumber = reportNumber;
          });
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.history_edu_rounded,
                  color: colorScheme.primary,
                  size: 22,
                ),
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
                        Text(
                          reportNumber,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: colorScheme.primary,
                          ),
                        ),
                        _buildChip(
                          versions.length == 1
                              ? '1 versão'
                              : '${versions.length} versões',
                          colorScheme.primaryContainer,
                          colorScheme.onPrimaryContainer,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Escola: $escola',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: colorScheme.onSurface,
                        height: 1.25,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 6,
                      children: [
                        _buildMetaText(
                          Icons.person_outline_rounded,
                          editadoPor,
                        ),
                        _buildMetaText(Icons.access_time_rounded, dataSnap),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetaText(IconData icon, String text) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 5),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildVersionCard(Map<String, dynamic> h, {required bool isLatest}) {
    final colorScheme = Theme.of(context).colorScheme;
    final versao = h['versao'] ?? '';
    final editadoPor = (h['editadoPor'] ?? h['usuario'] ?? '—').toString();
    final dataSnap = _fmt(h['dataSnapshot']);
    final tipo = (h['tipo'] ?? h['tipo_relatorio'] ?? '').toString();
    final dataVisita = _fmtDate(h['dataVisita']);
    final motivos = JsonUtils.asString(
      h['motivos'] ?? h['subjects'] ?? h['Motivos / Assuntos'],
    );
    final escola = JsonUtils.asString(h['escola'] ?? h['schoolName']);
    final tecnicos = JsonUtils.asString(
      h['tecnicos'] ??
          h['technicians'] ??
          h['Técnicos Presentes'] ??
          h['Tecnicos Presentes'],
    );

    return Card(
      elevation: 0,
      color: isLatest
          ? colorScheme.primaryContainer.withValues(alpha: 0.12)
          : colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isLatest
              ? colorScheme.primary.withValues(alpha: 0.32)
              : colorScheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _showDetail(h),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          versao.toString().isNotEmpty
                              ? 'Versão v${versao.toString().replaceFirst(RegExp(r'^v', caseSensitive: false), '')}'
                              : 'Versão não especificada',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: colorScheme.primary,
                          ),
                        ),
                        if (isLatest)
                          _buildChip(
                            'Mais recente',
                            Colors.green.withValues(alpha: 0.14),
                            Colors.green.shade700,
                          ),
                        if (tipo.isNotEmpty)
                          _buildChip(
                            tipo,
                            tipo.toLowerCase().contains('tecnico') ||
                                    tipo.toLowerCase().contains('técnico')
                                ? colorScheme.secondaryContainer
                                : colorScheme.tertiaryContainer,
                            tipo.toLowerCase().contains('tecnico') ||
                                    tipo.toLowerCase().contains('técnico')
                                ? colorScheme.onSecondaryContainer
                                : colorScheme.onTertiaryContainer,
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Ver detalhes',
                    onPressed: () => _showDetail(h),
                    icon: const Icon(Icons.open_in_new_rounded),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (escola.isNotEmpty)
                _buildInlineInfo(
                  Icons.school_outlined,
                  escola,
                  highlight: true,
                ),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  _buildMetaText(Icons.event_rounded, 'Visita: $dataVisita'),
                  _buildMetaText(
                    Icons.access_time_rounded,
                    'Alterado: $dataSnap',
                  ),
                  _buildMetaText(Icons.edit_outlined, 'Por: $editadoPor'),
                ],
              ),
              if (tecnicos.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildInlineInfo(Icons.engineering_outlined, tecnicos),
              ],
              if (motivos.isNotEmpty) ...[
                const SizedBox(height: 8),
                _buildInlineInfo(Icons.list_alt_rounded, motivos),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInlineInfo(
    IconData icon,
    String text, {
    bool highlight = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 15,
            color: highlight
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: highlight ? 13 : 12,
                color: highlight
                    ? colorScheme.onSurface
                    : colorScheme.onSurfaceVariant,
                fontWeight: highlight ? FontWeight.w700 : FontWeight.normal,
                height: 1.25,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChip(String label, Color bg, Color fg) {
    return InfoChip(label: label, backgroundColor: bg, color: fg);
  }

  Widget _buildHistoryList() {
    final grouped = _groupHistoryByReportNumber(_filtered);

    grouped.forEach((key, list) {
      list.sort((a, b) {
        final dateA = _parseSnapshotDate(a);
        final dateB = _parseSnapshotDate(b);
        return dateB.compareTo(dateA);
      });
    });

    if (_selectedReportNumber != null) {
      final versions = grouped[_selectedReportNumber] ?? [];
      if (versions.isEmpty) {
        // A busca filtrou todas as versões deste relatório
        return EmptyState(
          icon: Icons.search_off_rounded,
          title: 'Nenhuma versão encontrada',
          message:
              'Nenhuma versão de "$_selectedReportNumber" corresponde a "$_searchQuery".\nLimpe a busca para ver todas as versões.',
          actionLabel: 'Limpar busca',
          onAction: () {
            _searchController.clear();
            setState(() {
              _searchQuery = '';
              _applyFilter();
            });
          },
          actionIcon: Icons.clear_rounded,
        );
      }
      return RefreshIndicator(
        onRefresh: _loadHistory,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              itemCount: versions.length,
              itemBuilder: (ctx, i) =>
                  _buildVersionCard(versions[i], isLatest: i == 0),
            ),
          ),
        ),
      );
    }

    final sortedKeys = _getSortedReportNumbers(grouped);

    return RefreshIndicator(
      onRefresh: _loadHistory,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            itemCount: sortedKeys.length,
            itemBuilder: (ctx, i) {
              final key = sortedKeys[i];
              return _buildGroupCard(key, grouped[key]!);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(
    IconData icon,
    String label,
    String? value, {
    bool highlight = false,
  }) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    color: highlight
                        ? colorScheme.primary
                        : colorScheme.onSurface,
                    fontWeight: highlight ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailSection(String title, IconData icon, Widget child) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: colorScheme.primary,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.35,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            child: child,
          ),
        ],
      ),
    );
  }

  void _showDetail(Map<String, dynamic> h) {
    final colorScheme = Theme.of(context).colorScheme;
    final versao = h['versao'] ?? '';
    final numRel = _safeReportNumber(h);
    final escola = JsonUtils.asNullableString(h['escola']) ?? '—';
    final hasSignature = JsonUtils.asString(
      h['urlAssinatura'] ?? h['signatureUrl'] ?? h['Link Assinatura'],
    ).isNotEmpty;
    final hasPhotos = JsonUtils.asString(
      h['urlFotos'] ?? h['photos'] ?? h['url_fotos'] ?? h['Link Foto'],
    ).isNotEmpty;
    final hasObservations = JsonUtils.asString(
      h['observacoes'] ?? h['observations'] ?? h['Observações'],
    ).isNotEmpty;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.78,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (_, controller) => SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Header
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.history_edu_rounded,
                      color: colorScheme.onPrimaryContainer,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              numRel,
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(width: 10),
                            _buildChip(
                              versao.isNotEmpty
                                  ? 'v${versao.replaceFirst(RegExp(r'^v', caseSensitive: false), '')}'
                                  : 'v?',
                              colorScheme.primaryContainer,
                              colorScheme.onPrimaryContainer,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          escola,
                          style: TextStyle(
                            fontSize: 14,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.schedule_rounded,
                    size: 13,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    'Snapshot: ${_fmt(JsonUtils.asNullableString(h['dataSnapshot'] ?? h['updatedAt'] ?? h['dataVisita']))}',
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),

              Divider(
                height: 32,
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),

              // Section: Escola
              _buildDetailSection(
                'Dados da Escola',
                Icons.school_outlined,
                Column(
                  children: [
                    _buildDetailRow(
                      Icons.school_rounded,
                      'Escola',
                      JsonUtils.asNullableString(h['escola']),
                    ),
                    _buildDetailRow(
                      Icons.map_outlined,
                      'Regional (GRE)',
                      JsonUtils.asNullableString(h['gre']),
                    ),
                    _buildDetailRow(
                      Icons.location_on_outlined,
                      'Endereço',
                      JsonUtils.asNullableString(h['endereco']),
                    ),
                  ],
                ),
              ),

              // Section: Visita
              _buildDetailSection(
                'Dados da Visita',
                Icons.event_note_outlined,
                Column(
                  children: [
                    _buildDetailRow(
                      Icons.calendar_today_rounded,
                      'Data da Visita',
                      _fmtDate(JsonUtils.asNullableString(h['dataVisita'])),
                    ),
                    _buildDetailRow(
                      Icons.category_outlined,
                      'Tipo',
                      JsonUtils.asNullableString(h['tipo']),
                    ),
                    _buildDetailRow(
                      Icons.list_alt_rounded,
                      'Motivos',
                      JsonUtils.asNullableString(h['motivos']),
                    ),
                    _buildDetailRow(
                      Icons.engineering_outlined,
                      'Técnicos',
                      JsonUtils.asNullableString(h['tecnicos']),
                    ),
                    _buildDetailRow(
                      Icons.person_outline,
                      'Responsável',
                      JsonUtils.asNullableString(h['responsavel']),
                    ),
                  ],
                ),
              ),

              // Section: Alteração
              _buildDetailSection(
                'Registro de Alteração',
                Icons.edit_note_rounded,
                Column(
                  children: [
                    _buildDetailRow(
                      Icons.person_rounded,
                      'Usuário Criador',
                      JsonUtils.asNullableString(h['usuario']),
                      highlight: true,
                    ),
                    _buildDetailRow(
                      Icons.edit_rounded,
                      'Editado Por',
                      JsonUtils.asNullableString(h['editadoPor']),
                      highlight: true,
                    ),
                  ],
                ),
              ),

              // Section: Observações
              if (hasObservations)
                _buildDetailSection(
                  'Observações / Diagnóstico',
                  Icons.notes_rounded,
                  Text(
                    JsonUtils.asString(
                      h['observacoes'] ?? h['observations'] ?? h['Observações'],
                    ),
                    style: TextStyle(
                      fontSize: 14,
                      color: colorScheme.onSurface,
                      height: 1.5,
                    ),
                  ),
                ),

              // Section: Ações
              _buildDetailSection(
                'Anexos e Exportação',
                Icons.attach_file_rounded,
                Column(
                  children: [
                    if (hasSignature) ...[
                      _buildActionButton(
                        label: 'Ver Assinatura',
                        icon: Icons.draw_outlined,
                        onTap: () => _openUrl(
                          JsonUtils.asString(
                            h['urlAssinatura'] ??
                                h['signatureUrl'] ??
                                h['Link Assinatura'],
                          ),
                        ),
                        outlined: true,
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (hasPhotos) ...[
                      _buildActionButton(
                        label: 'Ver Fotos',
                        icon: Icons.photo_library_outlined,
                        onTap: () => _openUrl(
                          JsonUtils.asString(
                            h['urlFotos'] ??
                                h['photos'] ??
                                h['url_fotos'] ??
                                h['Link Foto'],
                          ),
                        ),
                        outlined: true,
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (!hasSignature && !hasPhotos)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Icon(
                              Icons.image_not_supported_outlined,
                              size: 14,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Nenhum anexo disponível',
                              style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    _buildActionButton(
                      label: 'Imprimir / Exportar PDF',
                      icon: Icons.picture_as_pdf_rounded,
                      onTap: _isExportingPdf
                          ? () {}
                          : () => _showExportOptions(h),
                      outlined: false,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    required bool outlined,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    if (outlined) {
      return OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    }
    return FilledButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: colorScheme.errorContainer,
        foregroundColor: colorScheme.onErrorContainer,
        minimumSize: const Size(double.infinity, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: _selectedReportNumber == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          setState(() {
            _selectedReportNumber = null;
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: _selectedReportNumber != null
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    setState(() {
                      _selectedReportNumber = null;
                    });
                  },
                )
              : null,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _selectedReportNumber != null
                    ? 'Versões do Relatório'
                    : 'Histórico de Alterações',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                _selectedReportNumber != null
                    ? 'Exibindo snapshots de $_selectedReportNumber'
                    : 'Auditoria de modificações e exclusões',
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _loadHistory,
              tooltip: 'Atualizar histórico',
            ),
          ],
        ),
        body: Column(
          children: [
            _buildSearchCard(),
            Expanded(
              child: _isLoading
                  ? _buildLoadingState()
                  : _filtered.isEmpty
                  ? _buildEmptyState()
                  : _buildHistoryList(),
            ),
          ],
        ),
      ),
    );
  }
}
