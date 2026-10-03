import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/school_model.dart';
import '../services/school_service.dart';
import 'school_form_screen.dart';
import '../widgets/app_ui.dart';

class SchoolListScreen extends StatefulWidget {
  const SchoolListScreen({super.key});

  @override
  State<SchoolListScreen> createState() => _SchoolListScreenState();
}

class _SchoolListScreenState extends State<SchoolListScreen> {
  final SchoolService _schoolService = SchoolService();

  String? _filterRegional;
  String? _filterCity;
  String _searchQuery = '';
  String _userPermission = 'USR';

  bool _isLoading = true;
  String? _loadError;
  List<SchoolModel> _schools = [];

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
  void initState() {
    super.initState();
    _loadPermission();
    _loadSchools();
  }

  Future<void> _loadSchools() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      await _schoolService.loadSchools(forceRefresh: true);
      if (!mounted) return;
      setState(() {
        _schools = List<SchoolModel>.from(_schoolService.schools);
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Erro ao carregar escolas: $e');
      if (!mounted) return;
      setState(() {
        _schools = List<SchoolModel>.from(_schoolService.schools);
        _isLoading = false;
        _loadError = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPermission() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _userPermission = prefs.getString('logged_user_permission') ?? 'USR';
      });
    }
  }

  void _refreshList() => setState(() {});

  bool get _hasActiveFilters =>
      _searchQuery.isNotEmpty || _filterRegional != null || _filterCity != null;

  void _clearFilters() {
    setState(() {
      _searchQuery = '';
      _filterRegional = null;
      _filterCity = null;
      _searchController.clear();
    });
  }

