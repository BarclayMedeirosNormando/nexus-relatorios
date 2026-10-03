import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/google_sheets_service.dart';
import '../widgets/app_ui.dart';

class SyncPendingScreen extends StatefulWidget {
  final Future<void> Function()? onSyncNow;

  const SyncPendingScreen({
    super.key,
    this.onSyncNow,
  });

  @override
  State<SyncPendingScreen> createState() => _SyncPendingScreenState();
}

class _SyncPendingScreenState extends State<SyncPendingScreen> {
  final GoogleSheetsService _sheetsService = GoogleSheetsService();
  final DateFormat _dateFormat = DateFormat('dd/MM/yyyy HH:mm');

  bool _isLoading = true;
  bool _isSyncing = false;
  String? _errorMessage;
  List<PendingSyncItem> _items = [];

  @override
  void initState() {
    super.initState();
    _loadPendingItems();
  }

  Future<void> _loadPendingItems() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final items = await _sheetsService.getPendingSyncItems();
      if (!mounted) return;
      setState(() {
        _items = items;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items = [];
        _isLoading = false;
        _errorMessage = 'Não foi possível carregar as pendências.';
      });
    }
  }

  Future<void> _syncNow() async {
    if (_isSyncing) return;

    setState(() => _isSyncing = true);
    try {
      if (widget.onSyncNow != null) {
        await widget.onSyncNow!();
      } else {
        await _sheetsService.syncOfflineData();
      }
      await _loadPendingItems();
    } finally {
      if (mounted) {
        setState(() => _isSyncing = false);
      }
    }
  }

  Color _actionColor(PendingSyncItem item, ColorScheme colorScheme) {
    switch (item.actionLabel) {
      case 'Criar':
        return Colors.green.shade700;
      case 'Excluir':
        return colorScheme.error;
      default:
        return colorScheme.primary;
    }
  }

  IconData _actionIcon(PendingSyncItem item) {
    switch (item.actionLabel) {
      case 'Criar':
        return Icons.add_circle_outline_rounded;
      case 'Excluir':
        return Icons.delete_outline_rounded;
      default:
        return Icons.edit_outlined;
    }
  }

  Widget _buildPendingCard(PendingSyncItem item) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final actionColor = _actionColor(item, colorScheme);
    final queuedAtLabel = item.queuedAt == null
        ? 'Data não registrada'
        : _dateFormat.format(item.queuedAt!);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      color: colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: actionColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(_actionIcon(item), color: actionColor, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      InfoChip(
                        label: item.actionLabel,
                        icon: _actionIcon(item),
                        color: actionColor,
                        backgroundColor: actionColor.withValues(alpha: 0.10),
                      ),
                      InfoChip(
                        label: item.status,
                        icon: Icons.pending_actions_rounded,
                        color: Colors.amber.shade800,
                        backgroundColor: Colors.amber.withValues(alpha: 0.14),
                      ),
                      InfoChip(
                        label: item.entityType,
                        icon: Icons.cloud_upload_outlined,
                        color: colorScheme.onSurfaceVariant,
                        backgroundColor: colorScheme.surfaceContainerHighest,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    item.title,
                    style: textTheme.titleMedium?.copyWith(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w800,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      _buildDetail(
                        Icons.confirmation_number_outlined,
                        item.entityType == 'Relatório'
                            ? 'Relatório ${item.reportNumber}'
                            : 'ID ${item.id}',
                      ),
                      _buildDetail(Icons.schedule_rounded, queuedAtLabel),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetail(IconData icon, String label) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 5),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    final colorScheme = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              'Carregando pendências...',
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null) {
      return EmptyState(
        icon: Icons.error_outline_rounded,
        title: _errorMessage!,
        message: 'Tente atualizar a lista novamente.',
        actionLabel: 'Atualizar',
        actionIcon: Icons.refresh_rounded,
        onAction: _loadPendingItems,
      );
    }

    if (_items.isEmpty) {
      return EmptyState(
        icon: Icons.cloud_done_outlined,
        title: 'Nenhuma pendência de sincronização.',
        message: 'Tudo que estava na fila já foi enviado.',
      );
    }

    return RefreshIndicator(
      onRefresh: _loadPendingItems,
      child: ListView.builder(
        padding: const EdgeInsets.only(top: 10, bottom: 24),
        itemCount: _items.length,
        itemBuilder: (context, index) => _buildPendingCard(_items[index]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasItems = _items.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Pendências de Sincronização',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            children: [
              if (hasItems)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${_items.length} ${_items.length == 1 ? 'item pendente' : 'itens pendentes'}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                ),
              Expanded(child: _buildBody()),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isSyncing
                              ? null
                              : () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.arrow_back_rounded),
                          label: const Text('Voltar'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: PrimaryActionButton(
                          onPressed: hasItems ? _syncNow : null,
                          label: 'Sincronizar agora',
                          icon: Icons.sync_rounded,
                          isLoading: _isSyncing,
                          height: 48,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
