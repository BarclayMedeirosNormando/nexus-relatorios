import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../utils/text_encoding.dart';
import '../utils/json_utils.dart';

class PhotoItem {
  final String path;
  String? comment;

  PhotoItem({required this.path, this.comment});

  Map<String, dynamic> toJson() => {'path': path, 'comment': comment};

  factory PhotoItem.fromJson(Map<String, dynamic> json) => PhotoItem(
    path: fixMojibake(
      (json['path'] ??
              json['url'] ??
              json['link'] ??
              json['fileUrl'] ??
              json['downloadUrl'] ??
              '')
          .toString(),
    ),
    comment:
        (json['comment'] ??
                json['comentario'] ??
                json['description'] ??
                json['legenda']) ==
            null
        ? null
        : fixMojibake(
            (json['comment'] ??
                    json['comentario'] ??
                    json['description'] ??
                    json['legenda'])
                .toString(),
          ),
  );
}

class TiMaterialItem {
  final String ambiente;
  final String equipamento;
  final String marcaModelo;
  final String quantidade;
  final String observacao;

  const TiMaterialItem({
    required this.ambiente,
    required this.equipamento,
    required this.marcaModelo,
    required this.quantidade,
    this.observacao = '',
  });

  Map<String, dynamic> toJson() => {
    'ambiente': ambiente,
    'equipamento': equipamento,
    'marcaModelo': marcaModelo,
    'quantidade': quantidade,
    'observacao': observacao,
  };

  factory TiMaterialItem.fromJson(Map<String, dynamic> json) => TiMaterialItem(
    ambiente: fixMojibake(JsonUtils.asString(json['ambiente']).trim()),
    equipamento: fixMojibake(
      JsonUtils.asString(json['equipamento'] ?? json['material']).trim(),
    ),
    marcaModelo: fixMojibake(
      JsonUtils.asString(
        json['marcaModelo'] ?? json['marca_modelo'] ?? json['marca'],
      ).trim(),
    ),
    quantidade: fixMojibake(JsonUtils.asString(json['quantidade']).trim()),
    observacao: fixMojibake(
      JsonUtils.asString(
        json['observacao'] ?? json['observação'] ?? json['observacoes'],
      ).trim(),
    ),
  );
}

class ReportModel {
  // Compatibility wrappers for legacy calls
  static String asString(dynamic value) => JsonUtils.asString(value);
  static String? asNullableString(dynamic value) =>
      JsonUtils.asNullableString(value);
  static List<String> asStringList(dynamic value) =>
      JsonUtils.asStringList(value);

  final String id;
  final String reportNumber;
  final bool isTechnicalAnalysis;
  final String creator;

  final String schoolName;
  final String? schoolAddress;
  final String? schoolCity;
  final String? schoolInep;
  final DateTime visitDate;
  final List<String> subjects;
  final String? observations;
  final List<TiMaterialItem> tiMaterials;

  final String? gre;
  final List<PhotoItem> photos;

  final List<String> technicians;
  final String? responsiblePerson;

  final Uint8List? signatureBytes;
  final List<Uint8List>? signatureBytesList;
  final String? signatureUrl;
  final List<String>? signatureUrlList;
  final String? urlFotos;
  final String? fotosJson;

  final String syncStatus;
  final DateTime? lastSyncedAt;
  final DateTime? localUpdatedAt;
  final DateTime? updatedAt;

  ReportModel({
    required this.id,
    String? reportNumber,
    this.isTechnicalAnalysis = true,
    required this.creator,
    required this.schoolName,
    this.schoolAddress,
    this.schoolCity,
    this.schoolInep,
    required this.visitDate,
    this.subjects = const [],
    this.observations,
    this.tiMaterials = const [],
    this.gre,
    this.photos = const [],
    this.technicians = const [],
    this.responsiblePerson,
    this.signatureBytes,
    this.signatureBytesList,
    this.signatureUrl,
    this.signatureUrlList,
    this.urlFotos,
    this.fotosJson,
    this.syncStatus = 'synced',
    this.lastSyncedAt,
    this.localUpdatedAt,
    this.updatedAt,
  }) : reportNumber =
           reportNumber ??
           'REL-${DateTime.now().millisecondsSinceEpoch.toString().substring(3)}';

