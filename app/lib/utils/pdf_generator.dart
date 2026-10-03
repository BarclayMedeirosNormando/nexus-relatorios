import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/report_model.dart';
import '../services/employee_service.dart';
import '../services/technician_service.dart';

class PdfGenerator {
  static const _brandBlue = PdfColor.fromInt(0xff003A5D);
  static const _labelFill = PdfColor.fromInt(0xffE8F1F8);
  static const _borderColor = PdfColor.fromInt(0xffB8C7D3);

  static String _s(String value) => value.trim();
  static String _valueOrDefault(String? value) {
    final clean = _s(value ?? '');
    return clean.isEmpty ? 'Não informado' : clean;
  }

  static String _joinOrDefault(Iterable<String> values) {
    final cleanValues = values
        .map((value) => value.trim().replaceAll(RegExp(r'^,\s*'), ''))
        .where((value) => value.isNotEmpty)
        .toList();
    return cleanValues.isEmpty ? 'Não informado' : _s(cleanValues.join(', '));
  }

  static Future<bool> generateAndPreviewPdf(
    ReportModel report, {
    bool includeImages = true,
  }) async {
    final result = await _buildPdf(report, includeImages: includeImages);

    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => result.bytes,
      name: 'Relatorio_${_s(report.schoolName).replaceAll(' ', '_')}.pdf',
    );

