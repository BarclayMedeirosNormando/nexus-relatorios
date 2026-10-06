/// Formatacao leve de texto usada em "Diagnostico / Observacoes".
///
/// O texto continua sendo uma string simples (por isso nada muda na planilha
/// nem no servidor). A formatacao e guardada com marcas:
///   **negrito**   _italico_   ++sublinhado++
///   linhas iniciadas por "- " viram marcadores
///   linhas iniciadas por "1. " viram lista numerada
/// A mesma regra e usada na tela e no PDF, entao os dois ficam iguais.
class RichSpan {
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;

  /// true para as marcas (**, _, ++): aparecem no editor, nao no PDF.
  final bool marker;

  const RichSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.marker = false,
  });
}

enum RichLineKind { blank, normal, bullet, numbered }

class RichLine {
  final RichLineKind kind;

  /// "•" para marcadores, "1." para numerada, vazio nos demais.
  final String label;

  /// Trechos sem as marcas de formatacao.
  final List<RichSpan> spans;

  const RichLine(this.kind, {this.label = '', this.spans = const []});

  String get plainText => spans.map((s) => s.text).join();
}

class RichMarkup {
  static final RegExp _bold = RegExp(r'\*\*(.+?)\*\*');
  static final RegExp _under = RegExp(r'\+\+(.+?)\+\+');
  static final RegExp _italic = RegExp(r'_(.+?)_');
  static final RegExp _wordChar = RegExp(r'[A-Za-z0-9_À-ÿ]');
  static final RegExp bulletLine = RegExp(r'^\s*[-•]\s+(.*)$');
  static final RegExp numberedLine = RegExp(r'^\s*(\d+)[.)]\s+(.*)$');

  /// Divide [text] em trechos. A concatenacao de todos os trechos (com marcas)
  /// e exatamente igual ao texto original.
  static List<RichSpan> spans(String text) {
    final out = <RichSpan>[];
    _parse(text, false, false, false, out);
    return out;
  }

  /// Igual a [spans], mas sem as marcas.
  static List<RichSpan> visibleSpans(String text) =>
      spans(text).where((s) => !s.marker && s.text.isNotEmpty).toList();

  static Match? _nextItalic(String s, int from) {
    var start = from;
    while (start < s.length) {
      final it = _italic.allMatches(s, start).iterator;
      if (!it.moveNext()) return null;
      final m = it.current;
      final before = m.start > 0 ? s[m.start - 1] : '';
      final after = m.end < s.length ? s[m.end] : '';
      // "_" dentro de uma palavra (ex.: nome_do_arquivo) nao e italico.
      if ((before.isNotEmpty && _wordChar.hasMatch(before)) ||
          (after.isNotEmpty && _wordChar.hasMatch(after))) {
        start = m.start + 1;
        continue;
      }
      return m;
    }
    return null;
  }

  static Match? _first(RegExp re, String s, int from) {
    final it = re.allMatches(s, from).iterator;
    return it.moveNext() ? it.current : null;
  }

  static void _parse(String s, bool b, bool i, bool u, List<RichSpan> out) {
    var pos = 0;
    while (pos < s.length) {
      final mb = _first(_bold, s, pos);
      final mu = _first(_under, s, pos);
      final mi = _nextItalic(s, pos);

      Match? best;
      String kind = '';
      for (final entry in [('b', mb), ('u', mu), ('i', mi)]) {
        final m = entry.$2;
        if (m == null) continue;
        if (best == null || m.start < best.start) {
          best = m;
          kind = entry.$1;
        }
      }

      if (best == null) {
        out.add(RichSpan(s.substring(pos), bold: b, italic: i, underline: u));
        return;
      }
      if (best.start > pos) {
        out.add(
          RichSpan(s.substring(pos, best.start), bold: b, italic: i, underline: u),
        );
      }
      final mark = kind == 'i' ? '_' : (kind == 'b' ? '**' : '++');
      out.add(RichSpan(mark, bold: b, italic: i, underline: u, marker: true));
      _parse(
        best.group(1)!,
        b || kind == 'b',
        i || kind == 'i',
        u || kind == 'u',
        out,
      );
      out.add(RichSpan(mark, bold: b, italic: i, underline: u, marker: true));
      pos = best.end;
    }
  }

  /// Linhas do texto ja classificadas (normal, marcador, numerada, vazia).
  static List<RichLine> lines(String text) {
    final result = <RichLine>[];
    for (final raw in text.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        result.add(const RichLine(RichLineKind.blank));
        continue;
      }
      final bullet = bulletLine.firstMatch(line);
      if (bullet != null) {
        result.add(
          RichLine(
            RichLineKind.bullet,
            label: '•',
            spans: visibleSpans(bullet.group(1)!),
          ),
        );
        continue;
      }
      final numbered = numberedLine.firstMatch(line);
      if (numbered != null) {
        result.add(
          RichLine(
            RichLineKind.numbered,
            label: '${numbered.group(1)}.',
            spans: visibleSpans(numbered.group(2)!),
          ),
        );
        continue;
      }
      result.add(RichLine(RichLineKind.normal, spans: visibleSpans(line.trim())));
    }
    return result;
  }

  /// Texto sem marcas (para busca ou lugares sem formatacao).
  static String plain(String text) {
    return lines(text).map((l) {
      switch (l.kind) {
        case RichLineKind.blank:
          return '';
        case RichLineKind.normal:
          return l.plainText;
        case RichLineKind.bullet:
        case RichLineKind.numbered:
          return '${l.label} ${l.plainText}';
      }
    }).join('\n');
  }
}
