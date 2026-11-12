import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/course.dart';
import '../services/downloader_service.dart';
import '../services/moodle_service.dart';
import '../services/settings_service.dart';
import 'auth_sheets.dart';
import 'folder_picker_dialog.dart';
import 'login_screen.dart';

enum ResourceFilter { files, pending, all }

class CoursesScreen extends StatefulWidget {
  final MoodleService moodleService;
  final SettingsService settingsService;

  const CoursesScreen({
    super.key,
    required this.moodleService,
    required this.settingsService,
  });

  @override
  State<CoursesScreen> createState() => _CoursesScreenState();
}

class _CoursesScreenState extends State<CoursesScreen> with WidgetsBindingObserver {
  late final DownloaderService _downloaderService;

  List<MoodleCourse> _courses = [];
  List<String> _existingSubfolders = [];
  ResourceFilter _filter = ResourceFilter.files;

  final Set<int> _expandedCourses = {};
  final Set<String> _expandedSections = {};
  final Map<int, TextEditingController> _folderCtrls = {};
  final Map<int, TextEditingController> _subfolderCtrls = {};

  bool _isScanning = false;
  bool _hasStoragePermission = true;
  String _statusMessage = 'Presiona "Actualizar cursos" para cargar tus asignaturas.';
  Color _statusColor = const Color(0xFF9CA3AF);

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
    _initScreen();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final c in _folderCtrls.values) {
      c.dispose();
    }
    for (final c in _subfolderCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissionAndSubfolders();
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

  void _setStatus(String msg, [String type = 'info']) {
    if (!mounted) return;
    setState(() {
      _statusMessage = msg;
      _statusColor = type == 'error'
          ? const Color(0xFFF87171)
          : (type == 'success' ? const Color(0xFF86EFAC) : const Color(0xFF9CA3AF));
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
    setState(() => _isScanning = true);
    _setStatus('Consultando cursos y archivos en Aula USM...');

    try {
      final subs = await widget.settingsService.listExistingSubfolders();
      final courses = await widget.moodleService.getCourses();

      for (final c in courses) {
        c.isLoadingContents = true;
        _folderCtrls[c.id]?.dispose();
        _folderCtrls[c.id] = TextEditingController(text: c.obsidianFolder);
        _subfolderCtrls[c.id]?.dispose();
        _subfolderCtrls[c.id] = TextEditingController(text: c.targetSubfolder);
      }

      if (!mounted) return;
      setState(() {
        _existingSubfolders = subs;
        _courses = courses;
      });

      // Escanear cursos concurrentemente en lotes de 3 para máxima velocidad sin saturar Aula
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
        final totalFiles = _totalFilesCount;
        final totalNew = _totalPendingCount;
        _setStatus(
          'Listo: ${_courses.length} ramos cargados ($totalFiles archivos, $totalNew pendientes). Toca un ramo para desplegar sus secciones.',
          'success',
        );
      }
    } on SessionExpiredException catch (e) {
      _setStatus(e.message, 'error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: const Color(0xFFB91C1C)),
        );
      }
    } catch (e) {
      _setStatus('Error al consultar Aula USM: ${e.toString().replaceAll('Exception: ', '')}', 'error');
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

      // Re-evaluar carpetas sugeridas y archivos existentes en disco para la nueva ruta
      for (final c in _courses) {
        final resolved =
            widget.settingsService.resolveCourseFolderSync(c.id, c.fullname, subs);
        c.obsidianFolder = resolved;
        _folderCtrls[c.id]?.text = resolved;
        await widget.moodleService.enrichItemsWithLocalStatus(c.items, c.obsidianFolder);
      }

      if (mounted) {
        setState(() => _existingSubfolders = subs);
        _setStatus('Carpeta de guardado actualizada: $chosen', 'success');
      }
    }
  }

  Future<void> _requestPermissionNow() async {
    final ok = await widget.settingsService.ensureStoragePermission(context);
    await _refreshPermissionAndSubfolders();
    if (ok) {
      _setStatus('Permiso de almacenamiento concedido correctamente.', 'success');
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
      _setStatus('Sesión iniciada. Cargando cursos...', 'success');
      await _scanAula();
    }
  }

  Future<void> _handleTokenModal() async {
    final ok = await showTokenLoginDialog(context, widget.moodleService);
    if (ok) {
      _setStatus('Token verificado. Cargando cursos...', 'success');
      await _scanAula();
    }
  }

  Future<void> _handleCookieModal() async {
    final ok = await showCookieLoginDialog(context, widget.moodleService);
    if (ok) {
      _setStatus('Cookie verificada. Cargando cursos...', 'success');
      await _scanAula();
    }
  }

  Future<void> _handleLogout() async {
    await widget.moodleService.logout();
    _goToLogin();
  }

  // --- Cálculos y Selección ---
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

    // 1. Verificar/pedir permiso explícitamente ANTES de descargar
    if (Platform.isAndroid) {
      final hasPerm = await widget.settingsService.hasStoragePermission();
      if (!hasPerm) {
        if (!mounted) return;
        final granted = await widget.settingsService.ensureStoragePermission(context);
        await _refreshPermissionAndSubfolders();
        if (!granted) {
          _setStatus(
            'Descarga cancelada: habilita el permiso de almacenamiento para guardar archivos en "${widget.settingsService.downloadRoot}".',
            'error',
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
        final where = res.lastSavedDir ?? widget.settingsService.downloadRoot;
        _setStatus(
          '${res.downloadedCount} archivo(s) descargados y grafo .md actualizado en: $where',
          'success',
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${res.downloadedCount} archivo(s) guardados en $where'),
            backgroundColor: const Color(0xFF15803D),
          ),
        );
      } else if (res.downloadedCount > 0 && res.errors.isNotEmpty) {
        _setStatus(
          'Se descargaron ${res.downloadedCount} archivo(s), pero ${res.errors.length} fallaron (${res.errors.first.error}).',
          'error',
        );
      } else if (res.errors.isNotEmpty) {
        _setStatus('Error al descargar: ${res.errors.first.error}', 'error');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No se pudo descargar: ${res.errors.first.error}'),
            backgroundColor: const Color(0xFFB91C1C),
          ),
        );
      }
    } on StoragePermissionException catch (e) {
      _setStatus(e.message, 'error');
      await _requestPermissionNow();
    } on SessionExpiredException catch (e) {
      _setStatus(e.message, 'error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: const Color(0xFFB91C1C)),
        );
      }
    } catch (e) {
      _setStatus('Error inesperado al descargar: $e', 'error');
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
    return course.items.where((item) {
      switch (_filter) {
        case ResourceFilter.files:
          return item.downloadable;
        case ResourceFilter.pending:
          return item.downloadable && !item.isDownloaded;
        case ResourceFilter.all:
          return true;
      }
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final queue = _selectedQueue;
    final selectedBytesStr = MoodleItem.formatFileSize(_selectedTotalBytes);

    return Scaffold(
      backgroundColor: const Color(0xFF0F0F12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF17171C),
        elevation: 0,
        titleSpacing: 12,
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset(
                'assets/logo.png',
                width: 24,
                height: 24,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.layers, size: 20, color: Color(0xFF38BDF8)),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Aula-Scrapt',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFFF3F4F6)),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: widget.moodleService.isAuthenticated
                        ? const Color(0x7322C55E)
                        : const Color(0x73EF4444),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: widget.moodleService.isAuthenticated
                            ? const Color(0xFF22C55E)
                            : const Color(0xFFEF4444),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        widget.moodleService.userName ?? 'Conectado',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: Color(0xFFF3F4F6)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.manage_accounts_outlined, color: Color(0xFFF3F4F6), size: 21),
            tooltip: 'Opciones de sesión',
            color: const Color(0xFF17171C),
            onSelected: (value) {
              if (value == 'browser') _handleBrowserSwitch();
              if (value == 'token') _handleTokenModal();
              if (value == 'cookie') _handleCookieModal();
              if (value == 'logout') _handleLogout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'browser',
                child: Text('Cambiar sesión (WebView)', style: TextStyle(color: Color(0xFFF3F4F6))),
              ),
              PopupMenuItem(
                value: 'token',
                child: Text('Conectar con Token (wstoken)', style: TextStyle(color: Color(0xFFF3F4F6))),
              ),
              PopupMenuItem(
                value: 'cookie',
                child: Text('Ingresar Cookie MoodleSession', style: TextStyle(color: Color(0xFFF3F4F6))),
              ),
              PopupMenuDivider(),
              PopupMenuItem(
                value: 'logout',
                child: Text('Salir / Cerrar sesión', style: TextStyle(color: Color(0xFFF87171))),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Barra de accesos rápidos de sesión (paridad topbar .exe: WebView / Token / Cookie / Salir)
          Container(
            width: double.infinity,
            color: const Color(0xFF17171C),
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _TopActionButton(label: 'Cambiar sesión', onTap: _handleBrowserSwitch),
                  const SizedBox(width: 6),
                  _TopActionButton(label: 'Token', onTap: _handleTokenModal),
                  const SizedBox(width: 6),
                  _TopActionButton(label: 'Cookie', onTap: _handleCookieModal),
                  const SizedBox(width: 6),
                  _TopActionButton(
                    label: 'Salir',
                    isDanger: true,
                    onTap: _handleLogout,
                  ),
                ],
              ),
            ),
          ),

          // Aviso de permiso de almacenamiento si falta
          if (!_hasStoragePermission && Platform.isAndroid)
            Container(
              width: double.infinity,
              color: const Color(0x2EEAB308),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFFFACC15)),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Falta permiso de almacenamiento para descargar en tu carpeta.',
                      style: TextStyle(color: Color(0xFFFDE047), fontSize: 11.5),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: const Color(0xFFFACC15),
                      foregroundColor: const Color(0xFF0F0F12),
                    ),
                    onPressed: _requestPermissionNow,
                    child: const Text('Conceder permiso',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),

          // Barra de carpeta destino + controles globales (igual a .control-bar en .exe)
          Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              color: Color(0xFF17171C),
              border: Border(
                top: BorderSide(color: Color(0xFF2A2A33)),
                bottom: BorderSide(color: Color(0xFF2A2A33)),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Selector de ruta Guardar en
                Row(
                  children: [
                    const Text(
                      'Guardar en:',
                      style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 11.5),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: GestureDetector(
                        onTap: _pickFolder,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F0F12),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: const Color(0xFF2A2A33)),
                          ),
                          child: Text(
                            widget.settingsService.downloadRoot,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Color(0xFFF3F4F6), fontSize: 11.5),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    OutlinedButton(
                      onPressed: _pickFolder,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF2A2A33)),
                        foregroundColor: const Color(0xFFF3F4F6),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                      ),
                      child: const Text('Elegir carpeta...', style: TextStyle(fontSize: 11.5)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Estadísticas y Botón Actualizar cursos
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${_courses.length} ramos | $_totalFilesCount archivos ($_totalPendingCount pendientes)',
                        style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: _isScanning ? null : _scanAula,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF3F4F6),
                        foregroundColor: const Color(0xFF0F0F12),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
                      ),
                      child: Text(
                        _isScanning ? 'Cargando...' : 'Actualizar cursos',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),

                if (_courses.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  // Pestañas de filtro por categoría + Marcar pendientes / Limpiar
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F0F12),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: const Color(0xFF2A2A33)),
                          ),
                          child: Row(
                            children: [
                              _FilterTabBtn(
                                label: 'Archivos',
                                active: _filter == ResourceFilter.files,
                                onTap: () => setState(() => _filter = ResourceFilter.files),
                              ),
                              _FilterTabBtn(
                                label: 'Pendientes',
                                active: _filter == ResourceFilter.pending,
                                onTap: () => setState(() => _filter = ResourceFilter.pending),
                              ),
                              _FilterTabBtn(
                                label: 'Todo',
                                active: _filter == ResourceFilter.all,
                                onTap: () => setState(() => _filter = ResourceFilter.all),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _TopActionButton(
                        label: 'Marcar pend.',
                        onTap: _selectAllPending,
                      ),
                      const SizedBox(width: 4),
                      _TopActionButton(
                        label: 'Limpiar',
                        onTap: _clearSelection,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),

          // Status Banner compacto
          Container(
            width: double.infinity,
            color: const Color(0xFF1E1E24),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              _statusMessage,
              style: TextStyle(color: _statusColor, fontSize: 11.5),
            ),
          ),

          // Lista principal de cursos
          Expanded(
            child: _isScanning && _courses.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(color: Color(0xFF38BDF8)),
                        SizedBox(height: 14),
                        Text(
                          'Consultando cursos en Aula USM...',
                          style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                        ),
                      ],
                    ),
                  )
                : _courses.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'No se encontraron cursos activos o falló la carga.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                              ),
                              const SizedBox(height: 12),
                              ElevatedButton(
                                onPressed: _scanAula,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFF3F4F6),
                                  foregroundColor: const Color(0xFF0F0F12),
                                ),
                                child: const Text('Actualizar cursos'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: EdgeInsets.fromLTRB(
                          12,
                          12,
                          12,
                          queue.isNotEmpty || _isDownloading ? 130 : 24,
                        ),
                        itemCount: _courses.length,
                        itemBuilder: (context, index) =>
                            _buildCourseCard(_courses[index]),
                      ),
          ),
        ],
      ),

      // Barra fija inferior de descarga
      bottomSheet: queue.isNotEmpty || _isDownloading
          ? Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: const BoxDecoration(
                color: Color(0xFF17171C),
                border: Border(top: BorderSide(color: Color(0xFF2A2A33))),
              ),
              child: SafeArea(
                top: false,
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
                              style: const TextStyle(color: Color(0xFF38BDF8), fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '$_downloadCurrent / $_downloadTotal',
                            style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: _downloadTotal > 0 ? _downloadCurrent / _downloadTotal : 0,
                        backgroundColor: const Color(0xFF0F0F12),
                        color: const Color(0xFF22C55E),
                      ),
                      const SizedBox(height: 10),
                    ],
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${queue.length} archivo(s) seleccionado(s)${selectedBytesStr.isNotEmpty ? ' • $selectedBytesStr' : ''}',
                            style: const TextStyle(
                              color: Color(0xFFF3F4F6),
                              fontWeight: FontWeight.w600,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                        ElevatedButton(
                          onPressed: _isDownloading ? null : _startDownload,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFF3F4F6),
                            foregroundColor: const Color(0xFF0F0F12),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          ),
                          child: Text(
                            _isDownloading ? 'Descargando...' : 'Descargar seleccionados',
                            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildCourseCard(MoodleCourse course) {
    final isExpanded = _expandedCourses.contains(course.id);
    final filtered = _filteredItems(course);

    // Agrupar ítems filtrados por sección / categoría
    final Map<String, List<MoodleItem>> sectionsMap = {};
    for (final item in filtered) {
      final sec = item.section.isEmpty ? 'General' : item.section;
      sectionsMap.putIfAbsent(sec, () => []).add(item);
    }

    final pendingCount = course.newFilesCount;
    final totalCount = course.downloadableCount;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF17171C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF2A2A33)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Cabecera de curso
          InkWell(
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expandedCourses.remove(course.id);
                } else {
                  _expandedCourses.add(course.id);
                }
              });
            },
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isExpanded ? Icons.arrow_drop_down : Icons.arrow_right,
                        color: const Color(0xFF9CA3AF),
                        size: 20,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          course.cleanName,
                          style: const TextStyle(
                            color: Color(0xFFF3F4F6),
                            fontWeight: FontWeight.w600,
                            fontSize: 13.5,
                          ),
                        ),
                      ),
                      if (course.isLoadingContents)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF38BDF8),
                          ),
                        )
                      else
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: pendingCount > 0
                                ? const Color(0x1EEAB308)
                                : const Color(0xFF0F0F12),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: pendingCount > 0
                                  ? const Color(0x73EAB308)
                                  : const Color(0xFF2A2A33),
                            ),
                          ),
                          child: Text(
                            '$totalCount archivos ($pendingCount pend.)',
                            style: TextStyle(
                              fontSize: 11,
                              color: pendingCount > 0
                                  ? const Color(0xFFFACC15)
                                  : const Color(0xFF9CA3AF),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Padding(
                    padding: const EdgeInsets.only(left: 24),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F0F12),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xFF2A2A33)),
                      ),
                      child: Text(
                        course.obsidianFolder,
                        style: const TextStyle(fontSize: 10.5, color: Color(0xFF9CA3AF)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Cuerpo expandido del curso
          if (isExpanded) ...[
            const Divider(color: Color(0xFF2A2A33), height: 1),
            // Barra de configuración de carpeta de este ramo
            Container(
              color: const Color(0xFF1E1E24),
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 92,
                        child: Text(
                          'Carpeta ramo:',
                          style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 11.5),
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _folderCtrls[course.id],
                          style: const TextStyle(color: Color(0xFFF3F4F6), fontSize: 12),
                          onChanged: (val) async {
                            final clean = val.trim();
                            if (clean.isEmpty) return;
                            course.obsidianFolder = clean;
                            await widget.settingsService.setCourseFolder(course.id, clean);
                          },
                          decoration: InputDecoration(
                            isDense: true,
                            filled: true,
                            fillColor: const Color(0xFF0F0F12),
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(5),
                              borderSide: const BorderSide(color: Color(0xFF2A2A33)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(5),
                              borderSide: const BorderSide(color: Color(0xFF2A2A33)),
                            ),
                          ),
                        ),
                      ),
                      if (_existingSubfolders.isNotEmpty)
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.arrow_drop_down,
                              color: Color(0xFF9CA3AF), size: 20),
                          tooltip: 'Elegir carpeta existente',
                          color: const Color(0xFF17171C),
                          onSelected: (folder) async {
                            _folderCtrls[course.id]?.text = folder;
                            course.obsidianFolder = folder;
                            await widget.settingsService.setCourseFolder(course.id, folder);
                            await widget.moodleService.enrichItemsWithLocalStatus(
                              course.items,
                              course.obsidianFolder,
                            );
                            if (mounted) setState(() {});
                          },
                          itemBuilder: (_) => _existingSubfolders
                              .map((f) => PopupMenuItem(
                                    value: f,
                                    child: Text(f,
                                        style: const TextStyle(
                                            color: Color(0xFFF3F4F6), fontSize: 12.5)),
                                  ))
                              .toList(),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const SizedBox(
                        width: 92,
                        child: Text(
                          'Subcarpeta:',
                          style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 11.5),
                        ),
                      ),
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: _subfolderCtrls[course.id],
                          style: const TextStyle(color: Color(0xFFF3F4F6), fontSize: 12),
                          onChanged: (val) async {
                            course.targetSubfolder = val.trim();
                            await widget.settingsService
                                .setCourseSubfolder(course.id, val.trim());
                          },
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: 'Opcional',
                            hintStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 11),
                            filled: true,
                            fillColor: const Color(0xFF0F0F12),
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(5),
                              borderSide: const BorderSide(color: Color(0xFF2A2A33)),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(5),
                              borderSide: const BorderSide(color: Color(0xFF2A2A33)),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: InkWell(
                          onTap: () async {
                            final next = !course.organizeBySection;
                            setState(() => course.organizeBySection = next);
                            await widget.settingsService
                                .setCourseOrganizeBySection(course.id, next);
                          },
                          child: Row(
                            children: [
                              SizedBox(
                                width: 22,
                                height: 22,
                                child: Checkbox(
                                  value: course.organizeBySection,
                                  activeColor: const Color(0xFF38BDF8),
                                  onChanged: (v) async {
                                    final next = v ?? true;
                                    setState(() => course.organizeBySection = next);
                                    await widget.settingsService
                                        .setCourseOrganizeBySection(course.id, next);
                                  },
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Flexible(
                                child: Text(
                                  'Subcarpeta por sección',
                                  style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 11),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _TopActionButton(
                        label: 'Marcar ramo',
                        onTap: () => _toggleCourseSelection(course, true),
                      ),
                      const SizedBox(width: 8),
                      _TopActionButton(
                        label: 'Desmarcar',
                        onTap: () => _toggleCourseSelection(course, false),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Contenido de secciones
            if (course.scanError != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Error: ${course.scanError}',
                  style: const TextStyle(color: Color(0xFFF87171), fontSize: 12),
                ),
              )
            else if (sectionsMap.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Sin elementos para este filtro.',
                  style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: sectionsMap.entries.map((entry) {
                    final secName = entry.key;
                    final secItems = entry.value;
                    final secKey = '${course.id}::$secName';
                    final isSecExpanded = _expandedSections.contains(secKey);

                    final downloadableInSec =
                        secItems.where((i) => i.downloadable).toList();
                    final allSecSelected = downloadableInSec.isNotEmpty &&
                        downloadableInSec.every((i) => i.isSelected);

                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F0F12),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFF2A2A33)),
                      ),
                      child: Column(
                        children: [
                          InkWell(
                            onTap: () async {
                              final opening = !isSecExpanded;
                              setState(() {
                                if (opening) {
                                  _expandedSections.add(secKey);
                                } else {
                                  _expandedSections.remove(secKey);
                                }
                              });
                              if (opening) {
                                final updated = await widget.moodleService
                                    .fetchMissingFileSizes(secItems);
                                if (updated && mounted) setState(() {});
                              }
                            },
                            borderRadius: BorderRadius.circular(6),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 7),
                              child: Row(
                                children: [
                                  Icon(
                                    isSecExpanded
                                        ? Icons.keyboard_arrow_down
                                        : Icons.keyboard_arrow_right,
                                    color: const Color(0xFF9CA3AF),
                                    size: 18,
                                  ),
                                  if (downloadableInSec.isNotEmpty)
                                    SizedBox(
                                      width: 28,
                                      height: 24,
                                      child: Checkbox(
                                        value: allSecSelected,
                                        activeColor: const Color(0xFF22C55E),
                                        onChanged: (v) => _toggleSectionSelection(
                                            secItems, v ?? false),
                                      ),
                                    ),
                                  Expanded(
                                    child: Text(
                                      secName,
                                      style: const TextStyle(
                                        color: Color(0xFFF3F4F6),
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '${secItems.length} elem.',
                                    style: const TextStyle(
                                        color: Color(0xFF9CA3AF), fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (isSecExpanded) ...[
                            const Divider(color: Color(0xFF2A2A33), height: 1),
                            ...secItems.map((item) => _buildItemRow(item)),
                          ],
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildItemRow(MoodleItem item) {
    final sizeText = item.formattedSize;

    Color badgeColor;
    Color badgeBorder;
    String badgeText;
    if (item.downloadable) {
      if (item.isDownloaded) {
        badgeColor = const Color(0xFF86EFAC);
        badgeBorder = const Color(0x5922C55E);
        badgeText = 'En carpeta';
      } else {
        badgeColor = const Color(0xFFFACC15);
        badgeBorder = const Color(0x66EAB308);
        badgeText = 'Pendiente';
      }
    } else {
      badgeColor = const Color(0xFF9CA3AF);
      badgeBorder = const Color(0xFF2A2A33);
      badgeText = item.typeLabel;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF1E1E24))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (item.downloadable)
            SizedBox(
              width: 28,
              height: 24,
              child: Checkbox(
                value: item.isSelected,
                activeColor: const Color(0xFF22C55E),
                onChanged: (val) =>
                    setState(() => item.isSelected = val ?? false),
              ),
            )
          else
            const SizedBox(
              width: 28,
              child: Icon(Icons.link, size: 15, color: Color(0xFF6B7280)),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFF3F4F6), fontSize: 12.5),
                ),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (sizeText.isNotEmpty)
                      Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(color: const Color(0xFF2A2A33)),
                        ),
                        child: Text(
                          sizeText,
                          style: const TextStyle(
                              color: Color(0xFF9CA3AF), fontSize: 10),
                        ),
                      ),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: badgeBorder),
                      ),
                      child: Text(
                        badgeText,
                        style: TextStyle(color: badgeColor, fontSize: 10),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          OutlinedButton(
            onPressed: () => _openItemUrl(item),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF2A2A33)),
              foregroundColor: const Color(0xFFF3F4F6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
            child: const Text('Abrir', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }
}

class _TopActionButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool isDanger;

  const _TopActionButton({
    required this.label,
    required this.onTap,
    this.isDanger = false,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        side: BorderSide(
          color: isDanger ? const Color(0x66EF4444) : const Color(0xFF2A2A33),
        ),
        foregroundColor:
            isDanger ? const Color(0xFFF87171) : const Color(0xFFF3F4F6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 11.5)),
    );
  }
}

class _FilterTabBtn extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _FilterTabBtn({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 5),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF17171C) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: active ? const Color(0xFFF3F4F6) : const Color(0xFF9CA3AF),
            ),
          ),
        ),
      ),
    );
  }
}