  ReportModel copyWith({
    String? id,
    String? reportNumber,
    bool? isTechnicalAnalysis,
    String? creator,
    String? schoolName,
    String? schoolAddress,
    String? schoolCity,
    String? schoolInep,
    DateTime? visitDate,
    List<String>? subjects,
    String? observations,
    List<TiMaterialItem>? tiMaterials,
    String? gre,
    List<PhotoItem>? photos,
    List<String>? technicians,
    String? responsiblePerson,
    Uint8List? signatureBytes,
    List<Uint8List>? signatureBytesList,
    String? signatureUrl,
    List<String>? signatureUrlList,
    String? urlFotos,
    String? fotosJson,
    String? syncStatus,
    DateTime? lastSyncedAt,
    DateTime? localUpdatedAt,
    DateTime? updatedAt,
  }) {
    return ReportModel(
      id: id ?? this.id,
      reportNumber: reportNumber ?? this.reportNumber,
      isTechnicalAnalysis: isTechnicalAnalysis ?? this.isTechnicalAnalysis,
      creator: creator ?? this.creator,
      schoolName: schoolName ?? this.schoolName,
      schoolAddress: schoolAddress ?? this.schoolAddress,
      schoolCity: schoolCity ?? this.schoolCity,
      schoolInep: schoolInep ?? this.schoolInep,
      visitDate: visitDate ?? this.visitDate,
      subjects: subjects ?? this.subjects,
      observations: observations ?? this.observations,
      tiMaterials: tiMaterials ?? this.tiMaterials,
      gre: gre ?? this.gre,
      photos: photos ?? this.photos,
      technicians: technicians ?? this.technicians,
      responsiblePerson: responsiblePerson ?? this.responsiblePerson,
      signatureBytes: signatureBytes ?? this.signatureBytes,
      signatureBytesList: signatureBytesList ?? this.signatureBytesList,
      signatureUrl: signatureUrl ?? this.signatureUrl,
      signatureUrlList: signatureUrlList ?? this.signatureUrlList,
      urlFotos: urlFotos ?? this.urlFotos,
      fotosJson: fotosJson ?? this.fotosJson,
      syncStatus: syncStatus ?? this.syncStatus,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      localUpdatedAt: localUpdatedAt ?? this.localUpdatedAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'reportNumber': reportNumber,
    'isTechnicalAnalysis': isTechnicalAnalysis,
    'creator': creator,
    'schoolName': schoolName,
    'schoolAddress': schoolAddress,
    'schoolCity': schoolCity,
    'schoolInep': schoolInep,
    'inep': schoolInep,
    'visitDate': visitDate.toIso8601String(),
    'subjects': subjects,
    'observations': observations,
    'tiMaterials': tiMaterials.map((item) => item.toJson()).toList(),
    'materiais_ti_json': jsonEncode(
      tiMaterials.map((item) => item.toJson()).toList(),
    ),
    'gre': gre,
    'photos': photos.map((p) => p.toJson()).toList(),
    'urlFotos':
        urlFotos ??
        photos.map((p) => p.path).where((p) => p.startsWith('http')).join(', '),
    'fotosJson':
        fotosJson ??
        jsonEncode(
          photos
              .map((p) => {'url': p.path, 'comment': p.comment ?? ''})
              .toList(),
        ),
    'technicians': technicians,
    'responsiblePerson': responsiblePerson,
    'signatureBytes': signatureBytes != null
        ? base64Encode(signatureBytes!)
        : null,
    'signatureBytesList': signatureBytesList
        ?.map((bytes) => base64Encode(bytes))
        .toList(),
    'assinaturaBase64List': signatureBytesList
        ?.map((bytes) => base64Encode(bytes))
        .toList(),
    'signatureUrl': signatureUrl,
    'signatureUrlList': signatureUrlList,
    'urlAssinatura': signatureUrl,
    'syncStatus': syncStatus,
    'lastSyncedAt': lastSyncedAt?.toIso8601String(),
    'localUpdatedAt': localUpdatedAt?.toIso8601String(),
    'updatedAt': updatedAt?.toIso8601String(),
  };

  static String _resolveDriveUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.contains('drive.google.com')) {
      final fileMatch =
          RegExp(r'/file/d/([a-zA-Z0-9_-]+)').firstMatch(trimmed) ??
          RegExp(r'/d/([a-zA-Z0-9_-]+)').firstMatch(trimmed);
      if (fileMatch != null) {
        final id = fileMatch.group(1);
        return 'https://drive.google.com/uc?export=download&id=$id';
      }
      final idMatch = RegExp(r'[?&]id=([a-zA-Z0-9_-]+)').firstMatch(trimmed);
      if (idMatch != null) {
        final id = idMatch.group(1);
        return 'https://drive.google.com/uc?export=download&id=$id';
      }
    }
    return trimmed;
  }

  static List<PhotoItem> parsePhotosFromJson(Map<String, dynamic> json) {
    final result = <PhotoItem>[];

    final photosValue = json['photos'] ?? json['fotos'];
    final fotosJsonValue =
        json['fotosJson'] ??
        json['fotos_json'] ??
        json['Fotos JSON'] ??
        json['FOTOS_JSON'];
    final urlFotosValue =
        json['urlFotos'] ??
        json['Link Foto'] ??
        json['Link Fotos'] ??
        json['url_fotos'];

    void addPhoto(String path, [String? comment]) {
      final cleanPath = _resolveDriveUrl(path);
      if (cleanPath.isEmpty ||
          cleanPath.contains('drive.google.com/drive/folders')) {
        return;
      }
      result.add(
        PhotoItem(
          path: fixMojibake(cleanPath),
          comment: comment != null && comment.trim().isNotEmpty
              ? fixMojibake(comment.trim())
              : null,
        ),
      );
    }

    if (photosValue is List) {
      for (final item in photosValue) {
        if (item is Map) {
          final map = Map<String, dynamic>.from(item);
          final path = JsonUtils.asString(
            map['path'] ??
                map['url'] ??
                map['link'] ??
                map['fileUrl'] ??
                map['downloadUrl'] ??
                map['base64'],
          );
          final comment = JsonUtils.asString(
            map['comment'] ??
                map['comentario'] ??
                map['description'] ??
                map['legenda'] ??
                map['descricao'],
          );
          addPhoto(path, comment);
        } else if (item != null) {
          addPhoto(JsonUtils.asString(item));
        }
      }
    } else if (photosValue != null) {
      final text = JsonUtils.asString(photosValue).trim();
      if (text.isNotEmpty) {
        if (text.startsWith('[') || text.startsWith('{')) {
          try {
            final decoded = jsonDecode(text);
            if (decoded is List) {
              for (final item in decoded) {
                if (item is Map) {
                  final map = Map<String, dynamic>.from(item);
                  final path = JsonUtils.asString(
                    map['path'] ??
                        map['url'] ??
                        map['link'] ??
                        map['fileUrl'] ??
                        map['downloadUrl'] ??
                        map['base64'],
                  );
                  final comment = JsonUtils.asString(
                    map['comment'] ??
                        map['comentario'] ??
                        map['description'] ??
                        map['legenda'] ??
                        map['descricao'],
                  );
                  addPhoto(path, comment);
                }
              }
            }
          } catch (_) {}
        } else {
          addPhoto(text);
        }
      }
    }

    final fotosJsonText = JsonUtils.asString(fotosJsonValue).trim();
    if (fotosJsonText.isNotEmpty) {
      try {
        final decoded = jsonDecode(fotosJsonText);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final map = Map<String, dynamic>.from(item);
              final path = JsonUtils.asString(
                map['path'] ??
                    map['url'] ??
                    map['link'] ??
                    map['fileUrl'] ??
                    map['downloadUrl'] ??
                    map['base64'],
              );
              final comment = JsonUtils.asString(
                map['comment'] ??
                    map['comentario'] ??
                    map['description'] ??
                    map['legenda'] ??
                    map['descricao'],
              );
              addPhoto(path, comment);
            }
          }
        }
      } catch (e) {
        debugPrint('Erro ao decodificar fotosJson: $e');
      }
    }

    if (urlFotosValue is List) {
      for (final item in urlFotosValue) {
        addPhoto(JsonUtils.asString(item));
      }
    } else {
      final text = JsonUtils.asString(urlFotosValue).trim();
      if (text.isNotEmpty) {
        final urls = text
            .split(RegExp(r',|;|\n'))
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty);

        for (final url in urls) {
          addPhoto(url);
        }
      }
    }

    final unique = <String, PhotoItem>{};
    for (final photo in result) {
      unique[photo.path] = photo;
    }

    return unique.values.toList();
  }

  static List<TiMaterialItem> parseTiMaterialsFromJson(
    Map<String, dynamic> json,
  ) {
    final value =
        json['tiMaterials'] ??
        json['materiais_ti_json'] ??
        json['materiaisTiJson'] ??
        json['materiaisTIJson'] ??
        json['MATERIAIS_TI_JSON'];

    dynamic decoded = value;
    if (decoded is String) {
      final text = decoded.trim();
      if (text.isEmpty) return const [];
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        return const [];
      }
    }

    if (decoded is! List) return const [];

    final items = <TiMaterialItem>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final material = TiMaterialItem.fromJson(Map<String, dynamic>.from(item));
      if (material.ambiente.isEmpty ||
          material.equipamento.isEmpty ||
          material.quantidade.isEmpty) {
        continue;
      }
      items.add(material);
    }
    return items;
  }

  static DateTime? _tryParseDate(dynamic value) {
    final text = JsonUtils.asString(value).trim();
    if (text.isEmpty) return null;
    return DateTime.tryParse(text);
  }

  static Uint8List? _readSignatureBytes(Map<String, dynamic> json) {
    final source = JsonUtils.asNullableString(
      json['signatureBytes'] ?? json['assinaturaBase64'],
    );
    if (source == null) return null;
    try {
      final clean = source.contains(',') ? source.split(',').last : source;
      return base64Decode(clean);
    } catch (_) {
      return null;
    }
  }

  static List<Uint8List>? _readSignatureBytesList(Map<String, dynamic> json) {
    final dynamic listValue = json['signatureBytesList'] ?? json['assinaturaBase64List'];
    if (listValue == null) return null;
    if (listValue is List) {
      final result = <Uint8List>[];
      for (final item in listValue) {
        final source = JsonUtils.asNullableString(item);
        if (source == null) continue;
        try {
          final clean = source.contains(',') ? source.split(',').last : source;
          result.add(base64Decode(clean));
        } catch (_) {
          continue;
        }
      }
      return result.isEmpty ? null : result;
    }
    final stringValue = JsonUtils.asNullableString(listValue);
    if (stringValue == null) return null;
    try {
      final decoded = jsonDecode(stringValue);
      if (decoded is List) {
        return _readSignatureBytesList({'signatureBytesList': decoded});
      }
    } catch (_) {}
    return null;
  }

  static List<String>? _readSignatureUrlList(Map<String, dynamic> json) {
    final dynamic listValue = json['signatureUrlList'];
    if (listValue == null) {
      final singleUrl = JsonUtils.asNullableString(
        json['signatureUrl'] ?? json['urlAssinatura'],
      );
      return singleUrl == null ? null : [singleUrl];
    }
    if (listValue is List) {
      final result = <String>[];
      for (final item in listValue) {
        final url = JsonUtils.asNullableString(item);
        if (url != null) result.add(url);
      }
      return result.isEmpty ? null : result;
    }
    final stringValue = JsonUtils.asNullableString(listValue);
    if (stringValue == null) return null;
    if (stringValue.startsWith('[') && stringValue.endsWith(']')) {
      try {
        final decoded = jsonDecode(stringValue);
        if (decoded is List) {
          return _readSignatureUrlList({'signatureUrlList': decoded});
        }
      } catch (_) {}
    }
    return stringValue
        .split(RegExp(r',|;|\n'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  factory ReportModel.fromJson(Map<String, dynamic> json) {
    final visitDate =
        _tryParseDate(
          json['visitDate'] ?? json['dataVisita'] ?? json['data_visita'],
        ) ??
        DateTime.now();
    final typeText = JsonUtils.asString(
      json['tipo'] ?? json['tipo_relatorio'] ?? json['Tipo de Relatório'],
    ).trim().toLowerCase();
    final isTechnicalValue = json['isTechnicalAnalysis'];
    final isTechnical = isTechnicalValue is bool
        ? isTechnicalValue
        : !(typeText.contains('nao') ||
              typeText.contains('não') ||
              typeText.contains('nÃ£o'));

    String fixedString(dynamic value) =>
        fixMojibake(JsonUtils.asString(value).trim());
    String? fixedNullableString(dynamic value) {
      final text = JsonUtils.asNullableString(value);
      return text == null ? null : fixMojibake(text);
    }

    List<String> fixedStringList(dynamic value) =>
        JsonUtils.asStringList(value).map(fixMojibake).toList();

    return ReportModel(
      id: fixedString(json['id'] ?? json['ID do Relatório']),
      reportNumber: fixedNullableString(
        json['reportNumber'] ??
            json['numeroRelatorio'] ??
            json['numero_relatorio'] ??
            json['Número do Relatório'] ??
            json['Numero do Relatorio'],
      ),
      isTechnicalAnalysis: isTechnical,
      creator:
          fixedNullableString(
            json['creator'] ??
                json['usuario'] ??
                json['usuario_logado'] ??
                json['Usuario Logado'] ??
                json['Usuário Logado'],
          ) ??
          'Desconhecido',
      schoolName: fixedString(
        json['schoolName'] ?? json['escola'] ?? json['Nome da Escola'],
      ),
      schoolAddress: fixedNullableString(
        json['schoolAddress'] ??
            json['endereco'] ??
            json['endereco_escola'] ??
            json['Endereco da Escola'] ??
            json['Endereço da Escola'],
      ),
      schoolCity: fixedNullableString(
        json['schoolCity'] ??
            json['municipio'] ??
            json['município'] ??
            json['municipioEscola'] ??
            json['cidade'] ??
            json['city'] ??
            json['Município'] ??
            json['Municipio'] ??
            json['Cidade'],
      ),
      schoolInep: fixedNullableString(
        json['schoolInep'] ??
            json['inep'] ??
            json['INEP'] ??
            json['codigoInep'] ??
            json['códigoInep'] ??
            json['codInep'] ??
            json['inepEscola'] ??
            json['INEP Escola'] ??
            json['Código INEP'],
      ),
      visitDate: visitDate,
      subjects: fixedStringList(
        json['subjects'] ?? json['motivos'] ?? json['Motivos / Assuntos'],
      ),
      observations: fixedNullableString(
        json['observations'] ??
            json['observacoes'] ??
            json['Observações'] ??
            json['Observacoes'],
      ),
      tiMaterials: parseTiMaterialsFromJson(json),
      gre: fixedNullableString(
        json['gre'] ?? json['GRE'] ?? json['Regional (GRE)'],
      ),
      photos: parsePhotosFromJson(json),
      urlFotos: fixedNullableString(
        json['urlFotos'] ?? json['Link Foto'] ?? json['Link Fotos'],
      ),
      fotosJson: fixedNullableString(
        json['fotosJson'] ??
            json['Fotos JSON'] ??
            json['FOTOS_JSON'] ??
            json['fotos_json'],
      ),
      technicians: fixedStringList(
        json['technicians'] ??
            json['tecnicos'] ??
            json['Técnicos Presentes'] ??
            json['Tecnicos Presentes'],
      ),
      responsiblePerson: fixedNullableString(
        json['responsiblePerson'] ??
            json['responsavel'] ??
            json['Responsável da Escola'] ??
            json['Responsavel da Escola'],
      ),
      signatureBytes: _readSignatureBytes(json),
      signatureUrl: fixedNullableString(
        json['signatureUrl'] ??
            json['urlAssinatura'] ??
            json['Link Assinatura'] ??
            json['URL_ASSINATURA'],
      ),
      signatureUrlList: _readSignatureUrlList(json),
      signatureBytesList: _readSignatureBytesList(json),
      syncStatus: fixedString(json['syncStatus'] ?? 'synced'),
      lastSyncedAt: _tryParseDate(json['lastSyncedAt']),
      localUpdatedAt: _tryParseDate(json['localUpdatedAt']),
      updatedAt: _tryParseDate(
        json['updatedAt'] ?? json['dataEnvio'] ?? json['dataRegistro'],
      ),
    );
  }
}
