import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/course.dart';
import '../services/downloader_service.dart';
import '../services/moodle_service.dart';
import '../services/settings_service.dart';
import '../services/updater_service.dart';
import 'auth_sheets.dart';
import 'folder_picker_dialog.dart';
import 'login_screen.dart';
import 'update_sheet.dart';

enum ResourceFilter { files, pending, all }

class CoursesScreen extends StatefulWidget {
  final MoodleService moodleService;
  final SettingsService settingsService;
  final UpdaterService? updaterService;

  const CoursesScreen({
    super.key,
    required this.moodleService,
    required this.settingsService,
    this.updaterService,
  });

  @override
  State<CoursesScreen> createState() => _CoursesScreenState();
}

class _CoursesScreenState extends State<CoursesScreen> with WidgetsBindingObserver {
  late final DownloaderService _downloaderService;
  late final UpdaterService _updaterService;
  final _searchCtrl = TextEditingController();
  AppUpdateCheckResult? _latestUpdateResult;
  bool _updateAvailable = false;

  List<MoodleCourse> _courses = [];
  List<String> _existingSubfolders = [];
  ResourceFilter _filter = ResourceFilter.files;
  String _searchQuery = '';

  final Set<int> _expandedCourses = {};
  final Set<String> _expandedSections = {};
  int? _activeWideCourseId;

  bool _isScanning = false;
  bool _hasStoragePermission = true;
  String? _statusMessage;
  bool _statusIsError = false;

