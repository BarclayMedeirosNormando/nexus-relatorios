import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/technician_model.dart';
import '../models/employee_model.dart';
import '../services/technician_service.dart';
import '../services/employee_service.dart';
import '../widgets/app_ui.dart';

class TechnicianFormScreen extends StatefulWidget {
  final TechnicianModel? existingTechnician;

  const TechnicianFormScreen({super.key, this.existingTechnician});

  @override
  State<TechnicianFormScreen> createState() => _TechnicianFormScreenState();
}

class _TechnicianFormScreenState extends State<TechnicianFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late String _name;
  late String _registration;
  late String _email;
  late String _permissions;
  String? _photoPath;
  String _password = '';
  
  late TextEditingController _passwordController;
  late TextEditingController _registrationController;
  late TextEditingController _nameController;
  late TextEditingController _searchController;
  
  String _loggedUserPermission = 'USR';
  bool _obscurePassword = true;
  bool _isSaving = false;

  List<EmployeeModel> _searchResults = [];
  bool _employeeSelected = false;
  bool _isSearching = false;

  bool get _isEditing => widget.existingTechnician != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      _name = widget.existingTechnician!.name;
      _registration = widget.existingTechnician!.registration;
      _email = widget.existingTechnician!.email;
      _permissions = widget.existingTechnician!.permissions;
      _photoPath = widget.existingTechnician!.photoPath;
      _password = widget.existingTechnician!.password ?? '';
    } else {
      _name = '';
      _registration = '';
      _email = '';
      _permissions = 'USR';
      _password = '';
    }
    _passwordController = TextEditingController(text: _password);
    _registrationController = TextEditingController(text: _registration);
    _nameController = TextEditingController(text: _name);
    _searchController = TextEditingController();
    _loadUserPermission();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _registrationController.dispose();
    _nameController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadUserPermission() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _loggedUserPermission = prefs.getString('logged_user_permission') ?? 'USR';
      });
    }
  }

  void _searchEmployees(String query) {
    final q = query.trim();
    if (q.length < 2) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    final service = EmployeeService();
    List<EmployeeModel> results;

    if (RegExp(r'^\d+$').hasMatch(q)) {
      results = service.all
          .where((e) => e.matricula.startsWith(q))
          .take(15)
          .toList();
      results.sort((a, b) {
        if (a.matricula == q) return -1;
        if (b.matricula == q) return 1;
        return a.matricula.compareTo(b.matricula);
      });
    } else {
      results = service.searchByName(q).take(15).toList();
    }

    setState(() {
      _searchResults = results;
      _isSearching = results.isNotEmpty;
    });
  }

  void _selectEmployee(EmployeeModel emp) {
    setState(() {
      _registration = emp.matricula;
      _name = emp.name;
      _registrationController.text = emp.matricula;
      _nameController.text = emp.name;
      _searchController.clear();
      _searchResults = [];
      _isSearching = false;
      _employeeSelected = true;
    });
    FocusScope.of(context).unfocus();
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(
          source: source, imageQuality: 50, maxWidth: 300, maxHeight: 300);
      if (pickedFile != null) {
        final bytes = await pickedFile.readAsBytes();
        if (mounted) setState(() => _photoPath = base64Encode(bytes));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erro ao carregar foto: $e')));
      }
    }
  }

  void _saveForm() async {
    if (!_formKey.currentState!.validate()) return;
    _formKey.currentState!.save();

    setState(() => _isSaving = true);

    final tech = TechnicianModel(
      id: widget.existingTechnician?.id ?? DateTime.now().millisecondsSinceEpoch.toString(),
      name: _name.trim(),
      registration: _registration.trim(),
      email: _email.trim(),
      permissions: _permissions,
      photoPath: _photoPath,
      password: _password,
    );

    final service = TechnicianService();
    if (_isEditing) {
      await service.updateTechnician(tech);
    } else {
      await service.addTechnician(tech);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Técnico salvo com sucesso!')),
      );
      Navigator.of(context).pop();
    }
  }

  // ── Build Helpers ─────────────────────────────────────────────────────────

  Widget _buildPhotoSection(ColorScheme colorScheme, TextTheme textTheme) {
    return Center(
      child: Stack(
        alignment: Alignment.bottomRight,
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: colorScheme.primary, width: 3),
            ),
            child: CircleAvatar(
              radius: 56,
              backgroundColor: colorScheme.primaryContainer,
              backgroundImage: _photoPath != null && _photoPath!.isNotEmpty
                  ? (_photoPath!.length > 500
                      ? MemoryImage(base64Decode(_photoPath!))
                      : (kIsWeb ? NetworkImage(_photoPath!) : FileImage(File(_photoPath!)))) as ImageProvider
                  : null,
              child: (_photoPath == null || _photoPath!.isEmpty)
                  ? Icon(Icons.person_rounded, size: 56, color: colorScheme.onPrimaryContainer)
                  : null,
            ),
          ),
          Container(
            margin: const EdgeInsets.only(right: 4, bottom: 4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colorScheme.primary,
              border: Border.all(color: colorScheme.surface, width: 2),
            ),
            child: IconButton(
              icon: Icon(Icons.camera_alt_rounded, size: 20, color: colorScheme.onPrimary),
              constraints: const BoxConstraints(minHeight: 40, minWidth: 40),
              padding: EdgeInsets.zero,
              tooltip: 'Alterar foto',
              onPressed: () => _showPhotoOptions(colorScheme, textTheme),
            ),
          )
        ],
      ),
    );
  }

  void _showPhotoOptions(ColorScheme colorScheme, TextTheme textTheme) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                'Foto do Perfil',
                style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.camera_alt_outlined, color: colorScheme.onSecondaryContainer),
                ),
                title: const Text('Tirar foto com a câmera'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.photo_library_outlined, color: colorScheme.onSecondaryContainer),
                ),
                title: const Text('Escolher da galeria'),
                onTap: () {
                  Navigator.pop(ctx);
                  _pickImage(ImageSource.gallery);
                },
              ),
              if (_photoPath != null && _photoPath!.isNotEmpty)
                ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.delete_outline_rounded, color: colorScheme.error),
                  ),
                  title: Text('Remover foto', style: TextStyle(color: colorScheme.error)),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() => _photoPath = null);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmployeeSearchSection(ColorScheme colorScheme, TextTheme textTheme) {
    return SectionCard(
      title: 'Vincular à Base SEE/PB',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Busque um funcionário pelo nome ou matrícula para preencher os dados automaticamente.',
            style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              labelText: 'Buscar na Base de Servidores',
              hintText: 'Matrícula ou Nome...',
              prefixIcon: const Icon(Icons.person_search_rounded),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _searchResults = [];
                          _isSearching = false;
                        });
                      },
                    )
                  : null,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            ),
            onChanged: _searchEmployees,
          ),
          if (_isSearching && _searchResults.isNotEmpty)
            _buildEmployeeResultCard(colorScheme),
          if (_employeeSelected && _name.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colorScheme.primary.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.verified_rounded, color: colorScheme.primary, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Funcionário selecionado e vinculado.',
                      style: TextStyle(color: colorScheme.primary, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmployeeResultCard(ColorScheme colorScheme) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      constraints: const BoxConstraints(maxHeight: 250),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: colorScheme.onSurface.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              '${_searchResults.length} resultado(s) — toque para selecionar',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: colorScheme.primary),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _searchResults.length,
              separatorBuilder: (ctx, i) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final emp = _searchResults[i];
                return InkWell(
                  onTap: () => _selectEmployee(emp),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 18,
                          backgroundColor: colorScheme.primaryContainer,
                          child: Icon(Icons.badge_outlined, size: 18, color: colorScheme.onPrimaryContainer),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                emp.name,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Matrícula: ${emp.matricula}',
                                style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, size: 20, color: colorScheme.onSurfaceVariant),
                      ],
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

  Widget _buildIdentificationSection(ColorScheme colorScheme, TextTheme textTheme) {
    return SectionCard(
      title: 'Identificação',
      child: Column(
        children: [
          TextFormField(
            controller: _registrationController,
            decoration: InputDecoration(
              labelText: 'Matrícula *',
              prefixIcon: const Icon(Icons.badge_outlined),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            keyboardType: TextInputType.number,
            onChanged: (v) {
              _registration = v;
              setState(() => _employeeSelected = false);
            },
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'A matrícula é obrigatória';
              final service = TechnicianService();
              final exists = service.technicians.any((t) =>
                  t.registration == v.trim() &&
                  (!_isEditing || t.id != widget.existingTechnician!.id));
              if (exists) return 'Esta matrícula já está cadastrada no sistema';
              return null;
            },
            onSaved: (v) => _registration = v?.trim() ?? '',
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: 'Nome do Técnico *',
              prefixIcon: const Icon(Icons.person_outline_rounded),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            textCapitalization: TextCapitalization.words,
            validator: (v) => v == null || v.trim().isEmpty ? 'O nome é obrigatório' : null,
            onChanged: (v) {
              _name = v;
              setState(() => _employeeSelected = false);
            },
            onSaved: (v) => _name = v?.trim() ?? '',
          ),
          const SizedBox(height: 16),
          TextFormField(
            initialValue: _email,
            decoration: InputDecoration(
              labelText: 'Email Corporativo',
              prefixIcon: const Icon(Icons.email_outlined),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            keyboardType: TextInputType.emailAddress,
            validator: (v) {
              if (v != null && v.trim().isNotEmpty) {
                final emailRegex = RegExp(r'^[^@]+@[^@]+\.[^@]+');
                if (!emailRegex.hasMatch(v.trim())) {
                  return 'Insira um e-mail válido';
                }
              }
              return null;
            },
            onSaved: (v) => _email = v?.trim() ?? '',
          ),
        ],
      ),
    );
  }

  Widget _buildAccessSection(ColorScheme colorScheme, TextTheme textTheme) {
    return SectionCard(
      title: 'Acesso e Permissões',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: ValueKey('perm_$_permissions'),
            initialValue: _permissions,
            decoration: InputDecoration(
              labelText: 'Nível de Permissão *',
              prefixIcon: const Icon(Icons.security_outlined),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              helperText: _getPermissionHelperText(),
            ),
            items: [
              DropdownMenuItem(
                value: 'ADM',
                child: Row(children: [
                  Icon(Icons.admin_panel_settings_rounded, size: 20, color: colorScheme.error),
                  const SizedBox(width: 8),
                  const Text('Administrador')
                ])
              ),
              DropdownMenuItem(
                value: 'OPE',
                child: Row(children: [
                  Icon(Icons.manage_accounts_rounded, size: 20, color: colorScheme.tertiary),
                  const SizedBox(width: 8),
                  const Text('Operador')
                ])
              ),
              DropdownMenuItem(
                value: 'USR',
                child: Row(children: [
                  Icon(Icons.person_rounded, size: 20, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  const Text('Usuário Comum')
                ])
              ),
            ],
            onChanged: (v) => setState(() => _permissions = v!),
            onSaved: (v) => _permissions = v!,
          ),
          const SizedBox(height: 24),
          TextFormField(
            controller: _passwordController,
            decoration: InputDecoration(
              labelText: 'Senha de Acesso',
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                tooltip: _obscurePassword ? 'Mostrar senha' : 'Ocultar senha',
              ),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            obscureText: _obscurePassword,
            onSaved: (v) => _password = v ?? '',
          ),
          if (_loggedUserPermission == 'ADM') ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: () {
                  setState(() {
                    _passwordController.text = '123456';
                    _password = '123456';
                  });
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('Senha alterada para 123456. Salve para aplicar.'),
                      backgroundColor: colorScheme.primary,
                      behavior: SnackBarBehavior.floating,
                    ),
                  );
                },
                icon: const Icon(Icons.lock_reset_rounded, size: 18),
                label: const Text('Resetar Senha para 123456'),
              ),
            ),
          ]
        ],
      ),
    );
  }

  String _getPermissionHelperText() {
    switch (_permissions) {
      case 'ADM':
        return 'Acesso total ao sistema, incluindo exclusão de registros.';
      case 'OPE':
        return 'Pode cadastrar e editar dados, mas não pode excluir.';
      case 'USR':
        return 'Acesso básico, pode visualizar relatórios e realizar visitas.';
      default:
        return '';
    }
  }

  Widget _buildSubmitButton() {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: FilledButton.icon(
        onPressed: _isSaving ? null : _saveForm,
        icon: _isSaving
            ? Builder(builder: (ctx) {
                final cs = Theme.of(ctx).colorScheme;
                return SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: cs.onPrimary),
                );
              })
            : Icon(_isEditing ? Icons.save_rounded : Icons.person_add_rounded),
        label: Text(
          _isSaving
              ? 'Salvando...'
              : _isEditing
                  ? 'Salvar alterações'
                  : 'Cadastrar técnico',
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
          _isEditing ? 'Editar Técnico' : 'Novo Técnico',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildPhotoSection(colorScheme, textTheme),
                  const SizedBox(height: 32),
                  _buildEmployeeSearchSection(colorScheme, textTheme),
                  _buildIdentificationSection(colorScheme, textTheme),
                  _buildAccessSection(colorScheme, textTheme),
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
