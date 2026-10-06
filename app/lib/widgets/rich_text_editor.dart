import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/rich_markup.dart';

/// Controller que mostra **negrito**, _italico_ e ++sublinhado++ formatados
/// dentro do proprio campo (as marcas ficam apagadas). O texto armazenado e
/// sempre o texto com as marcas.
class MarkupTextEditingController extends TextEditingController {
  MarkupTextEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // Durante a digitacao com teclado (texto "em composicao") mantem o padrao
    // para nao atrapalhar o corretor/teclado.
    if (withComposing && value.composing.isValid && !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final base = style ?? const TextStyle();
    final dim = (base.color ?? Colors.black).withValues(alpha: 0.35);
    return TextSpan(
      style: base,
      children: [
        for (final s in RichMarkup.spans(text))
          TextSpan(
            text: s.text,
            style: TextStyle(
              fontWeight: s.bold && !s.marker ? FontWeight.bold : null,
              fontStyle: s.italic && !s.marker ? FontStyle.italic : null,
              decoration: s.underline && !s.marker
                  ? TextDecoration.underline
                  : null,
              color: s.marker ? dim : null,
            ),
          ),
      ],
    );
  }
}

/// Campo de texto com barra de formatacao (negrito, italico, sublinhado,
/// marcadores e lista numerada).
class RichTextEditor extends StatefulWidget {
  final MarkupTextEditingController controller;
  final String label;
  final String? hint;
  final int minLines;
  final FormFieldValidator<String>? validator;

  const RichTextEditor({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.minLines = 12,
    this.validator,
  });

  @override
  State<RichTextEditor> createState() => _RichTextEditorState();
}

class _RichTextEditorState extends State<RichTextEditor> {
  final FocusNode _focus = FocusNode();
  String _previous = '';

