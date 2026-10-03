import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/technician_model.dart';
import '../services/technician_service.dart';
import 'technician_form_screen.dart';
import '../widgets/app_ui.dart';

class TechnicianListScreen extends StatefulWidget {
  const TechnicianListScreen({super.key});

  @override
  State<TechnicianListScreen> createState() => _TechnicianListScreenState();
}

class _TechnicianListScreenState extends State<TechnicianListScreen> {
  final TechnicianService _technicianService = TechnicianService();
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  String _normalize(String? value) {
    if (value == null) return '';
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[áàâãä]'), 'a')
        .replaceAll(RegExp(r'[éèêë]'), 'e')
        .replaceAll(RegExp(r'[íìîï]'), 'i')
        .replaceAll(RegExp(r'[óòôõö]'), 'o')
        .replaceAll(RegExp(r'[úùûü]'), 'u')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'\s+'), ' ');
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _refreshList() {
    setState(() {});
  }

  void _deleteTechnician(TechnicianModel tech) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => ConfirmDeleteDialog(
        title: 'Excluir Técnico',
        message: 'Você está prestes a remover o cadastro de:\n\n${tech.name}\n\nEsta ação não pode ser desfeita e removerá o acesso do usuário.',
      ),
    );

    if (confirm == true) {
      await _technicianService.deleteTechnician(tech.id);
      _refreshList();
    }
  }

  void _openForm([TechnicianModel? technician]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (ctx) => TechnicianFormScreen(existingTechnician: technician)),
    );
    _refreshList();
  }

  Widget _buildFilterCard(ColorScheme colorScheme, int totalCount) {
    final showHeaderButton = MediaQuery.of(context).size.width > 700;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.people_alt_rounded, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Técnicos e Usuários',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                        ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$totalCount cadastrados',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                if (showHeaderButton) ...[
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _openForm(),
                    icon: const Icon(Icons.person_add_rounded, size: 18),
                    label: const Text('Adicionar'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            AppSearchField(
              controller: _searchController,
              label: 'Buscar técnico',
              hint: 'Nome, matrícula, e-mail ou permissão',
              onChanged: (v) => setState(() => _searchQuery = v),
              onClear: () {
                setState(() {
                  _searchQuery = '';
                  _searchController.clear();
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPermissionChip(String permission, ColorScheme colorScheme, TextTheme textTheme) {
    Color color;
    Color bgColor;
    String label;
    IconData icon;

    switch (permission) {
      case 'ADM':
        color = colorScheme.error;
        bgColor = colorScheme.errorContainer.withValues(alpha: 0.5);
        label = 'Administrador';
        icon = Icons.admin_panel_settings_rounded;
        break;
      case 'OPE':
        color = colorScheme.tertiary;
        bgColor = colorScheme.tertiaryContainer.withValues(alpha: 0.5);
        label = 'Operador';
        icon = Icons.manage_accounts_rounded;
        break;
      default:
        color = colorScheme.primary;
        bgColor = colorScheme.primaryContainer.withValues(alpha: 0.5);
        label = 'Usuário';
        icon = Icons.person_rounded;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTechInfoChip({
    required IconData icon,
    required String label,
    required Color color,
    required Color backgroundColor,
    double maxWidth = 220,
  }) {
    final textTheme = Theme.of(context).textTheme;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTechCard(TechnicianModel tech, bool isLargeScreen, ColorScheme colorScheme, TextTheme textTheme) {
    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: colorScheme.secondaryContainer,
              backgroundImage: tech.photoPath != null && tech.photoPath!.isNotEmpty
                  ? (tech.photoPath!.length > 500
                      ? MemoryImage(base64Decode(tech.photoPath!))
                      : (kIsWeb ? NetworkImage(tech.photoPath!) : FileImage(File(tech.photoPath!)))) as ImageProvider
                  : null,
              child: (tech.photoPath == null || tech.photoPath!.isEmpty)
                  ? Icon(Icons.person_rounded, size: 30, color: colorScheme.onSecondaryContainer)
                  : null,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tech.name,
                    style: textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _buildPermissionChip(tech.permissions, colorScheme, textTheme),
                      _buildTechInfoChip(
                        icon: Icons.badge_outlined,
                        label: tech.registration.isNotEmpty
                            ? 'Matrícula ${tech.registration}'
                            : 'Sem matrícula',
                        color: colorScheme.primary,
                        backgroundColor:
                            colorScheme.primaryContainer.withValues(alpha: 0.45),
                      ),
                      _buildTechInfoChip(
                        icon: Icons.email_outlined,
                        label: tech.email.isNotEmpty ? tech.email : 'Sem e-mail',
                        color: colorScheme.onSurfaceVariant,
                        backgroundColor: colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.55),
                        maxWidth: isLargeScreen ? 260 : 210,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isLargeScreen)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: 'Editar',
                    child: IconButton(
                      icon: Icon(Icons.edit_outlined, color: colorScheme.primary),
                      onPressed: () => _openForm(tech),
                    ),
                  ),
                  Tooltip(
                    message: 'Excluir',
                    child: IconButton(
                      icon: Icon(Icons.delete_outline_rounded, color: colorScheme.error),
                      onPressed: () => _deleteTechnician(tech),
                    ),
                  ),
                ],
              )
            else
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert_rounded, color: colorScheme.onSurfaceVariant),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                onSelected: (value) {
                  if (value == 'edit') _openForm(tech);
                  if (value == 'delete') _deleteTechnician(tech);
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Row(children: [
                      Icon(Icons.edit_outlined, size: 18, color: colorScheme.primary),
                      const SizedBox(width: 10),
                      const Text('Editar'),
                    ]),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(children: [
                      Icon(Icons.delete_outline_rounded, size: 18, color: colorScheme.error),
                      const SizedBox(width: 10),
                      Text('Excluir', style: TextStyle(color: colorScheme.error)),
                    ]),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final screenWidth = MediaQuery.of(context).size.width;
    final isLargeScreen = screenWidth > 700;
    final useGrid = screenWidth >= 1040;

    final allTechs = _technicianService.technicians;
    final query = _normalize(_searchQuery);
    final techs = allTechs.where((t) {
      if (query.isEmpty) return true;
      return _normalize(t.name).contains(query) ||
          _normalize(t.registration).contains(query) ||
          _normalize(t.email).contains(query) ||
          _normalize(t.permissions).contains(query);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Gerenciar Técnicos', style: TextStyle(fontWeight: FontWeight.w600)),
            Text('Controle de Usuários e Permissões',
                style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Column(
            children: [
              _buildFilterCard(colorScheme, allTechs.length),
              Expanded(
                child: techs.isEmpty
                    ? EmptyState(
                        icon: _searchQuery.isNotEmpty ? Icons.search_off_rounded : Icons.people_outline,
                        title: 'Nenhum técnico encontrado',
                        message: _searchQuery.isNotEmpty
                            ? 'Nenhum usuário corresponde aos critérios de busca.'
                            : 'Ainda não há técnicos cadastrados no sistema.',
                        actionLabel: _searchQuery.isEmpty ? 'Novo Técnico' : null,
                        actionIcon: Icons.person_add_rounded,
                        onAction: _searchQuery.isEmpty ? () => _openForm() : null,
                      )
                    : useGrid
                        ? GridView.builder(
                            padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisExtent: 176,
                              crossAxisSpacing: 4,
                              mainAxisSpacing: 4,
                            ),
                            itemCount: techs.length,
                            itemBuilder: (ctx, index) {
                              return _buildTechCard(techs[index], isLargeScreen,
                                  colorScheme, textTheme);
                            },
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.only(bottom: 96, top: 4),
                            itemCount: techs.length,
                            itemBuilder: (ctx, index) {
                              return _buildTechCard(techs[index], isLargeScreen,
                                  colorScheme, textTheme);
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: isLargeScreen
          ? FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.person_add_rounded),
              label: const Text('Novo Técnico', style: TextStyle(fontWeight: FontWeight.w600)),
            )
          : FloatingActionButton(
              onPressed: () => _openForm(),
              child: const Icon(Icons.person_add_rounded),
            ),
    );
  }
}
