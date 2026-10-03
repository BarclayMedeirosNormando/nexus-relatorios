import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:signature/signature.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/report_model.dart';
import '../models/employee_model.dart';
import '../services/employee_service.dart';
import '../services/school_service.dart';
import '../widgets/app_ui.dart';

class NonTechnicalReportScreen extends StatefulWidget {
  const NonTechnicalReportScreen({super.key});

  @override
  State<NonTechnicalReportScreen> createState() => _NonTechnicalReportScreenState();
}

class _NonTechnicalReportScreenState extends State<NonTechnicalReportScreen> {
  final _formKey = GlobalKey<FormState>();
  
  DateTime? _selectedDate;
  String? _selectedSchool;
  final _subjectController = TextEditingController();
  final _techniciansController = TextEditingController();
  String? _selectedResponsible;

  final SignatureController _signatureController = SignatureController(
    penStrokeWidth: 3,
    penColor: Colors.black,
    exportBackgroundColor: Colors.white,
  );

  final List<String> _schools = [];
  bool _isSaving = false;
  String _creatorName = 'Usuário';

  @override
  void initState() {
    super.initState();
    _loadSchools();
    _loadCreator();
  }

  Future<void> _loadCreator() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _creatorName = prefs.getString('logged_user') ?? 'Usuário';
      });
    }
  }

  void _loadSchools() {
    final service = SchoolService();
    if (service.schools.isNotEmpty) {
      _schools.addAll(service.schools.map((s) => s.name).toList()..sort());
    } else {
      _schools.addAll(['Escola Estadual A', 'Escola Estadual B', 'Escola Técnica C']);
    }
  }

  @override
  void dispose() {
    _subjectController.dispose();
    _techniciansController.dispose();
    _signatureController.dispose();
    super.dispose();
  }

  void _presentDatePicker() async {
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      helpText: 'SELECIONE A DATA DO CHAMADO',
    );
    if (pickedDate != null) {
      setState(() {
        _selectedDate = pickedDate;
      });
    }
  }

  void _submitData() async {
    if (_formKey.currentState!.validate() && _selectedDate != null) {
      if (_signatureController.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A assinatura é obrigatória.')),
        );
        return;
      }

      setState(() => _isSaving = true);

      final Uint8List? signatureBytes = await _signatureController.toPngBytes();

      final newReport = ReportModel(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        isTechnicalAnalysis: false,
        creator: _creatorName,
        schoolName: _selectedSchool ?? '',
        visitDate: _selectedDate!,
        subjects: [_subjectController.text.trim()],
        technicians: _techniciansController.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
        responsiblePerson: _selectedResponsible,
        signatureBytes: signatureBytes,
      );
      
      if (mounted) {
        Navigator.of(context).pop(newReport);
      }
    } else if (_selectedDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Por favor, selecione a data do chamado.')),
      );
    }
  }

  // ── Build Helpers ─────────────────────────────────────────────────────────

  Widget _buildDateSection(ColorScheme colorScheme, TextTheme textTheme) {
    return SectionCard(
      title: 'Dados do Chamado',
      child: InkWell(
        onTap: _presentDatePicker,
        borderRadius: BorderRadius.circular(12),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: 'Data do chamado *',
            prefixIcon: const Icon(Icons.calendar_today_outlined),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          ),
          isEmpty: _selectedDate == null,
          child: Text(
            _selectedDate == null
                ? 'Selecionar data'
                : DateFormat('dd/MM/yyyy').format(_selectedDate!),
            style: textTheme.bodyLarge?.copyWith(
              color: _selectedDate == null ? colorScheme.onSurfaceVariant : colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSchoolSection(ColorScheme colorScheme, TextTheme textTheme) {
    return SectionCard(
      title: 'Escola e Responsável',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: ValueKey('school_$_selectedSchool'),
            decoration: InputDecoration(
              labelText: 'Selecione a Escola *',
              prefixIcon: const Icon(Icons.school_outlined),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            isExpanded: true,
            initialValue: _selectedSchool,
            items: _schools.map((school) {
              return DropdownMenuItem(value: school, child: Text(school, overflow: TextOverflow.ellipsis));
            }).toList(),
            onChanged: (value) => setState(() => _selectedSchool = value),
            validator: (value) => value == null ? 'A escola é obrigatória' : null,
          ),
          const SizedBox(height: 16),
          _buildResponsibleAutocomplete(colorScheme),
        ],
      ),
    );
  }

  Widget _buildResponsibleAutocomplete(ColorScheme colorScheme) {
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
            labelText: 'Responsável pela escola *',
            hintText: 'Busque por matrícula ou nome',
            prefixIcon: const Icon(Icons.person_search_outlined),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onEditingComplete: onEditingComplete,
          validator: (value) => _selectedResponsible == null ? 'O responsável é obrigatório' : null,
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
            color: colorScheme.surface,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: 250, 
                maxWidth: MediaQuery.of(context).size.width > 760 
                  ? 760 - 48 
                  : MediaQuery.of(context).size.width - 48
              ),
              child: ListView.separated(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                separatorBuilder: (ctx, i) => Divider(height: 1, color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
                itemBuilder: (BuildContext context, int index) {
                  final option = options.elementAt(index);
                  return ListTile(
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: colorScheme.primaryContainer,
                      child: Icon(Icons.person_outline, size: 16, color: colorScheme.onPrimaryContainer),
                    ),
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

  Widget _buildTeamReasonSection(ColorScheme colorScheme, TextTheme textTheme) {
    return SectionCard(
      title: 'Equipe e Motivo',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _techniciansController,
            decoration: InputDecoration(
              labelText: 'Técnico(s) *',
              hintText: 'Nomes dos técnicos presentes',
              prefixIcon: const Icon(Icons.group_outlined),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            textCapitalization: TextCapitalization.words,
            validator: (value) => (value == null || value.trim().isEmpty) ? 'A equipe é obrigatória' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _subjectController,
            decoration: InputDecoration(
              labelText: 'Motivo do Chamado *',
              hintText: 'Descreva brevemente o motivo',
              prefixIcon: const Icon(Icons.assignment_outlined),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            textCapitalization: TextCapitalization.sentences,
            validator: (value) => (value == null || value.trim().isEmpty) ? 'O motivo é obrigatório' : null,
          ),
        ],
      ),
    );
  }

  Widget _buildSignatureSection(ColorScheme colorScheme, TextTheme textTheme) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return SectionCard(
      title: 'Assinatura do Responsável *',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
              color: isDark ? colorScheme.surfaceContainerHighest : colorScheme.surface,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                Container(
                  color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.draw_rounded, size: 18, color: colorScheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Text('Área de Assinatura', style: textTheme.labelMedium),
                        ],
                      ),
                      TextButton.icon(
                        onPressed: () => _signatureController.clear(),
                        icon: const Icon(Icons.cleaning_services_rounded, size: 16),
                        label: const Text('Limpar'),
                        style: TextButton.styleFrom(
                          foregroundColor: colorScheme.error,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Signature(
                  controller: _signatureController,
                  height: 180,
                  backgroundColor: isDark ? const Color(0xFFE0E0E0) : colorScheme.surface,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton.icon(
        onPressed: _isSaving ? null : _submitData,
        icon: _isSaving
            ? Builder(builder: (ctx) {
                final cs = Theme.of(ctx).colorScheme;
                return SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary),
                );
              })
            : const Icon(Icons.save_rounded),
        label: Text(
          _isSaving ? 'Salvando...' : 'Salvar Relatório',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Relatório Não Técnico', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildDateSection(colorScheme, textTheme),
                  _buildSchoolSection(colorScheme, textTheme),
                  _buildTeamReasonSection(colorScheme, textTheme),
                  _buildSignatureSection(colorScheme, textTheme),
                  _buildSubmitButton(),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      '* Campos obrigatórios',
                      style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
