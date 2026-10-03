import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/school_model.dart';
import '../services/school_service.dart';
import '../utils/app_constants.dart';
import '../widgets/app_ui.dart';

class SchoolFormScreen extends StatefulWidget {
  final SchoolModel? existingSchool;

  const SchoolFormScreen({super.key, this.existingSchool});

  @override
  State<SchoolFormScreen> createState() => _SchoolFormScreenState();
}

class _SchoolFormScreenState extends State<SchoolFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late String _inep;
  late String _name;
  late String _address;
  late String _city;
  late String _uf;
  late String _gre;

  bool _isSaving = false;

  bool get _isEditing => widget.existingSchool != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      _inep    = widget.existingSchool!.inep;
      _name    = widget.existingSchool!.name;
      _address = widget.existingSchool!.address;
      _city    = widget.existingSchool!.city;
      _uf      = widget.existingSchool!.uf;
      _gre     = widget.existingSchool!.gre;
    } else {
      _inep    = '';
      _name    = '';
      _address = '';
      _city    = '';
      _uf      = 'PB';
      _gre     = '';
    }
  }

  Future<void> _saveForm() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    setState(() => _isSaving = true);

    final school = SchoolModel(
      id:      widget.existingSchool?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      inep:    _inep.replaceAll(' ', ''),
      name:    _name.trim(),
      address: _address.trim(),
      city:    _city.trim(),
      uf:      _uf.trim().toUpperCase(),
      gre:     _gre.trim(),
    );

    final service = SchoolService();
    if (_isEditing) {
      await service.updateSchool(school);
    } else {
      await service.addSchool(school);
    }

    if (mounted) Navigator.of(context).pop();
  }

  // ── Build helpers ──────────────────────────────────────────────────────────

  Widget _buildHeader(ColorScheme colorScheme, TextTheme textTheme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _isEditing
                  ? colorScheme.tertiaryContainer
                  : colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              _isEditing ? Icons.edit_note_rounded : Icons.add_business_rounded,
              size: 28,
              color: _isEditing
                  ? colorScheme.onTertiaryContainer
                  : colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isEditing ? 'Editar Escola' : 'Nova Escola',
                  style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Preencha os dados cadastrais da unidade escolar',
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _isEditing
                        ? colorScheme.tertiaryContainer
                        : colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _isEditing ? 'Modo edição' : 'Novo cadastro',
                    style: textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: _isEditing
                          ? colorScheme.onTertiaryContainer
                          : colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormCard(ColorScheme colorScheme) {
    return SectionCard(
      title: 'Identificação',
      child: Column(
        children: [
          // INEP
          TextFormField(
            initialValue: _inep,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(8),
            ],
            decoration: InputDecoration(
              labelText: 'Código INEP *',
              hintText: 'Ex: 25001234',
              prefixIcon: const Icon(Icons.tag_rounded),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              helperText: '8 dígitos numéricos',
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) {
                return 'O código INEP é obrigatório';
              }
              final service = SchoolService();
              final exists = service.schools.any((s) =>
                  s.inep == v.trim() &&
                  (!_isEditing || s.id != widget.existingSchool!.id));
              if (exists) return 'Este INEP já está cadastrado';
              return null;
            },
            onSaved: (v) => _inep = v!.trim().replaceAll(' ', ''),
          ),
          const SizedBox(height: 16),
          // Nome
          TextFormField(
            initialValue: _name,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Nome da Escola *',
              hintText: 'Ex: E.E. Prof. Fulano de Tal',
              prefixIcon: const Icon(Icons.school_outlined),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'O nome é obrigatório' : null,
            onSaved: (v) => _name = v!.trim(),
          ),
        ],
      ),
    );
  }

  Widget _buildLocationFields(ColorScheme colorScheme) {
    return SectionCard(
      title: 'Localização',
      child: Column(
        children: [
          // Endereço
          TextFormField(
            initialValue: _address,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: 'Endereço completo *',
              hintText: 'Rua, nº, bairro',
              prefixIcon: const Icon(Icons.location_on_outlined),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'O endereço é obrigatório' : null,
            onSaved: (v) => _address = v!.trim(),
          ),
          const SizedBox(height: 16),
          // Município + UF
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('city_$_city'),
                  initialValue: Constants.paraibaMunicipalities.contains(_city)
                      ? _city
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Município *',
                    prefixIcon: const Icon(Icons.location_city_outlined),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  items: Constants.paraibaMunicipalities
                      .map((m) => DropdownMenuItem(
                          value: m,
                          child: Text(m, overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (v) => setState(() => _city = v ?? ''),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Selecione o município' : null,
                  onSaved: (v) => _city = v!.trim(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 1,
                child: TextFormField(
                  initialValue: _uf,
                  textCapitalization: TextCapitalization.characters,
                  maxLength: 2,
                  decoration: InputDecoration(
                    labelText: 'UF *',
                    counterText: '',
                    prefixIcon: const Icon(Icons.map_outlined),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Obrigatório' : null,
                  onSaved: (v) => _uf = v!.trim().toUpperCase(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // GRE
          DropdownButtonFormField<String>(
            key: ValueKey('gre_$_gre'),
            initialValue: Constants.regionals.contains(_gre) ? _gre : null,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Regional de Ensino (GRE) *',
              prefixIcon: const Icon(Icons.account_balance_outlined),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            items: Constants.regionals
                .map((r) => DropdownMenuItem(
                    value: r, child: Text(r, overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: (v) => setState(() => _gre = v ?? ''),
            validator: (v) =>
                (v == null || v.isEmpty) ? 'Selecione a regional' : null,
            onSaved: (v) => _gre = v!.trim(),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton(ColorScheme colorScheme) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton.icon(
        onPressed: _isSaving ? null : _saveForm,
        icon: _isSaving
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: colorScheme.onPrimary),
              )
            : Icon(_isEditing ? Icons.save_rounded : Icons.add_rounded),
        label: Text(
          _isSaving
              ? 'Salvando...'
              : _isEditing
                  ? 'Salvar alterações'
                  : 'Cadastrar escola',
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
        title: Text(
          _isEditing ? 'Editar Escola' : 'Nova Escola',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeader(colorScheme, textTheme),
                  _buildFormCard(colorScheme),
                  _buildLocationFields(colorScheme),
                  _buildSubmitButton(colorScheme),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      '* Campos obrigatórios',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
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
