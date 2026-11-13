import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/updater_service.dart';

Future<void> showAppUpdateSheet(
  BuildContext context, {
  required UpdaterService updaterService,
  AppUpdateCheckResult? initialResult,
  void Function(AppUpdateCheckResult result)? onCheckCompleted,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _AppUpdateSheet(
      updaterService: updaterService,
      initialResult: initialResult,
      onCheckCompleted: onCheckCompleted,
    ),
  );
}

class _AppUpdateSheet extends StatefulWidget {
  final UpdaterService updaterService;
  final AppUpdateCheckResult? initialResult;
  final void Function(AppUpdateCheckResult result)? onCheckCompleted;

  const _AppUpdateSheet({
    required this.updaterService,
    this.initialResult,
    this.onCheckCompleted,
  });

  @override
  State<_AppUpdateSheet> createState() => _AppUpdateSheetState();
}

class _AppUpdateSheetState extends State<_AppUpdateSheet>
    with WidgetsBindingObserver {
  bool _checking = false;
  bool _downloading = false;
  double _progress = 0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  bool _canInstallPackages = true;
  String? _downloadedApkPath;
  String? _actionError;
  AppUpdateCheckResult? _result;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _result = widget.initialResult;
    _initStateAsync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshInstallPermission();
    }
  }

  Future<void> _initStateAsync() async {
    await _refreshInstallPermission();
    if (_result == null) {
      await _checkUpdates();
    }
  }

  Future<void> _refreshInstallPermission() async {
    final allowed = await widget.updaterService.canRequestPackageInstalls();
    if (!mounted) return;
    setState(() => _canInstallPackages = allowed);
  }

  Future<void> _checkUpdates() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _actionError = null;
    });

    final res = await widget.updaterService.checkForUpdates();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = res;
    });
    widget.onCheckCompleted?.call(res);
  }

  Future<void> _openPermissionSettings() async {
    await widget.updaterService.openInstallPermissionSettings();
  }

  Future<void> _downloadAndInstall() async {
    final asset = _result?.asset;
    if (asset == null || _downloading) return;

    // Si ya fue descargado en esta sesión del sheet, reintentar instalación directa
    if (_downloadedApkPath != null) {
      await _triggerInstall(_downloadedApkPath!);
      return;
    }

    setState(() {
      _downloading = true;
      _progress = 0;
      _receivedBytes = 0;
      _totalBytes = asset.size;
      _actionError = null;
    });

    try {
      final apkFile = await widget.updaterService.downloadApk(
        asset,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _receivedBytes = received;
            _totalBytes = total;
            _progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _progress = 1.0;
        _downloadedApkPath = apkFile.path;
      });
      await _triggerInstall(apkFile.path);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _actionError = 'No se pudo descargar el APK: $e';
      });
    }
  }

  Future<void> _triggerInstall(String path) async {
    await _refreshInstallPermission();
    if (!_canInstallPackages) {
      setState(() {
        _actionError =
            'Activa "Instalar aplicaciones desconocidas" para Aula-Scrapt y luego vuelve a presionar Instalar.';
      });
      await _openPermissionSettings();
      return;
    }

    try {
      await widget.updaterService.installApk(path);
    } on PlatformException catch (e) {
      if (!mounted) return;
      if (e.code == 'INSTALL_PERMISSION_REQUIRED') {
        await _refreshInstallPermission();
        await _openPermissionSettings();
      }
      setState(() => _actionError = e.message ?? 'Error al abrir el instalador.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _actionError = 'Error al instalar: $e');
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _openReleasesPage() async {
    final url = _result?.htmlUrl ?? UpdaterService.releasesUrl;
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final res = _result;
    final versionLabel = res?.currentVersion ?? '1.2.0';
    final abiLabel = res?.env.abiLabel ?? 'ARM 64-bit';

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Cabecera
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.system_update_rounded,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Actualizaciones de la app',
                        style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Versión actual v$versionLabel · $abiLabel',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Volver a comprobar',
                  onPressed: (_checking || _downloading) ? null : _checkUpdates,
                  icon: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2.2),
                        )
                      : const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Estado actual de búsqueda
            if (_checking && res == null)
              Card(
                color: cs.surfaceContainerHigh,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          'Consultando releases en GitHub (${UpdaterService.githubRepo})...',
                          style: tt.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else if (res != null && !res.ok)
              _buildStatusCard(
                cs,
                tt,
                icon: Icons.cloud_off_rounded,
                containerColor: cs.errorContainer,
                foregroundColor: cs.onErrorContainer,
                title: 'No se pudo comprobar',
                subtitle: res.error ?? 'Error desconocido al consultar GitHub.',
              )
            else if (res != null && res.noReleases)
              _buildStatusCard(
                cs,
                tt,
                icon: Icons.inventory_2_outlined,
                containerColor: cs.surfaceContainerHigh,
                foregroundColor: cs.onSurface,
                title: 'Sin releases publicadas todavía',
                subtitle: 'Aún no hay versiones publicadas en GitHub.',
              )
            else if (res != null && !res.updateAvailable)
              _buildStatusCard(
                cs,
                tt,
                icon: Icons.verified_rounded,
                containerColor: cs.secondaryContainer,
                foregroundColor: cs.onSecondaryContainer,
                title: '¡Tienes la última versión!',
                subtitle: 'Aula-Scrapt v${res.currentVersion} está al día.',
              )
            else if (res != null && res.updateAvailable)
              _buildUpdateAvailableSection(cs, tt, res),

            if (_actionError != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.errorContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded, color: cs.onErrorContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _actionError!,
                        style: tt.bodySmall?.copyWith(color: cs.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _openReleasesPage,
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('Ver releases en GitHub'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(44),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard(
    ColorScheme cs,
    TextTheme tt, {
    required IconData icon,
    required Color containerColor,
    required Color foregroundColor,
    required String title,
    required String subtitle,
  }) {
    return Card(
      color: containerColor,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: foregroundColor, size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: tt.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: foregroundColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: tt.bodySmall?.copyWith(color: foregroundColor),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUpdateAvailableSection(
    ColorScheme cs,
    TextTheme tt,
    AppUpdateCheckResult res,
  ) {
    final asset = res.asset;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: cs.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        res.tagName,
                        style: tt.labelMedium?.copyWith(
                          color: cs.onPrimaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        res.releaseName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
                if (asset != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(
                        Icons.android_rounded,
                        size: 16,
                        color: cs.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${asset.name} · ${asset.sizeLabel} (${asset.archTag})',
                          style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ],
                if (res.changelog.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 150),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: cs.outlineVariant),
                    ),
                    child: SingleChildScrollView(
                      child: Text(
                        res.changelog,
                        style: tt.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // Aviso de permiso REQUEST_INSTALL_PACKAGES
        if (!_canInstallPackages) ...[
          const SizedBox(height: 12),
          Card(
            color: cs.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.security_update_warning_rounded,
                        color: cs.onTertiaryContainer,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Permiso requerido en Android',
                          style: tt.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: cs.onTertiaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Android necesita autorización para "Instalar aplicaciones desconocidas" desde Aula-Scrapt antes de aplicar el nuevo APK.',
                    style: tt.bodySmall?.copyWith(color: cs.onTertiaryContainer),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.tonalIcon(
                    onPressed: _openPermissionSettings,
                    icon: const Icon(Icons.admin_panel_settings_rounded, size: 18),
                    label: const Text('Permitir en Ajustes'),
                  ),
                ],
              ),
            ),
          ),
        ],

        if (_downloading) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: _totalBytes > 0 ? _progress : null,
            borderRadius: BorderRadius.circular(99),
            minHeight: 8,
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _totalBytes > 0
                    ? 'Descargando ${_formatBytes(_receivedBytes)} / ${_formatBytes(_totalBytes)}'
                    : 'Descargando APK...',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              Text(
                '${(_progress * 100).round()}%',
                style: tt.labelMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ],

        const SizedBox(height: 14),
        if (asset != null)
          FilledButton.icon(
            onPressed: _downloading ? null : _downloadAndInstall,
            icon: Icon(
              _downloadedApkPath != null
                  ? Icons.install_mobile_rounded
                  : Icons.download_for_offline_rounded,
            ),
            label: Text(
              _downloading
                  ? 'Descargando...'
                  : _downloadedApkPath != null
                      ? 'Instalar ${res.tagName}'
                      : 'Descargar e instalar ${res.tagName}',
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
            ),
          )
        else
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              'Esta release no incluye un archivo .apk compatible para descarga directa.',
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}
