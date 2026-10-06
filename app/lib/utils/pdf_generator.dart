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
import '../services/google_sheets_service.dart';
import '../services/technician_service.dart';
import 'rich_markup.dart';

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
    final italicFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-Italic.ttf'),
    );
    final boldItalicFont = pw.Font.ttf(
      await rootBundle.load('assets/fonts/NotoSans-BoldItalic.ttf'),
    );
    final pdf = pw.Document(
      theme: pw.ThemeData.withFont(
        base: regularFont,
        bold: boldFont,
        italic: italicFont,
        boldItalic: boldItalicFont,
      ),
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

    // "Cauda" = ultimo trecho do conteudo (ultima linha da tabela ou ultimo
    // paragrafo) que viaja junto com as assinaturas, para elas nunca ficarem
    // sozinhas em uma pagina.
    final tail = <pw.Widget>[];
    final hasObs =
        report.observations != null && report.observations!.trim().isNotEmpty;
    final hasMaterials =
        report.isTechnicalAnalysis && report.tiMaterials.isNotEmpty;
    final obsWidgets = hasObs
        ? _buildObservations(report, tail: hasMaterials ? null : tail)
        : <pw.Widget>[];
    final materialWidgets =
        hasMaterials ? _buildTiMaterials(report, tail: tail) : <pw.Widget>[];

    final signatureSection = _buildSignatureSection(report, signatureBytesList);
    // Com muitas assinaturas o bloco nao cabe inteiro em uma pagina: nesse caso
    // mantem o fluxo normal (pode quebrar).
    final keepTogether = (signatureBytesList?.length ?? 0) <= 6;
    final signatureBlock = <pw.Widget>[
      ...tail,
      pw.SizedBox(height: 48),
      signatureSection,
    ];

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
          if (hasObs) ...[
            pw.SizedBox(height: 20),
            ...obsWidgets,
          ],
          if (hasMaterials) ...[
            pw.SizedBox(height: 20),
            ...materialWidgets,
          ],
          if (keepTogether)
            // Container nao quebra entre paginas: ou o bloco inteiro cabe, ou
            // vai todo para a proxima pagina junto com o ultimo trecho.
            pw.Container(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: signatureBlock,
              ),
            )
          else
            ...signatureBlock,
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
            for (var i = 0; i < pdfPhotos.length; i += 2) ...[
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(child: _buildPhotoCell(pdfPhotos[i])),
                  pw.SizedBox(width: 16),
                  pw.Expanded(
                    child: i + 1 < pdfPhotos.length
                        ? _buildPhotoCell(pdfPhotos[i + 1])
                        : pw.SizedBox(),
                  ),
                ],
              ),
              pw.SizedBox(height: 12),
            ],
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

        // No navegador o Drive bloqueia o download direto (CORS): usa o
        // Apps Script como ponte.
        if (kIsWeb && driveId != null) {
          final viaScript =
              await GoogleSheetsService().fetchDriveFileBytes(trimmed);
          if (viaScript != null && viaScript.isNotEmpty) return viaScript;
        }
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

  static List<pw.Widget> _buildObservations(
    ReportModel report, {
    List<pw.Widget>? tail,
  }) {
    var obs = report.observations ?? '';
    obs = obs.replaceAllMapped(RegExp(r'\S{40,}'), (match) {
      final word = match.group(0)!;
      return word.replaceAllMapped(RegExp(r'.{40}'), (m) => '${m.group(0)} ');
    });
    obs = _s(obs);

    const baseStyle = pw.TextStyle(fontSize: 11);

    // Mesma regra de formatacao da tela: **negrito**, _italico_, ++sublinhado++,
    // "- " marcadores e "1. " lista numerada.
    pw.Widget lineWidget(RichLine line) {
      if (line.kind == RichLineKind.blank) return pw.SizedBox(height: 8);

      final rich = pw.RichText(
        textAlign: pw.TextAlign.left,
        text: pw.TextSpan(
          style: baseStyle,
          children: [
            for (final s in line.spans)
              pw.TextSpan(
                text: s.text,
                style: pw.TextStyle(
                  fontWeight: s.bold ? pw.FontWeight.bold : pw.FontWeight.normal,
                  fontStyle: s.italic ? pw.FontStyle.italic : pw.FontStyle.normal,
                  decoration: s.underline ? pw.TextDecoration.underline : null,
                ),
              ),
          ],
        ),
      );

      if (line.kind == RichLineKind.normal) {
        return pw.Padding(padding: const pw.EdgeInsets.only(bottom: 2), child: rich);
      }
      return pw.Padding(
        padding: const pw.EdgeInsets.only(left: 6, bottom: 2),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.SizedBox(
              width: line.kind == RichLineKind.bullet ? 14 : 20,
              child: pw.Text(line.label, style: baseStyle),
            ),
            pw.Expanded(child: rich),
          ],
        ),
      );
    }

    final lines = RichMarkup.lines(obs);
    // Se der, a ultima linha (curta) vai junto com a assinatura.
    if (tail != null && lines.length > 1) {
      var lastIdx = lines.length - 1;
      while (lastIdx > 0 && lines[lastIdx].kind == RichLineKind.blank) {
        lastIdx--;
      }
      final last = lines[lastIdx];
      if (lastIdx > 0 &&
          last.kind != RichLineKind.blank &&
          last.plainText.length <= 500) {
        tail.add(lineWidget(last));
        lines.removeRange(lastIdx, lines.length);
      }
    }

    return [
      _sectionTitle('2. OBSERVAÇÕES / DIAGNÓSTICO TÉCNICO'),
      pw.SizedBox(height: 6),
      for (final line in lines) lineWidget(line),
    ];
  }

  static List<pw.Widget> _buildTiMaterials(
    ReportModel report, {
    List<pw.Widget>? tail,
  }) {
    final grouped = <String, List<TiMaterialItem>>{};
    for (final item in report.tiMaterials) {
      grouped.putIfAbsent(item.ambiente, () => []).add(item);
    }

    const Map<int, pw.TableColumnWidth> widths = {
      0: pw.FlexColumnWidth(2),
      1: pw.FlexColumnWidth(2),
      2: pw.FlexColumnWidth(1.2),
      3: pw.FlexColumnWidth(2.2),
    };

    pw.TableRow headerRow() => pw.TableRow(
      children: [
        _labelCell('Equipamento/Material'),
        _labelCell('Marca/Modelo'),
        _labelCell('Quantidade'),
        _labelCell('Observação'),
      ],
    );

    pw.TableRow itemRow(TiMaterialItem item) => pw.TableRow(
      children: [
        _valueCell(_valueOrDefault(item.equipamento)),
        _valueCell(_valueOrDefault(item.marcaModelo)),
        _valueCell(_valueOrDefault(item.quantidade)),
        _valueCell(_valueOrDefault(item.observacao)),
      ],
    );

    pw.Widget table(List<pw.TableRow> rows) => pw.Table(
      border: pw.TableBorder.all(color: _borderColor, width: 0.5),
      columnWidths: widths,
      children: rows,
    );

    pw.Widget groupTitle(String name) => pw.Text(
      _s(name),
      style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
    );

    final result = <pw.Widget>[
      _sectionTitle('Materiais de TI necessários'),
      pw.SizedBox(height: 8),
    ];

    final entries = grouped.entries.toList();
    for (var g = 0; g < entries.length; g++) {
      final entry = entries[g];
      final isLastGroup = g == entries.length - 1;

      if (isLastGroup && tail != null) {
        if (entry.value.length == 1) {
          // Grupo de 1 item: o grupo inteiro vai junto com a assinatura.
          tail
            ..add(groupTitle(entry.key))
            ..add(pw.SizedBox(height: 4))
            ..add(table([headerRow(), itemRow(entry.value.first)]));
        } else {
          // Separa so a ultima linha da tabela (mesmas colunas e bordas).
          result
            ..add(groupTitle(entry.key))
            ..add(pw.SizedBox(height: 4))
            ..add(
              table([
                headerRow(),
                ...entry.value
                    .sublist(0, entry.value.length - 1)
                    .map(itemRow),
              ]),
            );
          tail.add(table([itemRow(entry.value.last)]));
        }
        continue;
      }

      result
        ..add(groupTitle(entry.key))
        ..add(pw.SizedBox(height: 4))
        ..add(table([headerRow(), ...entry.value.map(itemRow)]))
        ..add(pw.SizedBox(height: 10));
    }

    return result;
  }

  /// Uma foto com o comentario logo abaixo (usada na grade de 2 colunas).
  static pw.Widget _buildPhotoCell(MapEntry<pw.MemoryImage, String?> entry) {
    final comment = entry.value?.trim() ?? '';
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          height: 210,
          alignment: pw.Alignment.center,
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey300, width: 0.6),
          ),
          child: pw.Image(entry.key, fit: pw.BoxFit.contain),
        ),
        if (comment.isNotEmpty) ...[
          pw.SizedBox(height: 4),
          pw.Text(
            _s(comment),
            style: const pw.TextStyle(fontSize: 9.5),
          ),
        ],
      ],
    );
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