  @override
  void initState() {
    super.initState();
    _previous = widget.controller.text;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  TextSelection _currentSelection() {
    final c = widget.controller;
    final sel = c.selection;
    if (sel.isValid && sel.start >= 0 && sel.end <= c.text.length) return sel;
    return TextSelection.collapsed(offset: c.text.length);
  }

  /// Aplica (ou remove) uma marca ao redor do texto selecionado.
  void _wrap(String open, String close) {
    final c = widget.controller;
    final text = c.text;
    final sel = _currentSelection();
    final start = sel.start;
    final end = sel.end;
    final selected = text.substring(start, end);

    // Ja esta marcado? Entao remove a marca (liga/desliga).
    if (!selected.contains('\n') &&
        start >= open.length &&
        end + close.length <= text.length &&
        text.substring(start - open.length, start) == open &&
        text.substring(end, end + close.length) == close) {
      final newText =
          text.substring(0, start - open.length) +
          selected +
          text.substring(end + close.length);
      c.value = TextEditingValue(
        text: newText,
        selection: TextSelection(
          baseOffset: start - open.length,
          extentOffset: end - open.length,
        ),
      );
    } else if (selected.isEmpty) {
      c.value = TextEditingValue(
        text: text.substring(0, start) + open + close + text.substring(end),
        selection: TextSelection.collapsed(offset: start + open.length),
      );
    } else {
      // Cada linha selecionada recebe suas proprias marcas.
      final wrapped = selected
          .split('\n')
          .map((l) => l.trim().isEmpty ? l : '$open$l$close')
          .join('\n');
      c.value = TextEditingValue(
        text: text.substring(0, start) + wrapped + text.substring(end),
        selection: TextSelection(
          baseOffset: start,
          extentOffset: start + wrapped.length,
        ),
      );
    }
    _previous = c.text;
    _focus.requestFocus();
  }

  /// Liga/desliga marcadores ou numeracao nas linhas selecionadas.
  void _toggleList({required bool numbered}) {
    final c = widget.controller;
    final text = c.text;
    final sel = _currentSelection();

    final lineStart = sel.start == 0
        ? 0
        : text.lastIndexOf('\n', sel.start - 1) + 1;
    final endRef = (sel.end > sel.start && sel.end > 0) ? sel.end - 1 : sel.end;
    var lineEnd = text.indexOf('\n', endRef);
    if (lineEnd == -1) lineEnd = text.length;
    if (lineEnd < lineStart) lineEnd = lineStart;

    final lines = text.substring(lineStart, lineEnd).split('\n');
    final prefix = RegExp(r'^\s*([-•]|\d+[.)])\s+');
    final target = numbered ? RichMarkup.numberedLine : RichMarkup.bulletLine;
    final filled = lines.where((l) => l.trim().isNotEmpty).toList();
    final allTarget = filled.isNotEmpty && filled.every(target.hasMatch);

    var n = 1;
    final newLines = <String>[];
    for (final l in lines) {
      final stripped = l.replaceFirst(prefix, '');
      if (allTarget || l.trim().isEmpty) {
        newLines.add(stripped);
      } else {
        newLines.add(numbered ? '${n++}. $stripped' : '- $stripped');
      }
    }
    final block = newLines.join('\n');
    c.value = TextEditingValue(
      text: text.substring(0, lineStart) + block + text.substring(lineEnd),
      selection: lines.length > 1
          ? TextSelection(
              baseOffset: lineStart,
              extentOffset: lineStart + block.length,
            )
          : TextSelection.collapsed(offset: lineStart + block.length),
    );
    _previous = c.text;
    _focus.requestFocus();
  }

  /// Ao dar Enter numa linha de lista, continua a lista (ou encerra se o item
  /// estava vazio).
  void _onChanged(String value) {
    final c = widget.controller;
    if (value.length == _previous.length + 1 && c.selection.isCollapsed) {
      final pos = c.selection.baseOffset;
      if (pos > 0 && pos <= value.length && value[pos - 1] == '\n') {
        final lineStart = pos - 1 == 0
            ? 0
            : value.lastIndexOf('\n', pos - 2) + 1;
        final prevLine = value.substring(lineStart, pos - 1);
        final bullet = RichMarkup.bulletLine.firstMatch(prevLine);
        final number = RichMarkup.numberedLine.firstMatch(prevLine);
        if (bullet != null || number != null) {
          final content = bullet != null
              ? bullet.group(1)!
              : number!.group(2)!;
          if (content.trim().isEmpty) {
            c.value = TextEditingValue(
              text: value.substring(0, lineStart) + value.substring(pos),
              selection: TextSelection.collapsed(offset: lineStart),
            );
          } else {
            final nextPrefix = bullet != null
                ? '- '
                : '${(int.tryParse(number!.group(1)!) ?? 0) + 1}. ';
            c.value = TextEditingValue(
              text:
                  value.substring(0, pos) + nextPrefix + value.substring(pos),
              selection: TextSelection.collapsed(
                offset: pos + nextPrefix.length,
              ),
            );
          }
        }
      }
    }
    _previous = c.text;
  }

  Widget _button(IconData icon, String tooltip, VoidCallback onPressed) {
    return IconButton.filledTonal(
      onPressed: onPressed,
      icon: Icon(icon),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _button(Icons.format_bold, 'Negrito', () => _wrap('**', '**')),
            _button(Icons.format_italic, 'Itálico', () => _wrap('_', '_')),
            _button(
              Icons.format_underlined,
              'Sublinhado',
              () => _wrap('++', '++'),
            ),
            const SizedBox(width: 8),
            _button(
              Icons.format_list_bulleted,
              'Marcadores',
              () => _toggleList(numbered: false),
            ),
            _button(
              Icons.format_list_numbered,
              'Lista numerada',
              () => _toggleList(numbered: true),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: widget.controller,
          focusNode: _focus,
          minLines: widget.minLines,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          onChanged: _onChanged,
          validator: widget.validator,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            helperText:
                'Selecione o texto e use os botões acima. O PDF sai com a mesma formatação.',
            helperMaxLines: 2,
            alignLabelWithHint: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ],
    );
  }
}

/// Mostra o texto das observacoes com a formatacao (para telas de leitura).
class RichObservationText extends StatelessWidget {
  final String text;
  final TextStyle style;

  const RichObservationText({super.key, required this.text, required this.style});

  List<InlineSpan> _spans(List<RichSpan> spans) => [
    for (final s in spans)
      TextSpan(
        text: s.text,
        style: TextStyle(
          fontWeight: s.bold ? FontWeight.bold : null,
          fontStyle: s.italic ? FontStyle.italic : null,
          decoration: s.underline ? TextDecoration.underline : null,
        ),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final gap = math.max(6.0, (style.fontSize ?? 14) * 0.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in RichMarkup.lines(text))
          if (line.kind == RichLineKind.blank)
            SizedBox(height: gap)
          else if (line.kind == RichLineKind.normal)
            Text.rich(TextSpan(style: style, children: _spans(line.spans)))
          else
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: line.kind == RichLineKind.bullet ? 16 : 24,
                    child: Text(line.label, style: style),
                  ),
                  Expanded(
                    child: Text.rich(
                      TextSpan(style: style, children: _spans(line.spans)),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