  void _deleteSchool(SchoolModel school) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => ConfirmDeleteDialog(
        title: 'Excluir Escola',
        message: 'Você está prestes a excluir a escola:\n\n${school.name}\n\nEsta ação não pode ser desfeita.',
      ),
    );

    if (confirm == true) {
      await _schoolService.deleteSchool(school.id);
      _refreshList();
    }
  }

  void _openForm([SchoolModel? school]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (ctx) => SchoolFormScreen(existingSchool: school)),
    );
    await _loadSchools();
  }

  void _openMapRoute(SchoolModel school) async {
    final query = Uri.encodeComponent(
        '${school.name}, INEP ${school.inep}, ${school.address}, ${school.city} - ${school.uf}');
    final url =
        Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$query');

    try {
      bool launched = false;
      try {
        launched = await launchUrl(url, mode: LaunchMode.externalApplication);
      } catch (_) {}
      
      if (!launched) {
        await launchUrl(url); // Fallback padrão seguro para a plataforma
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não foi possível abrir o Google Maps.')),
        );
      }
    }
  }

  List<SchoolModel> get _schoolsByRegional {
    if (_filterRegional == null || _filterRegional!.trim().isEmpty) {
      return _schools;
    }
    final reg = _normalize(_filterRegional);
    return _schools.where((s) => _normalize(s.gre) == reg).toList();
  }

  List<String> get _availableRegionals {
    final set = <String>{};
    for (final s in _schools) {
      final gre = s.gre.trim();
      if (gre.isNotEmpty) set.add(gre);
    }
    final list = set.toList();
    list.sort((a, b) => _normalize(a).compareTo(_normalize(b)));
    return list;
  }

  List<String> get _availableCities {
    final source = _schoolsByRegional;
    final set = <String>{};
    for (final s in source) {
      final city = s.city.trim();
      if (city.isNotEmpty) set.add(city);
    }
    final list = set.toList();
    list.sort((a, b) => _normalize(a).compareTo(_normalize(b)));
    return list;
  }

  List<SchoolModel> get _filteredSchools {
    final q = _normalize(_searchQuery);
    final selectedReg = _normalize(_filterRegional);
    final selectedCity = _normalize(_filterCity);

    final result = _schools.where((s) {
      final matchesRegional = selectedReg.isEmpty || _normalize(s.gre) == selectedReg;
      final matchesCity = selectedCity.isEmpty || _normalize(s.city) == selectedCity;
      final matchesSearch = q.isEmpty ||
          _normalize(s.name).contains(q) ||
          _normalize(s.inep).contains(q) ||
          _normalize(s.city).contains(q) ||
          _normalize(s.gre).contains(q);

      return matchesRegional && matchesCity && matchesSearch;
    }).toList();

    result.sort((a, b) {
      final greCompare = _normalize(a.gre).compareTo(_normalize(b.gre));
      if (greCompare != 0) return greCompare;

      final cityCompare = _normalize(a.city).compareTo(_normalize(b.city));
      if (cityCompare != 0) return cityCompare;

      return _normalize(a.name).compareTo(_normalize(b.name));
    });

    return result;
  }

  // ── Build helpers ──────────────────────────────────────────────────────────

  Widget _buildFilterCard(bool isLargeScreen, ColorScheme colorScheme) {
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
            // Header row
            Row(
              children: [
                Icon(Icons.school_rounded, size: 18, color: colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Escolas cadastradas',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                        ),
                  ),
                ),
                if (_hasActiveFilters)
                  TextButton.icon(
                    onPressed: _clearFilters,
                    icon: const Icon(Icons.filter_alt_off_rounded, size: 16),
                    label: const Text('Limpar filtros'),
                    style: TextButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                if (isLargeScreen) ...[
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => _openForm(),
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Adicionar'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Gerencie as unidades escolares da rede estadual',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 16),
            // Search bar
            AppSearchField(
              controller: _searchController,
              label: 'Buscar escola',
              hint: 'Nome, INEP, município ou GRE',
              onChanged: (v) => setState(() => _searchQuery = v),
              onClear: () {
                setState(() {
                  _searchQuery = '';
                  _searchController.clear();
                });
              },
            ),
            const SizedBox(height: 12),
            // Filters
            if (isLargeScreen)
              Row(
                children: [
                  Expanded(child: _buildRegionalDropdown(colorScheme)),
                  const SizedBox(width: 12),
                  Expanded(child: _buildCityDropdown(colorScheme)),
                ],
              )
            else ...[
              _buildRegionalDropdown(colorScheme),
              const SizedBox(height: 12),
              _buildCityDropdown(colorScheme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRegionalDropdown(ColorScheme colorScheme) {
    final regionals = _availableRegionals;
    final regionalValue = regionals.any((r) => _normalize(r) == _normalize(_filterRegional)) ? _filterRegional : null;

    return DropdownButtonFormField<String>(
      key: ValueKey('regional_$_filterRegional'),
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Regional (GRE)',
        prefixIcon: const Icon(Icons.map_outlined),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      initialValue: regionalValue,
      items: [
        const DropdownMenuItem(value: null, child: Text('Todas as Regionais')),
        ...regionals.map((r) =>
            DropdownMenuItem(value: r, child: Text(r, overflow: TextOverflow.ellipsis))),
      ],
      onChanged: (v) => setState(() {
        _filterRegional = v;
        _filterCity = null;
      }),
    );
  }

  Widget _buildCityDropdown(ColorScheme colorScheme) {
    final cities = _availableCities;
    final cityValue = cities.any((c) => _normalize(c) == _normalize(_filterCity)) ? _filterCity : null;

    return DropdownButtonFormField<String>(
      key: ValueKey('city_${_filterRegional}_$_filterCity'),
      isExpanded: true,
      decoration: InputDecoration(
        labelText: 'Município',
        prefixIcon: const Icon(Icons.location_city_outlined),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      initialValue: cityValue,
      items: [
        const DropdownMenuItem(value: null, child: Text('Todos os Municípios')),
        ...cities.map((c) => DropdownMenuItem(
                value: c, child: Text(c, overflow: TextOverflow.ellipsis))),
      ],
      onChanged: (v) => setState(() => _filterCity = v),
    );
  }

  Widget _buildSchoolCard(SchoolModel school, bool isLargeScreen,
      ColorScheme colorScheme) {
    final textTheme = Theme.of(context).textTheme;

    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Avatar
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.school_rounded, color: colorScheme.onPrimaryContainer, size: 26),
            ),
            const SizedBox(width: 14),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // School name
                  Text(
                    school.name,
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Chips row
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      InfoChip(
                        label: 'INEP ${school.inep}',
                        icon: Icons.tag_rounded,
                        color: colorScheme.primary,
                        backgroundColor: colorScheme.primaryContainer.withValues(alpha: 0.5),
                      ),
                      InfoChip(
                        label: '${school.city} / ${school.uf}',
                        icon: Icons.location_on_outlined,
                        color: colorScheme.secondary,
                        backgroundColor: colorScheme.secondaryContainer.withValues(alpha: 0.5),
                      ),
                      InfoChip(
                        label: school.gre,
                        icon: Icons.account_balance_outlined,
                        color: colorScheme.tertiary,
                        backgroundColor: colorScheme.tertiaryContainer.withValues(alpha: 0.5),
                      ),
                    ],
                  ),
                  // Address
                  if (school.address.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.place_outlined,
                            size: 13, color: colorScheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            school.address,
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            // Actions
            if (isLargeScreen)
              _buildLargeScreenActions(school, colorScheme)
            else
              _buildPopupMenu(school, colorScheme),
          ],
        ),
      ),
    );
  }



  Widget _buildLargeScreenActions(SchoolModel school, ColorScheme colorScheme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _actionIconButton(
          icon: Icons.directions_rounded,
          tooltip: 'Traçar percurso',
          color: colorScheme.tertiary,
          onPressed: () => _openMapRoute(school),
        ),
        _actionIconButton(
          icon: Icons.edit_outlined,
          tooltip: 'Editar escola',
          color: colorScheme.primary,
          onPressed: () => _openForm(school),
        ),
        if (_userPermission == 'ADM')
          _actionIconButton(
            icon: Icons.delete_outline_rounded,
            tooltip: 'Excluir',
            color: colorScheme.error,
            onPressed: () => _deleteSchool(school),
          ),
      ],
    );
  }

  Widget _actionIconButton({
    required IconData icon,
    required String tooltip,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 20, color: color),
        ),
      ),
    );
  }

  Widget _buildPopupMenu(SchoolModel school, ColorScheme colorScheme) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert_rounded, color: colorScheme.onSurfaceVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (value) {
        if (value == 'route') _openMapRoute(school);
        if (value == 'edit') _openForm(school);
        if (value == 'delete') _deleteSchool(school);
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'route',
          child: Row(children: [
            Icon(Icons.directions_rounded, size: 18, color: colorScheme.tertiary),
            const SizedBox(width: 10),
            const Text('Traçar percurso'),
          ]),
        ),
        PopupMenuItem(
          value: 'edit',
          child: Row(children: [
            Icon(Icons.edit_outlined, size: 18, color: colorScheme.primary),
            const SizedBox(width: 10),
            const Text('Editar escola'),
          ]),
        ),
        if (_userPermission == 'ADM')
          PopupMenuItem(
            value: 'delete',
            child: Row(children: [
              Icon(Icons.delete_outline_rounded, size: 18, color: colorScheme.error),
              const SizedBox(width: 10),
              Text('Excluir', style: TextStyle(color: colorScheme.error)),
            ]),
          ),
      ],
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: colorScheme.primary),
            const SizedBox(height: 16),
            Text('Carregando escolas...', style: TextStyle(color: colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }

    if (_loadError != null && _schools.isEmpty) {
      return EmptyState(
        icon: Icons.error_outline_rounded,
        title: 'Não foi possível carregar as escolas',
        message: 'Ocorreu um erro ao buscar os dados:\n$_loadError',
        actionLabel: 'Tentar novamente',
        actionIcon: Icons.refresh_rounded,
        onAction: _loadSchools,
      );
    }

    final withFilters = _hasActiveFilters;
    return EmptyState(
      icon: withFilters ? Icons.search_off_rounded : Icons.school_outlined,
      title: 'Nenhuma escola encontrada',
      message: withFilters
          ? 'Nenhuma escola corresponde aos filtros aplicados. Tente ajustar a busca ou os filtros.'
          : 'Ainda não há escolas cadastradas no sistema. Comece cadastrando a primeira.',
      actionLabel: withFilters ? 'Limpar filtros' : 'Cadastrar escola',
      actionIcon: withFilters ? Icons.filter_alt_off_rounded : Icons.add_rounded,
      onAction: withFilters ? _clearFilters : () => _openForm(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final screenWidth = MediaQuery.of(context).size.width;
    final isLargeScreen = screenWidth > 700;
    final useGrid = screenWidth >= 1024;
    final schools = _filteredSchools;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Gerenciar Escolas',
                style: TextStyle(fontWeight: FontWeight.w700)),
            Text(
              'Catálogo da Rede Estadual',
              style: TextStyle(
                  fontSize: 12, color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadSchools,
            tooltip: 'Atualizar escolas',
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Column(
            children: [
          _buildFilterCard(isLargeScreen, colorScheme),
          // Results count
          if (!_isLoading && _loadError == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: Row(
                children: [
                  Text(
                    schools.isEmpty
                        ? 'Nenhum resultado de ${_schools.length} total'
                        : '${schools.length} de ${_schools.length} ${schools.length == 1 ? 'escola encontrada' : 'escolas encontradas'}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                  if (_filterRegional != null && _filterRegional!.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      '(${_availableCities.length} municípios disponíveis)',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ],
              ),
            ),
          Expanded(
            child: _isLoading || (_loadError != null && _schools.isEmpty) || schools.isEmpty
                ? _buildEmptyState(colorScheme)
                : useGrid
                    ? GridView.builder(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 96),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisExtent: 178,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                        ),
                        itemCount: schools.length,
                        itemBuilder: (ctx, index) {
                          return _buildSchoolCard(
                              schools[index], isLargeScreen, colorScheme);
                        },
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 96, top: 4),
                        itemCount: schools.length,
                        itemBuilder: (ctx, index) {
                          return _buildSchoolCard(
                              schools[index], isLargeScreen, colorScheme);
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
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nova escola',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            )
          : FloatingActionButton(
              onPressed: () => _openForm(),
              child: const Icon(Icons.add_rounded),
            ),
    );
  }
}
