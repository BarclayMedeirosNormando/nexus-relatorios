import 'dart:convert';

String fixMojibake(String value) {
  var text = value;
  if (text.isEmpty) return text;

  if (text.contains('Ã') || text.contains('Â')) {
    try {
      final repaired = utf8.decode(latin1.encode(text), allowMalformed: true);
      if (!_looksMoreBroken(repaired, text)) {
        text = repaired;
      }
    } catch (_) {}
  }

  const replacements = {
    'Jo�o': 'João',
    'jo�o': 'joão',
    'N�o': 'Não',
    'n�o': 'não',
    'S�o': 'São',
    's�o': 'são',
    'Catol�': 'Catolé',
    'Cuit�': 'Cuité',
    'T�cnico': 'Técnico',
    't�cnico': 'técnico',
    'T�cnicos': 'Técnicos',
    't�cnicos': 'técnicos',
    'Munic�pio': 'Município',
    'munic�pio': 'município',
    'Observa��es': 'Observações',
    'observa��es': 'observações',
    'Respons�vel': 'Responsável',
    'respons�vel': 'responsável',
    'Educa��o': 'Educação',
    'educa��o': 'educação',
    'Para�ba': 'Paraíba',
    'Matr�cula': 'Matrícula',
    'matr�cula': 'matrícula',
    'Relat�rio': 'Relatório',
    'relat�rio': 'relatório',
    'Diagn�stico': 'Diagnóstico',
    'diagn�stico': 'diagnóstico',
    'Edi��o': 'Edição',
    'edi��o': 'edição',
    'Relat�rios': 'Relatórios',
    'relat�rios': 'relatórios',
    'Vers�o': 'Versão',
    'vers�o': 'versão',
    '� GRE': 'ª GRE',
  };

  replacements.forEach((broken, fixed) {
    text = text.replaceAll(broken, fixed);
  });
  return text;
}

dynamic fixMojibakeDeep(dynamic value) {
  if (value is String) return fixMojibake(value);
  if (value is List) return value.map(fixMojibakeDeep).toList();
  if (value is Map) {
    return value.map((key, item) => MapEntry(key, fixMojibakeDeep(item)));
  }
  return value;
}

bool _looksMoreBroken(String repaired, String original) {
  int score(String text) {
    final bad = RegExp('[ÃÂ�]').allMatches(text).length;
    return bad * 3 + RegExp(r'\s').allMatches(text).length;
  }

  return score(repaired) > score(original);
}
