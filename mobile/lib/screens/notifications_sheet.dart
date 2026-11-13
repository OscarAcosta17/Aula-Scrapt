import 'package:flutter/material.dart';
import '../services/settings_service.dart';

/// Abre el Centro de Notificaciones in-app con historial unificado de Moodle y WorkManager.
Future<void> showNotificationsSheet(
  BuildContext context, {
  required SettingsService settingsService,
}) async {
  await settingsService.reloadNotifications();
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => _NotificationsSheet(settingsService: settingsService),
  );
  await settingsService.markAllNotificationsRead();
}

class _NotificationsSheet extends StatefulWidget {
  final SettingsService settingsService;

  const _NotificationsSheet({required this.settingsService});

  @override
  State<_NotificationsSheet> createState() => _NotificationsSheetState();
}

class _NotificationsSheetState extends State<_NotificationsSheet> {
  bool _hasPermission = true;

  @override
  void initState() {
    super.initState();
    _checkPerm();
  }

  Future<void> _checkPerm() async {
    final granted = await widget.settingsService.hasNotificationPermission();
    if (mounted) setState(() => _hasPermission = granted);
  }

  Future<void> _requestPerm() async {
    final granted = await widget.settingsService.requestNotificationPermission();
    if (mounted) setState(() => _hasPermission = granted);
  }

  IconData _iconForKind(String kind) {
    switch (kind) {
      case 'deadline':
        return Icons.alarm_on_rounded;
      case 'new_file':
        return Icons.library_add_rounded;
      case 'download':
        return Icons.download_done_rounded;
      case 'update':
        return Icons.system_update_rounded;
      default:
        return Icons.notifications_active_rounded;
    }
  }

  Color _accentForKind(ColorScheme cs, String kind) {
    switch (kind) {
      case 'deadline':
        return cs.error;
      case 'new_file':
        return cs.primary;
      case 'download':
        return cs.tertiary;
      case 'update':
        return cs.secondary;
      default:
        return cs.primary;
    }
  }

  String _formatRelativeTime(int timestampSec) {
    if (timestampSec <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampSec * 1000).toLocal();
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Ahora';
    if (diff.inMinutes < 60) return 'Hace ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'Hace ${diff.inHours} h';
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return ValueListenableBuilder<int>(
      valueListenable: widget.settingsService.notificationsNotifier,
      builder: (context, _, _) {
        final items = widget.settingsService.notifications;
        final unread = widget.settingsService.unreadNotificationsCount;

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          minChildSize: 0.45,
          maxChildSize: 0.94,
          builder: (context, scrollController) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 12, 10),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.notifications_rounded,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Centro de avisos',
                            style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            unread > 0
                                ? '$unread sin leer • ${items.length} recientes'
                                : '${items.length} avisos recientes',
                            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    if (items.isNotEmpty)
                      TextButton.icon(
                        onPressed: () async {
                          await widget.settingsService.clearNotifications();
                        },
                        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                        label: const Text('Limpiar'),
                      ),
                  ],
                ),
              ),
              if (!_hasPermission)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Card(
                    color: cs.tertiaryContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(
                            Icons.notifications_off_outlined,
                            color: cs.onTertiaryContainer,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Activa el permiso de notificaciones para recibir alertas en segundo plano.',
                              style: tt.bodySmall?.copyWith(color: cs.onTertiaryContainer),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.tonal(
                            onPressed: _requestPerm,
                            child: const Text('Activar'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.35)),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.notifications_none_rounded,
                                size: 46,
                                color: cs.outline,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                'Sin novedades por ahora',
                                style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Aquí aparecerán archivos nuevos, entregas próximas (< 48h) y descargas completadas.',
                                textAlign: TextAlign.center,
                                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final n = items[index];
                          final kind = (n['kind'] ?? 'info').toString();
                          final isUnread = n['read'] != true;
                          final accent = _accentForKind(cs, kind);
                          final ts = (n['created_at'] as num?)?.toInt() ?? 0;

                          return Card(
                            color: isUnread
                                ? cs.surfaceContainerHigh
                                : cs.surfaceContainerLow,
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: accent.withValues(alpha: 0.16),
                                foregroundColor: accent,
                                child: Icon(_iconForKind(kind), size: 20),
                              ),
                              title: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      (n['title'] ?? '').toString(),
                                      style: tt.titleSmall?.copyWith(
                                        fontWeight: isUnread ? FontWeight.w700 : FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  if (isUnread)
                                    Container(
                                      width: 8,
                                      height: 8,
                                      margin: const EdgeInsets.only(left: 6),
                                      decoration: BoxDecoration(
                                        color: cs.primary,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                ],
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if ((n['body'] ?? '').toString().isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        (n['body'] ?? '').toString(),
                                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                                      ),
                                    ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _formatRelativeTime(ts),
                                    style: tt.labelSmall?.copyWith(color: cs.outline),
                                  ),
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
      },
    );
  }
}