    return result.requestedPhotosMissing;
  }

  @visibleForTesting
  static Future<Uint8List> buildPdfBytesForTesting(
    ReportModel report, {
    bool includeImages = true,
  }) async {
    final result = await _buildPdf(report, includeImages: includeImages);
    return result.bytes;
  }

  static Future<_PdfBuildResult> _buildPdf(
    ReportModel report, {
    bool includeImages = true,
  }) async {
    final regularFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'),
    );
    final boldFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'),
    );
    final pdf = pw.Document(
      theme: pw.ThemeData.withFont(base: regularFont, bold: boldFont),
    );

    if (kDebugMode) {
      debugPrint('Gerando PDF relatorio: ${report.id}');
      debugPrint('Fotos no report: ${report.photos.length}');
      debugPrint('Assinatura bytes: ${report.signatureBytes != null}');
      debugPrint('Assinatura URL: ${report.signatureUrl}');
      debugPrint('includeImages: $includeImages');
    }

    Uint8List? brasaoBytes;
    try {
      final byteData = await rootBundle.load('assets/images/brasao_pb.png');
      brasaoBytes = byteData.buffer.asUint8List();
    } catch (e) {
      debugPrint('Nao foi possivel carregar brasao: $e');
    }

    final pdfPhotos = <MapEntry<pw.MemoryImage, String?>>[];
    if (includeImages && report.photos.isNotEmpty) {
      for (final photo in report.photos) {
        try {
          final bytes = await _loadImageBytes(photo.path);
          if (bytes != null && bytes.isNotEmpty) {
            pdfPhotos.add(MapEntry(pw.MemoryImage(bytes), photo.comment));
          }
        } catch (e) {
          debugPrint('Falha ao carregar foto para PDF (${photo.path}): $e');
        }
      }
    }

    final signatureBytesList = await _resolveSignatureBytesList(report);

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(horizontal: 32, vertical: 32),
        build: (pw.Context context) => [
          _buildInstitutionalHeader(report, brasaoBytes),
          pw.SizedBox(height: 20),
          _buildReportTitle(),
          pw.SizedBox(height: 20),
          _buildReportDetails(report),
          if (report.observations != null &&
              report.observations!.trim().isNotEmpty) ...[
            pw.SizedBox(height: 20),
            ..._buildObservations(report),
          ],
          if (report.isTechnicalAnalysis && report.tiMaterials.isNotEmpty) ...[
            pw.SizedBox(height: 20),
            ..._buildTiMaterials(report),
          ],
          pw.SizedBox(height: 48),
          _buildSignatureSection(report, signatureBytesList),
        ],
      ),
    );

    if (pdfPhotos.isNotEmpty) {
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.symmetric(horizontal: 32, vertical: 32),
          build: (pw.Context context) => [
            _sectionTitle('3. ANEXOS - FOTOS DA VISITA'),
            pw.SizedBox(height: 6),
            ...pdfPhotos.map(
              (entry) => pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Container(
                    width: 240,
                    child: pw.Image(entry.key, fit: pw.BoxFit.contain),
                  ),
                  if (entry.value != null &&
                      entry.value!.trim().isNotEmpty) ...[
                    pw.SizedBox(height: 6),
                    pw.Text(
                      'Comentário: ${_s(entry.value!)}',
                      style: const pw.TextStyle(fontSize: 11),
                    ),
                  ],
                  pw.SizedBox(height: 16),
                  pw.Divider(color: PdfColors.grey300),
                  pw.SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return _PdfBuildResult(
      bytes: await pdf.save(),
      requestedPhotosMissing:
          includeImages && report.photos.isNotEmpty && pdfPhotos.isEmpty,
    );
  }

  static Future<Uint8List?> _loadImageBytes(String source) async {
    try {
      final trimmed = source.trim();
      if (trimmed.isEmpty) return null;

      if (trimmed.startsWith('data:image') ||
          (RegExp(r'^[a-zA-Z0-9+/=]+$').hasMatch(trimmed) &&
              trimmed.length > 100)) {
        try {
          final cleanBase64 = trimmed.contains(',')
              ? trimmed.split(',').last
              : trimmed;
          return base64Decode(cleanBase64.trim());
        } catch (e) {
          debugPrint('Imagem base64 invalida: $e');
        }
      }

      if (trimmed.startsWith('http://') ||
          trimmed.startsWith('https://') ||
          trimmed.contains('drive.google.com')) {
        final driveId = _extractDriveFileId(trimmed);
        final urls = <String>[
          if (driveId != null)
            'https://drive.google.com/uc?export=download&id=$driveId',
          trimmed,
          if (driveId != null)
            'https://drive.google.com/thumbnail?id=$driveId&sz=w1000',
        ];

        for (final url in urls.toSet()) {
          try {
            final response = await http
                .get(Uri.parse(url))
                .timeout(const Duration(seconds: 20));
            final contentType = response.headers['content-type'] ?? '';
            if (response.statusCode == 200 &&
                response.bodyBytes.isNotEmpty &&
                !contentType.toLowerCase().contains('text/html')) {
              return response.bodyBytes;
            }
          } catch (e) {
            debugPrint('Falha ao baixar imagem $url: $e');
          }
        }
        return null;
      }

      if (!kIsWeb) {
        try {
          final file = io.File(trimmed);
          if (await file.exists()) {
            return await file.readAsBytes();
          }
        } catch (e) {
          debugPrint('Falha ao ler arquivo de imagem $trimmed: $e');
        }
      }

      try {
        return await XFile(trimmed).readAsBytes();
      } catch (e) {
        debugPrint('Falha ao ler XFile $trimmed: $e');
      }
    } catch (e) {
      debugPrint('Erro ao carregar imagem ($source): $e');
    }
    return null;
  }

  static Future<List<Uint8List>?> _resolveSignatureBytesList(ReportModel report) async {
    if (report.signatureBytesList != null && report.signatureBytesList!.isNotEmpty) {
      return report.signatureBytesList;
    }

    if (report.signatureBytes != null && report.signatureBytes!.isNotEmpty) {
      return [report.signatureBytes!];
    }

    final bytes = <Uint8List>[];
    if (report.signatureUrlList != null && report.signatureUrlList!.isNotEmpty) {
      for (final url in report.signatureUrlList!) {
        if (url.trim().isEmpty) continue;
        final loaded = await _loadImageBytes(url);
        if (loaded != null && loaded.isNotEmpty) {
          bytes.add(loaded);
        }
      }
      if (bytes.isNotEmpty) return bytes;
    }

    if (report.signatureUrl != null && report.signatureUrl!.trim().isNotEmpty) {
      final loaded = await _loadImageBytes(report.signatureUrl!);
      if (loaded != null && loaded.isNotEmpty) {
        return [loaded];
      }
    }

    return null;
  }

  static String? _extractDriveFileId(String url) {
    final fileMatch =
        RegExp(r'/file/d/([a-zA-Z0-9_-]+)').firstMatch(url) ??
        RegExp(r'/d/([a-zA-Z0-9_-]+)').firstMatch(url);
    if (fileMatch != null) return fileMatch.group(1);

    final idMatch = RegExp(r'[?&]id=([a-zA-Z0-9_-]+)').firstMatch(url);
    return idMatch?.group(1);
  }

  static pw.Widget _buildInstitutionalHeader(
    ReportModel report,
    Uint8List? brasaoBytes,
  ) {
    final reportNumber = _s(report.reportNumber).isEmpty
        ? 'sem número'
        : _s(report.reportNumber);

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Expanded(flex: 4, child: _buildBrandBlock(brasaoBytes)),
            pw.SizedBox(width: 18),
            pw.Container(width: 1.1, height: 76, color: PdfColors.black),
            pw.SizedBox(width: 18),
            pw.Expanded(
              flex: 7,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                mainAxisAlignment: pw.MainAxisAlignment.center,
                children: [
                  pw.Text(
                    'SECRETARIA DE ESTADO DA EDUCAÇÃO DA PARAÍBA',
                    style: pw.TextStyle(
                      fontSize: 12,
                      fontWeight: pw.FontWeight.bold,
                      color: _brandBlue,
                    ),
                  ),
                  pw.SizedBox(height: 3),
                  pw.Text(
                    'GTECI - Gerência de Tecnologia da Informação',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    'Relatório de Visita Técnica',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                  pw.SizedBox(height: 4),
                  pw.RichText(
                    text: pw.TextSpan(
                      children: [
                        pw.TextSpan(
                          text: 'Nº: ',
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontWeight: pw.FontWeight.bold,
                            color: _brandBlue,
                          ),
                        ),
                        pw.TextSpan(
                          text: reportNumber,
                          style: pw.TextStyle(
                            fontSize: 10,
                            fontWeight: pw.FontWeight.bold,
                            color: _brandBlue,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 14),
        pw.Container(height: 0.8, color: PdfColors.black),
      ],
    );
  }

  static pw.Widget _buildBrandBlock(Uint8List? brasaoBytes) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.center,
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        if (brasaoBytes != null)
          pw.Container(
            width: 42,
            height: 42,
            child: pw.Image(
              pw.MemoryImage(brasaoBytes),
              fit: pw.BoxFit.contain,
            ),
          )
        else
          pw.Container(
            width: 42,
            height: 42,
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
            ),
          ),
        pw.SizedBox(width: 8),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'GOVERNO',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              'DA PARAÍBA',
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            pw.Text(
              'SECRETARIA',
              style: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
                color: _brandBlue,
              ),
            ),
            pw.Text(
              'DA EDUCAÇÃO',
              style: pw.TextStyle(
                fontSize: 8,
                fontWeight: pw.FontWeight.bold,
                color: _brandBlue,
              ),
            ),
          ],
        ),
      ],
    );
  }

  static pw.Widget _buildReportTitle() {
    return pw.Center(
      child: pw.Text(
        'RELATÓRIO DE VISITA TÉCNICA',
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          fontSize: 17,
          fontWeight: pw.FontWeight.bold,
          color: _brandBlue,
        ),
      ),
    );
  }

  static pw.TextStyle _sectionTitleStyle() {
    return pw.TextStyle(
      fontSize: 13,
      fontWeight: pw.FontWeight.bold,
      color: _brandBlue,
    );
  }

  static pw.Widget _sectionTitle(String text) {
    return pw.Text(text, style: _sectionTitleStyle());
  }

  static pw.Widget _buildReportDetails(ReportModel report) {
    final visitDate = DateFormat('dd/MM/yyyy').format(report.visitDate);

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        _sectionTitle('1. IDENTIFICAÇÃO DA VISITA'),
        pw.SizedBox(height: 6),
        pw.Column(
          children: [
            _fullInfoTable(
              'Escola',
              _valueOrDefault(report.schoolName),
              boldValue: true,
            ),
            _doubleInfoTable(
              'GRE',
              _valueOrDefault(report.gre),
              'Município',
              _valueOrDefault(report.schoolCity),
            ),
            _doubleInfoTable(
              'INEP',
              _valueOrDefault(report.schoolInep),
              'Data do Atendimento',
              visitDate,
            ),
            _fullInfoTable(
              'Motivo do Chamado',
              _joinOrDefault(report.subjects),
              boldValue: true,
            ),
            _fullInfoTable(
              'Técnicos Presentes',
              _joinOrDefault(report.technicians),
              boldValue: true,
            ),
            if (!report.isTechnicalAnalysis)
              _fullInfoTable(
                'Responsável pela escola',
                _valueOrDefault(report.responsiblePerson),
                boldValue: true,
              ),
          ],
        ),
      ],
    );
  }

  static pw.Widget _fullInfoTable(
    String label,
    String value, {
    bool boldValue = false,
  }) {
    return pw.Table(
      border: pw.TableBorder.all(color: _borderColor, width: 0.5),
      columnWidths: const {
        0: pw.FlexColumnWidth(1.45),
        1: pw.FlexColumnWidth(5.15),
      },
      children: [
        pw.TableRow(
          children: [
            _labelCell(label),
            _valueCell(value, bold: boldValue),
          ],
        ),
      ],
    );
  }

  static pw.Widget _doubleInfoTable(
    String firstLabel,
    String firstValue,
    String secondLabel,
    String secondValue,
  ) {
    return pw.Table(
      border: pw.TableBorder.all(color: _borderColor, width: 0.5),
      columnWidths: const {
        0: pw.FlexColumnWidth(1.45),
        1: pw.FlexColumnWidth(2.15),
        2: pw.FlexColumnWidth(1.25),
        3: pw.FlexColumnWidth(1.75),
      },
      children: [
        pw.TableRow(
          children: [
            _labelCell(firstLabel),
            _valueCell(firstValue, bold: true),
            _labelCell(secondLabel),
            _valueCell(secondValue, bold: true),
          ],
        ),
      ],
    );
  }

  static pw.Widget _labelCell(String label) {
    return pw.Container(
      color: _labelFill,
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: pw.Text(
        label,
        style: pw.TextStyle(
          fontSize: 9.5,
          fontWeight: pw.FontWeight.bold,
          color: _brandBlue,
        ),
      ),
    );
  }

  static pw.Widget _valueCell(String value, {bool bold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: pw.Text(
        value,
        softWrap: true,
        style: pw.TextStyle(
          fontSize: 9.5,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );
  }

  static List<pw.Widget> _buildObservations(ReportModel report) {
    var obs = report.observations ?? '';
    obs = obs.replaceAllMapped(RegExp(r'\S{40,}'), (match) {
      final word = match.group(0)!;
      return word.replaceAllMapped(RegExp(r'.{40}'), (m) => '${m.group(0)} ');
    });

    return [
      _sectionTitle('2. OBSERVAÇÕES / DIAGNÓSTICO TÉCNICO'),
      pw.SizedBox(height: 6),
      pw.Paragraph(
        text: _s(obs),
        style: const pw.TextStyle(fontSize: 11),
        textAlign: pw.TextAlign.left,
      ),
    ];
  }

  static List<pw.Widget> _buildTiMaterials(ReportModel report) {
    final grouped = <String, List<TiMaterialItem>>{};
    for (final item in report.tiMaterials) {
      grouped.putIfAbsent(item.ambiente, () => []).add(item);
    }

    return [
      _sectionTitle('Materiais de TI necessários'),
      pw.SizedBox(height: 8),
      ...grouped.entries.expand(
        (entry) => [
          pw.Text(
            _s(entry.key),
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          pw.Table(
            border: pw.TableBorder.all(color: _borderColor, width: 0.5),
            columnWidths: const {
              0: pw.FlexColumnWidth(2),
              1: pw.FlexColumnWidth(2),
              2: pw.FlexColumnWidth(1.2),
              3: pw.FlexColumnWidth(2.2),
            },
            children: [
              pw.TableRow(
                children: [
                  _labelCell('Equipamento/Material'),
                  _labelCell('Marca/Modelo'),
                  _labelCell('Quantidade'),
                  _labelCell('Observação'),
                ],
              ),
              ...entry.value.map(
                (item) => pw.TableRow(
                  children: [
                    _valueCell(_valueOrDefault(item.equipamento)),
                    _valueCell(_valueOrDefault(item.marcaModelo)),
                    _valueCell(_valueOrDefault(item.quantidade)),
                    _valueCell(_valueOrDefault(item.observacao)),
                  ],
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 10),
        ],
      ),
    ];
  }

  static pw.Widget _buildSignatureSection(
    ReportModel report,
    List<Uint8List>? signatureBytesList,
  ) {
    if (signatureBytesList != null && signatureBytesList.isNotEmpty) {
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < signatureBytesList.length; index++) ...[
            pw.Center(
              child: pw.Container(
                width: 140,
                height: 50,
                constraints: const pw.BoxConstraints(maxWidth: 140),
                child: pw.Image(
                  pw.MemoryImage(signatureBytesList[index]),
                  fit: pw.BoxFit.contain,
                ),
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Center(
              child: pw.Text(
                _signatureLabelForIndex(report, index),
                style: const pw.TextStyle(fontSize: 9),
              ),
            ),
            if (index < signatureBytesList.length - 1) ...[
              pw.SizedBox(height: 12),
              pw.Container(width: double.infinity, height: 0.6, color: PdfColors.grey300),
              pw.SizedBox(height: 12),
            ],
          ],
        ],
      );
    }

    final label = _signatureLabel(report);
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.SizedBox(height: 50),
        pw.Container(width: 260, height: 1, color: PdfColors.black),
        pw.SizedBox(height: 6),
        pw.Text(label, style: const pw.TextStyle(fontSize: 11)),
      ],
    );
  }

  static String _signatureLabel(ReportModel report) {
    if (report.isTechnicalAnalysis) {
      var nome = '';
      var matricula = '';
      if (report.technicians.isNotEmpty) {
        nome = report.technicians.first.trim().replaceAll(RegExp(r'^,\s*'), '');
        try {
          final tech = TechnicianService().technicians.firstWhere(
            (t) => t.name == nome,
          );
          matricula = tech.registration;
        } catch (_) {}
      }
      if (matricula.isNotEmpty) return '$nome - Matrícula: $matricula';
      return nome.isNotEmpty ? nome : 'Assinatura do Técnico Responsável';
    }

    final nome = report.responsiblePerson ?? '';
    var matricula = '';
    if (nome.isNotEmpty) {
      try {
        final emp = EmployeeService().all.firstWhere((e) => e.name == nome);
        matricula = emp.matricula;
      } catch (_) {}
    }
    if (matricula.isNotEmpty) return '$nome - Matrícula: $matricula';
    return nome.isNotEmpty ? nome : 'Assinatura do Responsável da Escola';
  }

  static String _signatureLabelForIndex(ReportModel report, int index) {
    if (report.isTechnicalAnalysis) {
      final nome = index < report.technicians.length
          ? report.technicians[index].trim().replaceAll(RegExp(r'^,\s*'), '')
          : '';
      if (nome.isNotEmpty) {
        var matricula = '';
        try {
          final tech = TechnicianService().technicians.firstWhere(
            (t) => t.name == nome,
          );
          matricula = tech.registration;
        } catch (_) {}
        return matricula.isNotEmpty
            ? '$nome - Matrícula: $matricula'
            : nome;
      }
      return 'Assinatura do Técnico ${index + 1}';
    }

    final nome = report.responsiblePerson ?? '';
    if (nome.isNotEmpty) {
      var matricula = '';
      try {
        final emp = EmployeeService().all.firstWhere((e) => e.name == nome);
        matricula = emp.matricula;
      } catch (_) {}
      return matricula.isNotEmpty ? '$nome - Matrícula: $matricula' : nome;
    }
    return 'Assinatura do Responsável da Escola';
  }
}

class _PdfBuildResult {
  final Uint8List bytes;
  final bool requestedPhotosMissing;

  const _PdfBuildResult({
    required this.bytes,
    required this.requestedPhotosMissing,
  });
}