  // Estado de descarga
  bool _isDownloading = false;
  int _downloadCurrent = 0;
  int _downloadTotal = 0;
  String _downloadingFile = '';
  String _downloadingStage = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _downloaderService = DownloaderService(
      moodleService: widget.moodleService,
      settingsService: widget.settingsService,
    );
    _updaterService = widget.updaterService ?? UpdaterService();
    _initScreen();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissionAndSubfolders();
      widget.settingsService.refreshSystemSeedColor().then((_) {
        if (widget.settingsService.useDynamicColor) {
          widget.settingsService.themeNotifier.value++;
        }
      });
    }
  }

  Future<void> _initScreen() async {
    await _refreshPermissionAndSubfolders();
    await widget.moodleService.verifySessionLive();
    if (mounted && !widget.moodleService.isAuthenticated) {
      _goToLogin();
      return;
    }
    await _scanAula();
    if (widget.settingsService.autoCheckUpdates) {
      unawaited(_checkUpdatesSilently());
    }
  }

  Future<void> _checkUpdatesSilently() async {
    final res = await _updaterService.checkForUpdates();
    if (!mounted) return;
    setState(() {
      _latestUpdateResult = res;
      _updateAvailable = res.ok && res.updateAvailable;
    });
  }

  Future<void> _openUpdateSheet() async {
    await showAppUpdateSheet(
      context,
      updaterService: _updaterService,
      initialResult: _latestUpdateResult,
      onCheckCompleted: (res) {
        if (!mounted) return;
        setState(() {
          _latestUpdateResult = res;
          _updateAvailable = res.ok && res.updateAvailable;
        });
      },
    );
  }

  Future<void> _refreshPermissionAndSubfolders() async {
    final perm = await widget.settingsService.hasStoragePermission();
    final subs = await widget.settingsService.listExistingSubfolders();
    if (mounted) {
      setState(() {
        _hasStoragePermission = perm;
        _existingSubfolders = subs;
      });
    }
  }

  void _setStatus(String? msg, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = msg;
      _statusIsError = isError;
    });
  }

  void _goToLogin() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => LoginScreen(
          moodleService: widget.moodleService,
          settingsService: widget.settingsService,
        ),
      ),
    );
  }

  Future<void> _scanAula() async {
    if (_isScanning) return;
    setState(() {
      _isScanning = true;
      _statusMessage = null;
      _statusIsError = false;
    });

    try {
      final subs = await widget.settingsService.listExistingSubfolders();
      final courses = await widget.moodleService.getCourses();

      for (final c in courses) {
        c.isLoadingContents = true;
      }

      if (!mounted) return;
      setState(() {
        _existingSubfolders = subs;
        _courses = courses;
        if (courses.isNotEmpty &&
            (_activeWideCourseId == null ||
                !courses.any((c) => c.id == _activeWideCourseId))) {
          _activeWideCourseId = courses.first.id;
        }
      });

      // Escanear cursos concurrentemente en lotes de 3
      for (var i = 0; i < courses.length; i += 3) {
        final batch = courses.sublist(i, (i + 3).clamp(0, courses.length));
        await Future.wait(batch.map((c) async {
          try {
            final items = await widget.moodleService.scanCourseContents(c);
            c.items = items;
            c.scanError = null;
          } on SessionExpiredException {
            rethrow;
          } catch (e) {
            c.scanError = e.toString().replaceAll('Exception: ', '');
          } finally {
            c.isLoadingContents = false;
            if (mounted) setState(() {});
          }
        }));
      }

      if (mounted) {
        _setStatus(null);
      }
    } on SessionExpiredException catch (e) {
      _setStatus(e.message, isError: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message)),
        );
      }
    } catch (e) {
      _setStatus(
        'Error al consultar Aula USM: ${e.toString().replaceAll('Exception: ', '')}',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() => _isScanning = false);
      }
    }
  }

  Future<void> _pickFolder() async {
    final chosen = await showFolderPickerDialog(context, widget.settingsService);
    final perm = await widget.settingsService.hasStoragePermission();
    if (mounted) {
      setState(() => _hasStoragePermission = perm);
    }
    if (chosen != null && chosen.isNotEmpty) {
      await widget.settingsService.setDownloadRoot(chosen);
      final subs = await widget.settingsService.listExistingSubfolders();

      for (final c in _courses) {
        final resolved =
            widget.settingsService.resolveCourseFolderSync(c.id, c.fullname, subs);
        c.obsidianFolder = resolved;
        await widget.moodleService.enrichItemsWithLocalStatus(c.items, c.obsidianFolder);
      }

      if (mounted) {
        setState(() => _existingSubfolders = subs);
        _setStatus('Carpeta actualizada: ${widget.settingsService.shortDownloadRoot}');
      }
    }
  }

  Future<void> _requestPermissionNow() async {
    final ok = await widget.settingsService.ensureStoragePermission(context);
    await _refreshPermissionAndSubfolders();
    if (ok) {
      _setStatus('Permiso de almacenamiento concedido.');
      for (final c in _courses) {
        await widget.moodleService.enrichItemsWithLocalStatus(c.items, c.obsidianFolder);
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> _handleBrowserSwitch() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WebViewLoginScreen(
          moodleService: widget.moodleService,
          clearExistingCookies: true,
        ),
      ),
    );
    if (ok == true) {
      _setStatus('Sesión iniciada. Actualizando ramos...');
      await _scanAula();
    }
  }

  Future<void> _handleTokenModal() async {
    final ok = await showTokenLoginDialog(context, widget.moodleService);
    if (ok) {
      _setStatus('Token verificado. Actualizando ramos...');
      await _scanAula();
    }
  }

  Future<void> _handleCookieModal() async {
    final ok = await showCookieLoginDialog(context, widget.moodleService);
    if (ok) {
      _setStatus('Cookie verificada. Actualizando ramos...');
      await _scanAula();
    }
  }

  Future<void> _handleLogout() async {
    await widget.moodleService.logout();
    _goToLogin();
  }

  // --- Cálculos y selección ---
  int get _totalFilesCount =>
      _courses.fold(0, (sum, c) => sum + c.downloadableCount);

  int get _totalPendingCount =>
      _courses.fold(0, (sum, c) => sum + c.newFilesCount);

  List<({MoodleCourse course, MoodleItem item})> get _selectedQueue {
    final list = <({MoodleCourse course, MoodleItem item})>[];
    for (final c in _courses) {
      for (final item in c.items) {
        if (item.downloadable && item.isSelected) {
          list.add((course: c, item: item));
        }
      }
    }
    return list;
  }

  int get _selectedTotalBytes =>
      _selectedQueue.fold(0, (acc, e) => acc + e.item.sizeBytes);

  void _selectAllPending() {
    setState(() {
      for (final c in _courses) {
        for (final i in c.items) {
          if (i.downloadable && !i.isDownloaded) {
            i.isSelected = true;
          }
        }
      }
    });
  }

  void _clearSelection() {
    setState(() {
      for (final c in _courses) {
        for (final i in c.items) {
          i.isSelected = false;
        }
      }
    });
  }

  void _toggleCourseSelection(MoodleCourse course, bool selectAll) {
    setState(() {
      for (final i in course.items) {
        if (i.downloadable) {
          i.isSelected = selectAll;
        }
      }
    });
  }

  void _toggleSectionSelection(List<MoodleItem> secItems, bool selectAll) {
    setState(() {
      for (final i in secItems) {
        if (i.downloadable) {
          i.isSelected = selectAll;
        }
      }
    });
  }

  Future<void> _startDownload() async {
    final queue = _selectedQueue;
    if (queue.isEmpty || _isDownloading) return;

    if (Platform.isAndroid) {
      final hasPerm = await widget.settingsService.hasStoragePermission();
      if (!hasPerm) {
        if (!mounted) return;
        final granted = await widget.settingsService.ensureStoragePermission(context);
        await _refreshPermissionAndSubfolders();
        if (!granted) {
          _setStatus(
            'Descarga cancelada: habilita el permiso de almacenamiento.',
            isError: true,
          );
          return;
        }
      }
    }

    setState(() {
      _isDownloading = true;
      _downloadCurrent = 0;
      _downloadTotal = queue.length;
      _downloadingFile = 'Iniciando conexión...';
      _downloadingStage = 'Preparando';
    });

    try {
      final res = await _downloaderService.downloadSelectedItems(
        queue: queue,
        onProgress: (cur, tot, file, stage) {
          if (!mounted) return;
          setState(() {
            _downloadCurrent = cur;
            _downloadTotal = tot;
            _downloadingFile = file;
            _downloadingStage = stage;
          });
        },
      );

      if (!mounted) return;
      if (res.downloadedCount > 0 && res.errors.isEmpty) {
        final where = res.lastSavedDir ?? widget.settingsService.shortDownloadRoot;
        _setStatus('${res.downloadedCount} archivo(s) guardados y grafo .md actualizado');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${res.downloadedCount} archivo(s) guardados en $where')),
        );
      } else if (res.downloadedCount > 0 && res.errors.isNotEmpty) {
        _setStatus(
          '${res.downloadedCount} descargados, ${res.errors.length} fallaron (${res.errors.first.error}).',
          isError: true,
        );
      } else if (res.errors.isNotEmpty) {
        _setStatus('Error al descargar: ${res.errors.first.error}', isError: true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${res.errors.first.error}')),
        );
      }
    } on StoragePermissionException catch (e) {
      _setStatus(e.message, isError: true);
      await _requestPermissionNow();
    } on SessionExpiredException catch (e) {
      _setStatus(e.message, isError: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      _setStatus('Error inesperado al descargar: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
          _downloadingFile = '';
          _downloadingStage = '';
        });
      }
    }
  }

  void _openItemUrl(MoodleItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AuthenticatedWebViewerScreen(
          title: item.title,
          url: item.url,
          moodleService: widget.moodleService,
        ),
      ),
    );
  }

  List<MoodleItem> _filteredItems(MoodleCourse course) {
    final q = _searchQuery.trim().toLowerCase();
    final courseNameMatches = q.isEmpty ||
        course.cleanName.toLowerCase().contains(q) ||
        course.obsidianFolder.toLowerCase().contains(q);

    return course.items.where((item) {
      final passesFilter = switch (_filter) {
        ResourceFilter.files => item.downloadable,
        ResourceFilter.pending => item.downloadable && !item.isDownloaded,
        ResourceFilter.all => true,
      };
      if (!passesFilter) return false;
      if (q.isEmpty || courseNameMatches) return true;
      return item.title.toLowerCase().contains(q) ||
          item.section.toLowerCase().contains(q) ||
          item.fileName.toLowerCase().contains(q);
    }).toList();
  }

  List<MoodleCourse> get _visibleCourses {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return _courses;
    return _courses.where((c) {
      if (c.cleanName.toLowerCase().contains(q) ||
          c.obsidianFolder.toLowerCase().contains(q)) {
        return true;
      }
      return c.items.any((i) =>
          i.title.toLowerCase().contains(q) || i.section.toLowerCase().contains(q));
    }).toList();
  }

  Future<void> _openCourseConfigSheet(MoodleCourse course) async {
    final folderCtrl = TextEditingController(text: course.obsidianFolder);
    final subCtrl = TextEditingController(text: course.targetSubfolder);
    bool orgBySection = course.organizeBySection;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final cs = Theme.of(ctx).colorScheme;
          final tt = Theme.of(ctx).textTheme;
          final keyboardInset = MediaQuery.of(ctx).viewInsets.bottom;

          return Padding(
            padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + keyboardInset),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(Icons.folder_special_rounded,
                            color: cs.onPrimaryContainer),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Carpeta del ramo',
                              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              course.cleanName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: folderCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Carpeta principal del ramo',
                      hintText: 'Ej: Ingeniería de Software',
                      prefixIcon: Icon(Icons.folder_outlined),
                    ),
                  ),
                  if (_existingSubfolders.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Carpetas existentes en destino:',
                      style: tt.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: _existingSubfolders
                          .take(12)
                          .map((folder) => ActionChip(
                                label: Text(folder),
                                onPressed: () {
                                  folderCtrl.text = folder;
                                  setSheetState(() {});
                                },
                              ))
                          .toList(),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextField(
                    controller: subCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Subcarpeta fija (opcional)',
                      hintText: 'Ej: Aula (dejar vacío para guardar directo)',
                      prefixIcon: Icon(Icons.subdirectory_arrow_right_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    title: const Text('Subcarpeta por sección'),
                    subtitle: const Text('Agrupa cada archivo según la pestaña/unidad de Aula'),
                    value: orgBySection,
                    onChanged: (v) => setSheetState(() => orgBySection = v),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('Cancelar'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: FilledButton.icon(
                          onPressed: () async {
                            final f = folderCtrl.text.trim();
                            final sub = subCtrl.text.trim();
                            if (f.isNotEmpty) {
                              course.obsidianFolder = f;
                              await widget.settingsService.setCourseFolder(course.id, f);
                            }
                            course.targetSubfolder = sub;
                            await widget.settingsService.setCourseSubfolder(course.id, sub);
                            course.organizeBySection = orgBySection;
                            await widget.settingsService
                                .setCourseOrganizeBySection(course.id, orgBySection);

                            await widget.moodleService.enrichItemsWithLocalStatus(
                              course.items,
                              course.obsidianFolder,
                            );
                            if (ctx.mounted) Navigator.of(ctx).pop();
                            if (mounted) setState(() {});
                          },
                          icon: const Icon(Icons.check_rounded),
                          label: const Text('Guardar cambios'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    folderCtrl.dispose();
    subCtrl.dispose();
  }

  Future<void> _openAccountSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => ListenableBuilder(
        listenable: widget.settingsService.themeNotifier,
        builder: (ctx, _) {
          final cs = Theme.of(ctx).colorScheme;
          final tt = Theme.of(ctx).textTheme;
          final authLabel = widget.moodleService.isTokenAuth
              ? 'Conectado por Token (wstoken)'
              : 'Conectado por Sesión WebView / Cookie';

          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Cabecera usuario
                  Card(
                    color: cs.surfaceContainerHigh,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: cs.primaryContainer,
                            child: Icon(Icons.person_rounded, color: cs.onPrimaryContainer),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.moodleService.userName ?? 'Usuario Aula USM',
                                  style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  authLabel,
                                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: widget.moodleService.isAuthenticated
                                  ? Colors.greenAccent.shade400
                                  : cs.error,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),

                  Text(
                    'Sesión de Aula USM',
                    style: tt.labelLarge?.copyWith(color: cs.primary),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    color: cs.surfaceContainerHigh,
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.public_rounded),
                          title: const Text('Cambiar sesión (Navegador)'),
                          subtitle: const Text('Iniciar sesión con Microsoft 365'),
                          onTap: () {
                            Navigator.of(ctx).pop();
                            _handleBrowserSwitch();
                          },
                        ),
                        const Divider(height: 1, indent: 56),
                        ListTile(
                          leading: const Icon(Icons.key_rounded),
                          title: const Text('Conectar con Token (wstoken)'),
                          subtitle: const Text('Alternativa rápida sin navegador'),
                          onTap: () {
                            Navigator.of(ctx).pop();
                            _handleTokenModal();
                          },
                        ),
                        const Divider(height: 1, indent: 56),
                        ListTile(
                          leading: const Icon(Icons.cookie_outlined),
                          title: const Text('Ingresar Cookie MoodleSession'),
                          subtitle: const Text('Usar sesión activa copiada del navegador'),
                          onTap: () {
                            Navigator.of(ctx).pop();
                            _handleCookieModal();
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),

                  Text(
                    'Apariencia Android',
                    style: tt.labelLarge?.copyWith(color: cs.primary),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    selected: {widget.settingsService.themeMode},
                    onSelectionChanged: (sel) =>
                        widget.settingsService.setThemeMode(sel.first),
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.brightness_auto_rounded, size: 17),
                        label: Text('Sistema'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode_rounded, size: 17),
                        label: Text('Oscuro'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_rounded, size: 17),
                        label: Text('Claro'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile.adaptive(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    secondary: const Icon(Icons.palette_outlined),
                    title: const Text('Color dinámico (Material You)'),
                    subtitle: const Text('Adapta la paleta a tu fondo de pantalla'),
                    value: widget.settingsService.useDynamicColor,
                    onChanged: (v) => widget.settingsService.setUseDynamicColor(v),
                  ),
                  const SizedBox(height: 18),

                  Text(
                    'Actualizaciones',
                    style: tt.labelLarge?.copyWith(color: cs.primary),
                  ),
                  const SizedBox(height: 8),
                  StatefulBuilder(
                    builder: (sheetCtx, setUpdatesState) => Card(
                      color: cs.surfaceContainerHigh,
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          ListTile(
                            leading: Badge(
                              isLabelVisible: _updateAvailable,
                              smallSize: 8,
                              child: Icon(
                                Icons.system_update_rounded,
                                color: _updateAvailable ? cs.primary : null,
                              ),
                            ),
                            title: Text(
                              _updateAvailable
                                  ? 'Nueva versión ${_latestUpdateResult?.tagName ?? ''}'
                                  : 'Buscar actualizaciones',
                            ),
                            subtitle: Text(
                              _updateAvailable
                                  ? 'Toca para descargar e instalar el APK'
                                  : 'Versión v${_latestUpdateResult?.currentVersion ?? '1.2.0'} · GitHub Releases',
                            ),
                            trailing: _updateAvailable
                                ? Chip(
                                    label: const Text('Nueva'),
                                    backgroundColor: cs.primaryContainer,
                                    labelStyle: tt.labelSmall?.copyWith(
                                      color: cs.onPrimaryContainer,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    side: BorderSide.none,
                                  )
                                : const Icon(Icons.chevron_right_rounded),
                            onTap: () {
                              Navigator.of(ctx).pop();
                              _openUpdateSheet();
                            },
                          ),
                          const Divider(height: 1, indent: 56),
                          SwitchListTile.adaptive(
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 16),
                            secondary:
                                const Icon(Icons.notifications_active_outlined),
                            title: const Text('Buscar al abrir la app'),
                            subtitle: const Text(
                              'Consulta automáticamente en GitHub Releases',
                            ),
                            value: widget.settingsService.autoCheckUpdates,
                            onChanged: (v) async {
                              await widget.settingsService
                                  .setAutoCheckUpdates(v);
                              setUpdatesState(() {});
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  FilledButton.tonalIcon(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _handleLogout();
                    },
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Cerrar sesión'),
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.errorContainer,
                      foregroundColor: cs.onErrorContainer,
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  ({Color bg, Color fg}) _courseBadgeColors(ColorScheme cs, int index) {
    return switch (index % 3) {
      0 => (bg: cs.primaryContainer, fg: cs.onPrimaryContainer),
      1 => (bg: cs.secondaryContainer, fg: cs.onSecondaryContainer),
      _ => (bg: cs.tertiaryContainer, fg: cs.onTertiaryContainer),
    };
  }

  @override
  Widget build(BuildContext context) {
    final queue = _selectedQueue;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 720;

        return Scaffold(
          appBar: isWide ? _buildTopAppBar(context) : null,
          body: Stack(
            children: [
              if (isWide)
                _buildWideAdaptiveBody(context, queue)
              else
                _buildPhoneBody(context, queue),

              // Dock flotante edge-to-edge en alcance del pulgar (se oculta al escribir en búsqueda)
              if (MediaQuery.viewInsetsOf(context).bottom < 50)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: _buildFloatingBottomDock(context, queue),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSettingsActionButton() {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: IconButton.filledTonal(
        tooltip: 'Cuenta, apariencia y actualizaciones',
        onPressed: _openAccountSettingsSheet,
        icon: Badge(
          isLabelVisible: _updateAvailable,
          smallSize: 8,
          child: const Icon(Icons.tune_rounded),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildTopAppBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final displayUser = widget.moodleService.userName ?? 'Conectado';
    final shortUser = displayUser.split(' ').take(2).join(' ');

    return AppBar(
      titleSpacing: 16,
      title: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.asset(
              'assets/logo.png',
              width: 30,
              height: 30,
              errorBuilder: (_, _, _) => Icon(Icons.layers_rounded, color: cs.primary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Aula-Scrapt',
                  style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.moodleService.isAuthenticated
                            ? Colors.greenAccent.shade400
                            : cs.error,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        shortUser,
                        overflow: TextOverflow.ellipsis,
                        style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Actualizar cursos',
          onPressed: _isScanning ? null : _scanAula,
          icon: _isScanning
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                )
              : const Icon(Icons.refresh_rounded),
        ),
        _buildSettingsActionButton(),
      ],
    );
  }

  Widget _buildPhoneBody(
    BuildContext context,
    List<({MoodleCourse course, MoodleItem item})> queue,
  ) {
    final cs = Theme.of(context).colorScheme;
    final visibleCourses = _visibleCourses;
    final hasDock = queue.isNotEmpty || _isDownloading;

    return RefreshIndicator(
      onRefresh: _scanAula,
      edgeOffset: MediaQuery.of(context).padding.top + kToolbarHeight,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverAppBar(
            floating: true,
            snap: true,
            pinned: false,
            titleSpacing: 16,
            surfaceTintColor: cs.surfaceTint,
            title: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/logo.png',
                    width: 30,
                    height: 30,
                    errorBuilder: (_, _, _) =>
                        Icon(Icons.layers_rounded, color: cs.primary),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Aula-Scrapt',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: widget.moodleService.isAuthenticated
                                  ? Colors.greenAccent.shade400
                                  : cs.error,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              (widget.moodleService.userName ?? 'Conectado')
                                  .split(' ')
                                  .take(2)
                                  .join(' '),
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Actualizar cursos',
                onPressed: _isScanning ? null : _scanAula,
                icon: _isScanning
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      )
                    : const Icon(Icons.refresh_rounded),
              ),
              _buildSettingsActionButton(),
            ],
          ),

          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_hasStoragePermission && Platform.isAndroid) ...[
                    _buildPermissionBanner(context),
                    const SizedBox(height: 12),
                  ],
                  _buildDestinationSummaryCard(context),
                  if (_courses.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _buildSearchAndFilters(context, queue),
                  ],
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 10),
                    _buildStatusPill(context),
                  ],
                ],
              ),
            ),
          ),

          if (_isScanning && _courses.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Consultando cursos en Aula USM...'),
                  ],
                ),
              ),
            )
          else if (visibleCourses.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _buildEmptyCoursesState(context),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                16,
                4,
                16,
                MediaQuery.of(context).padding.bottom + (hasDock ? 116 : 28),
              ),
              sliver: SliverList.separated(
                itemCount: visibleCourses.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, idx) =>
                    _buildExpressiveCourseCard(context, visibleCourses[idx], idx),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWideAdaptiveBody(
    BuildContext context,
    List<({MoodleCourse course, MoodleItem item})> queue,
  ) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final visibleCourses = _visibleCourses;
    final MoodleCourse? selectedCourse = visibleCourses.isEmpty
        ? null
        : visibleCourses.firstWhere(
            (c) => c.id == _activeWideCourseId,
            orElse: () => visibleCourses.first,
          );

    return SafeArea(
      top: false,
      bottom: false,
      child: Row(
        children: [
            // Panel izquierdo: Resumen + Buscador + Lista de ramos
            SizedBox(
              width: 360,
              child: RefreshIndicator(
                onRefresh: _scanAula,
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    8,
                    12,
                    MediaQuery.of(context).padding.bottom + 100,
                  ),
                  children: [
                    if (!_hasStoragePermission && Platform.isAndroid) ...[
                      _buildPermissionBanner(context),
                      const SizedBox(height: 12),
                    ],
                    _buildDestinationSummaryCard(context),
                    const SizedBox(height: 12),
                    _buildSearchBar(context),
                    if (_statusMessage != null) ...[
                      const SizedBox(height: 10),
                      _buildStatusPill(context),
                    ],
                    const SizedBox(height: 12),
                    for (var i = 0; i < visibleCourses.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _buildWideCourseTile(
                          context,
                          visibleCourses[i],
                          i,
                          selectedCourse?.id == visibleCourses[i].id,
                        ),
                      ),
                  ],
                ),
              ),
            ),

            VerticalDivider(width: 1, color: cs.outlineVariant.withValues(alpha: 0.4)),

            // Panel derecho: Detalle del ramo activo
            Expanded(
              child: selectedCourse == null
                  ? Center(
                      child: _isScanning
                          ? const CircularProgressIndicator()
                          : Text(
                              'Selecciona un ramo para explorar su material.',
                              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                            ),
                    )
                  : ListView(
                      padding: EdgeInsets.fromLTRB(
                        20,
                        12,
                        20,
                        MediaQuery.of(context).padding.bottom +
                            (queue.isNotEmpty || _isDownloading ? 120 : 32),
                      ),
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    selectedCourse.cleanName,
                                    style: tt.headlineSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${selectedCourse.downloadableCount} archivos • ${selectedCourse.newFilesCount} pendientes',
                                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ),
                            ActionChip(
                              avatar: const Icon(Icons.folder_outlined, size: 17),
                              label: Text(selectedCourse.obsidianFolder),
                              onPressed: () => _openCourseConfigSheet(selectedCourse),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _buildFilterAndBulkRow(context, queue, courseOnly: selectedCourse),
                        const SizedBox(height: 16),
                        _buildSectionsList(context, selectedCourse),
                      ],
                    ),
            ),
          ],
      ),
    );
  }

  Widget _buildWideCourseTile(
    BuildContext context,
    MoodleCourse course,
    int index,
    bool isSelected,
  ) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final colors = _courseBadgeColors(cs, index);
    final pending = course.newFilesCount;

    return Card(
      color: isSelected ? cs.primaryContainer : cs.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: () => setState(() => _activeWideCourseId = course.id),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isSelected ? cs.primary : colors.bg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: course.isLoadingContents
              ? Padding(
                  padding: const EdgeInsets.all(10),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: isSelected ? cs.onPrimary : colors.fg,
                  ),
                )
              : Icon(
                  Icons.menu_book_rounded,
                  size: 20,
                  color: isSelected ? cs.onPrimary : colors.fg,
                ),
        ),
        title: Text(
          course.cleanName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: tt.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: isSelected ? cs.onPrimaryContainer : cs.onSurface,
          ),
        ),
        subtitle: Text(
          '${course.downloadableCount} archivos • $pending pend.',
          style: tt.labelSmall?.copyWith(
            color: isSelected
                ? cs.onPrimaryContainer.withValues(alpha: 0.8)
                : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionBanner(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Card(
      color: cs.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.folder_off_rounded, color: cs.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Permiso de almacenamiento requerido',
                    style: tt.titleSmall?.copyWith(
                      color: cs.onErrorContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Actívalo para guardar PDFs y notas Obsidian en tu teléfono.',
                    style: tt.bodySmall?.copyWith(color: cs.onErrorContainer),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _requestPermissionNow,
              style: FilledButton.styleFrom(
                backgroundColor: cs.onErrorContainer,
                foregroundColor: cs.errorContainer,
                minimumSize: const Size(84, 40),
              ),
              child: const Text('Activar'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDestinationSummaryCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Card(
      color: cs.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: _pickFolder,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 14, 12),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(Icons.folder_copy_rounded, color: cs.onPrimaryContainer),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Guardar descargas en',
                          style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.settingsService.shortDownloadRoot,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    onPressed: _pickFolder,
                    icon: const Icon(Icons.edit_location_alt_outlined, size: 18),
                    label: const Text('Elegir'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(84, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_courses.isNotEmpty) ...[
            Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.35)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _MetricBadge(
                    icon: Icons.school_outlined,
                    label: '${_courses.length} ramos',
                    bg: cs.surfaceContainerHighest,
                    fg: cs.onSurface,
                  ),
                  _MetricBadge(
                    icon: Icons.insert_drive_file_outlined,
                    label: '$_totalFilesCount archivos',
                    bg: cs.secondaryContainer,
                    fg: cs.onSecondaryContainer,
                  ),
                  _MetricBadge(
                    icon: Icons.download_for_offline_outlined,
                    label: '$_totalPendingCount pendientes',
                    bg: _totalPendingCount > 0
                        ? cs.tertiaryContainer
                        : cs.surfaceContainerHighest,
                    fg: _totalPendingCount > 0
                        ? cs.onTertiaryContainer
                        : cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ],
          if (_isScanning) const LinearProgressIndicator(minHeight: 3),
        ],
      ),
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return TextField(
      controller: _searchCtrl,
      onChanged: (v) => setState(() => _searchQuery = v),
      decoration: InputDecoration(
        hintText: 'Buscar ramo, sección o archivo...',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: _searchQuery.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _searchQuery = '');
                },
              )
            : null,
        filled: true,
        fillColor: cs.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide(color: cs.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    );
  }

  Widget _buildSearchAndFilters(
    BuildContext context,
    List<({MoodleCourse course, MoodleItem item})> queue,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSearchBar(context),
        const SizedBox(height: 10),
        _buildFilterAndBulkRow(context, queue),
      ],
    );
  }

  Widget _buildFilterAndBulkRow(
    BuildContext context,
    List<({MoodleCourse course, MoodleItem item})> queue, {
    MoodleCourse? courseOnly,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<ResourceFilter>(
          showSelectedIcon: false,
          selected: {_filter},
          onSelectionChanged: (sel) => setState(() => _filter = sel.first),
          segments: const [
            ButtonSegment(
              value: ResourceFilter.files,
              icon: Icon(Icons.folder_zip_outlined, size: 17),
              label: Text('Archivos', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ButtonSegment(
              value: ResourceFilter.pending,
              icon: Icon(Icons.new_releases_outlined, size: 17),
              label: Text('Pendientes', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ButtonSegment(
              value: ResourceFilter.all,
              icon: Icon(Icons.list_alt_rounded, size: 17),
              label: Text('Todo', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: FilledButton.tonalIcon(
                onPressed: courseOnly != null
                    ? () => _toggleCourseSelection(courseOnly, true)
                    : (_totalPendingCount > 0 ? _selectAllPending : null),
                icon: const Icon(Icons.done_all_rounded, size: 18),
                label: Text(
                  courseOnly != null ? 'Marcar ramo' : 'Marcar pendientes',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: OutlinedButton.icon(
                onPressed: queue.isNotEmpty
                    ? (courseOnly != null
                        ? () => _toggleCourseSelection(courseOnly, false)
                        : _clearSelection)
                    : null,
                icon: const Icon(Icons.clear_all_rounded, size: 18),
                label: const Text(
                  'Limpiar',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatusPill(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _statusIsError ? cs.errorContainer : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            _statusIsError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
            size: 18,
            color: _statusIsError ? cs.onErrorContainer : cs.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _statusMessage!,
              style: tt.bodySmall?.copyWith(
                color: _statusIsError ? cs.onErrorContainer : cs.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 16),
            onPressed: () => setState(() => _statusMessage = null),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyCoursesState(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final hasSearch = _searchQuery.trim().isNotEmpty;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasSearch ? Icons.search_off_rounded : Icons.school_outlined,
              size: 48,
              color: cs.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              hasSearch
                  ? 'Sin resultados para "$_searchQuery"'
                  : 'No se encontraron ramos activos.',
              textAlign: TextAlign.center,
              style: tt.titleSmall,
            ),
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              onPressed: hasSearch
                  ? () {
                      _searchCtrl.clear();
                      setState(() => _searchQuery = '');
                    }
                  : _scanAula,
              icon: Icon(hasSearch ? Icons.clear_rounded : Icons.refresh_rounded),
              label: Text(hasSearch ? 'Limpiar búsqueda' : 'Actualizar cursos'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpressiveCourseCard(
    BuildContext context,
    MoodleCourse course,
    int index,
  ) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isExpanded =
        _expandedCourses.contains(course.id) || _searchQuery.trim().isNotEmpty;
    final badgeColors = _courseBadgeColors(cs, index);
    final pendingCount = course.newFilesCount;
    final totalCount = course.downloadableCount;
    final selectedInCourse =
        course.items.where((i) => i.downloadable && i.isSelected).length;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: isExpanded ? cs.surfaceContainerHigh : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                if (_expandedCourses.contains(course.id)) {
                  _expandedCourses.remove(course.id);
                } else {
                  _expandedCourses.add(course.id);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: badgeColors.bg,
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: course.isLoadingContents
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: badgeColors.fg,
                            ),
                          )
                        : Icon(Icons.menu_book_rounded, color: badgeColors.fg),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          course.cleanName,
                          style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${course.obsidianFolder}${selectedInCourse > 0 ? ' • $selectedInCourse selec.' : ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!course.isLoadingContents)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: pendingCount > 0
                            ? cs.tertiaryContainer
                            : cs.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        pendingCount > 0 ? '$pendingCount pend.' : '$totalCount arch.',
                        style: tt.labelSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: pendingCount > 0
                              ? cs.onTertiaryContainer
                              : cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: cs.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),

          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: !isExpanded
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.35)),
                        const SizedBox(height: 10),
                        // Barra de acciones rápidas del ramo (táctil y limpia)
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              ActionChip(
                                avatar: Icon(
                                  Icons.folder_outlined,
                                  size: 17,
                                  color: cs.primary,
                                ),
                                label: Text(
                                  course.targetSubfolder.isEmpty
                                      ? 'Carpeta: ${course.obsidianFolder}'
                                      : '${course.obsidianFolder}/${course.targetSubfolder}',
                                ),
                                onPressed: () => _openCourseConfigSheet(course),
                              ),
                              const SizedBox(width: 8),
                              ActionChip(
                                avatar: const Icon(Icons.done_all_rounded, size: 17),
                                label: const Text('Marcar todo'),
                                onPressed: () => _toggleCourseSelection(course, true),
                              ),
                              const SizedBox(width: 8),
                              ActionChip(
                                avatar: const Icon(Icons.clear_all_rounded, size: 17),
                                label: const Text('Desmarcar'),
                                onPressed: () => _toggleCourseSelection(course, false),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        _buildSectionsList(context, course),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionsList(BuildContext context, MoodleCourse course) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final filtered = _filteredItems(course);

    if (course.scanError != null) {
      return Card(
        color: cs.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(
            'Error al leer este ramo: ${course.scanError}',
            style: tt.bodySmall?.copyWith(color: cs.onErrorContainer),
          ),
        ),
      );
    }

    if (filtered.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Text(
          'Sin elementos visibles con este filtro.',
          textAlign: TextAlign.center,
          style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      );
    }

    final Map<String, List<MoodleItem>> sectionsMap = {};
    for (final item in filtered) {
      final sec = item.section.isEmpty ? 'General' : item.section;
      sectionsMap.putIfAbsent(sec, () => []).add(item);
    }

    return Column(
      children: sectionsMap.entries.map((entry) {
        final secName = entry.key;
        final secItems = entry.value;
        final secKey = '${course.id}::$secName';
        final isSecExpanded =
            _expandedSections.contains(secKey) || _searchQuery.trim().isNotEmpty;

        final downloadableInSec = secItems.where((i) => i.downloadable).toList();
        final allSecSelected = downloadableInSec.isNotEmpty &&
            downloadableInSec.every((i) => i.isSelected);

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: cs.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                InkWell(
                  onTap: () async {
                    final opening = !_expandedSections.contains(secKey);
                    setState(() {
                      if (opening) {
                        _expandedSections.add(secKey);
                      } else {
                        _expandedSections.remove(secKey);
                      }
                    });
                    if (opening) {
                      final updated =
                          await widget.moodleService.fetchMissingFileSizes(secItems);
                      if (updated && mounted) setState(() {});
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(
                      children: [
                        if (downloadableInSec.isNotEmpty)
                          Checkbox(
                            value: allSecSelected,
                            onChanged: (v) =>
                                _toggleSectionSelection(secItems, v ?? false),
                          )
                        else
                          const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            secName,
                            style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${secItems.length}',
                            style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          isSecExpanded
                              ? Icons.keyboard_arrow_up_rounded
                              : Icons.keyboard_arrow_down_rounded,
                          color: cs.onSurfaceVariant,
                          size: 20,
                        ),
                        const SizedBox(width: 6),
                      ],
                    ),
                  ),
                ),
                if (isSecExpanded) ...[
                  Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.3)),
                  ...secItems.map((item) => _buildItemRow(context, item)),
                ],
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildItemRow(BuildContext context, MoodleItem item) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final sizeText = item.formattedSize;

    Color statusBg;
    Color statusFg;
    String statusText;
    if (item.downloadable) {
      if (item.isDownloaded) {
        statusBg = cs.secondaryContainer;
        statusFg = cs.onSecondaryContainer;
        statusText = 'En carpeta';
      } else {
        statusBg = cs.tertiaryContainer;
        statusFg = cs.onTertiaryContainer;
        statusText = 'Pendiente';
      }
    } else {
      statusBg = cs.surfaceContainerHigh;
      statusFg = cs.onSurfaceVariant;
      statusText = item.typeLabel;
    }

    IconData nonFileIcon = switch (item.type) {
      'assignment' => Icons.assignment_outlined,
      'forum' => Icons.forum_outlined,
      'page' => Icons.article_outlined,
      _ => Icons.link_rounded,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
      child: Row(
        children: [
          if (item.downloadable)
            Checkbox(
              value: item.isSelected,
              onChanged: (val) => setState(() => item.isSelected = val ?? false),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Icon(nonFileIcon, size: 20, color: cs.onSurfaceVariant),
            ),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: item.downloadable
                  ? () => setState(() => item.isSelected = !item.isSelected)
                  : () => _openItemUrl(item),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        Container(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: statusBg,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            statusText,
                            style: tt.labelSmall?.copyWith(
                              color: statusFg,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (sizeText.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHigh,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              sizeText,
                              style:
                                  tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton.filledTonal(
            tooltip: 'Abrir en Aula USM',
            onPressed: () => _openItemUrl(item),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildFloatingBottomDock(
    BuildContext context,
    List<({MoodleCourse course, MoodleItem item})> queue,
  ) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    if (queue.isEmpty && !_isDownloading) {
      return const SizedBox.shrink();
    }

    final selectedBytesStr = MoodleItem.formatFileSize(_selectedTotalBytes);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: Material(
          elevation: 6,
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(28),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_isDownloading) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          '$_downloadingStage: $_downloadingFile',
                          style: tt.labelMedium?.copyWith(
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '$_downloadCurrent / $_downloadTotal',
                        style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: _downloadTotal > 0 ? _downloadCurrent / _downloadTotal : 0,
                  ),
                  const SizedBox(height: 12),
                ],
                Row(
                  children: [
                    if (!_isDownloading)
                      IconButton(
                        tooltip: 'Limpiar selección',
                        onPressed: _clearSelection,
                        icon: const Icon(Icons.close_rounded),
                      ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${queue.length} seleccionado(s)',
                            style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          if (selectedBytesStr.isNotEmpty)
                            Text(
                              selectedBytesStr,
                              style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _isDownloading ? null : _startDownload,
                      icon: const Icon(Icons.download_rounded),
                      label: Text(_isDownloading ? 'Descargando' : 'Descargar'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MetricBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color bg;
  final Color fg;

  const _MetricBadge({
    required this.icon,
    required this.label,
    required this.bg,
    required this.fg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: fg),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
