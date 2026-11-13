import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../services/settings_service.dart';

/// Selector moderno Material 3 Expressive de carpeta para Android
Future<String?> showFolderPickerDialog(
  BuildContext context,
  SettingsService settingsService,
) async {
  await settingsService.ensureStoragePermission(context);
  if (!context.mounted) return null;

  final extRoot = await settingsService.getExternalRootPath();
  var currentPath = settingsService.downloadRoot;
  if (!await Directory(currentPath).exists()) {
    currentPath = Directory(p.dirname(currentPath)).existsSync()
        ? p.dirname(currentPath)
        : extRoot;
  }

  if (!context.mounted) return null;

  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _FolderPickerSheet(
      initialPath: currentPath,
      extRoot: extRoot,
      settingsService: settingsService,
    ),
  );
}

class _FolderPickerSheet extends StatefulWidget {
  final String initialPath;
  final String extRoot;
  final SettingsService settingsService;

  const _FolderPickerSheet({
    required this.initialPath,
    required this.extRoot,
    required this.settingsService,
  });

  @override
  State<_FolderPickerSheet> createState() => _FolderPickerSheetState();
}

class _FolderPickerSheetState extends State<_FolderPickerSheet> {
  late String _currentPath;
  late TextEditingController _pathCtrl;
  List<Directory> _subdirs = [];
  bool _loading = true;
  bool _hasPermission = true;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath;
    _pathCtrl = TextEditingController(text: _currentPath);
    _loadDir(_currentPath);
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDir(String path) async {
    setState(() {
      _loading = true;
      _errorText = null;
      _currentPath = path;
      _pathCtrl.text = path;
    });

    final hasPerm = await widget.settingsService.hasStoragePermission();
    final List<Directory> found = [];
    String? err;

    try {
      final dir = Directory(path);
      if (await dir.exists()) {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is Directory) {
            final name = p.basename(entity.path);
            if (!name.startsWith('.')) {
              found.add(entity);
            }
          }
        }
        found.sort((a, b) =>
            p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));
      } else {
        err = 'La carpeta aún no existe (se creará al descargar o al usarla).';
      }
    } on FileSystemException catch (e) {
      err = 'No se puede explorar esta carpeta (${e.message}). Concede permiso o usa otra ruta.';
    } catch (e) {
      err = e.toString();
    }

    if (mounted) {
      setState(() {
        _hasPermission = hasPerm;
        _subdirs = found;
        _errorText = err;
        _loading = false;
      });
    }
  }

  Future<void> _createNewFolder() async {
    final nameCtrl = TextEditingController();
    final createdName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(
          Icons.create_new_folder_rounded,
          color: Theme.of(ctx).colorScheme.primary,
        ),
        title: const Text('Nueva carpeta'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nombre',
            hintText: 'Ej: Obsidian o Ramos',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
            child: const Text('Crear'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();

    if (createdName != null && createdName.isNotEmpty) {
      try {
        final newDir = Directory(p.join(_currentPath, createdName));
        await newDir.create(recursive: true);
        await _loadDir(newDir.path);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo crear la carpeta: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final parentPath = p.dirname(_currentPath);
    final canGoUp = parentPath != _currentPath && _currentPath != '/';

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.82,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.folder_copy_rounded, color: cs.onPrimaryContainer, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Carpeta de destino',
                    style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          if (!_hasPermission && Platform.isAndroid)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Card(
                color: cs.tertiaryContainer,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline_rounded,
                          color: cs.onTertiaryContainer, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Permiso "Todos los archivos" desactivado.',
                          style: tt.bodySmall?.copyWith(color: cs.onTertiaryContainer),
                        ),
                      ),
                      FilledButton.tonal(
                        onPressed: () async {
                          await widget.settingsService.ensureStoragePermission(context);
                          await _loadDir(_currentPath);
                        },
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(72, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        child: const Text('Activar'),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Accesos rápidos Material 3 ActionChips
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                ActionChip(
                  avatar: const Icon(Icons.auto_stories_outlined, size: 17),
                  label: const Text('Obsidian'),
                  onPressed: () => _loadDir('${widget.extRoot}/Documents/Obsidian'),
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.description_outlined, size: 17),
                  label: const Text('Documents/Aula-USM'),
                  onPressed: () => _loadDir('${widget.extRoot}/Documents/Aula-USM'),
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.download_outlined, size: 17),
                  label: const Text('Download/Aula-USM'),
                  onPressed: () => _loadDir('${widget.extRoot}/Download/Aula-USM'),
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: Icon(Icons.folder_open_rounded, size: 17, color: cs.primary),
                  label: const Text('Archivos de Android'),
                  onPressed: () async {
                    final picked =
                        await widget.settingsService.pickNativeAndroidDirectory();
                    if (picked != null && picked.isNotEmpty) {
                      await _loadDir(picked);
                    }
                  },
                ),
                const SizedBox(width: 8),
                ActionChip(
                  avatar: const Icon(Icons.phone_android_rounded, size: 17),
                  label: const Text('Carpeta interna'),
                  onPressed: () async {
                    final d = await getExternalStorageDirectory() ??
                        await getApplicationDocumentsDirectory();
                    await _loadDir(p.join(d.path, 'Aula-USM'));
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // Barra de ruta + subir / nueva carpeta
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                IconButton.filledTonal(
                  icon: const Icon(Icons.arrow_upward_rounded),
                  tooltip: 'Subir un nivel',
                  onPressed: canGoUp ? () => _loadDir(parentPath) : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _pathCtrl,
                    style: tt.bodySmall?.copyWith(fontFamily: 'monospace'),
                    onSubmitted: (val) => _loadDir(val.trim()),
                    decoration: const InputDecoration(
                      labelText: 'Ruta actual',
                      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  icon: const Icon(Icons.create_new_folder_outlined),
                  tooltip: 'Crear carpeta aquí',
                  onPressed: _createNewFolder,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // Explorador de subcarpetas
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _errorText != null && _subdirs.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _errorText!,
                            textAlign: TextAlign.center,
                            style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ),
                      )
                    : _subdirs.isEmpty
                        ? Center(
                            child: Text(
                              'Sin subcarpetas en esta ubicación.',
                              style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                            itemCount: _subdirs.length,
                            separatorBuilder: (_, _) => const SizedBox(height: 6),
                            itemBuilder: (ctx, idx) {
                              final d = _subdirs[idx];
                              return ListTile(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(18),
                                ),
                                tileColor: cs.surfaceContainerHigh,
                                leading: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: cs.primaryContainer.withValues(alpha: 0.7),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(Icons.folder_rounded,
                                      color: cs.onPrimaryContainer),
                                ),
                                title: Text(
                                  p.basename(d.path),
                                  style: tt.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                                ),
                                trailing: Icon(Icons.chevron_right_rounded,
                                    color: cs.onSurfaceVariant),
                                onTap: () => _loadDir(d.path),
                              );
                            },
                          ),
          ),

          // Footer limpio dentro de SafeArea
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            decoration: BoxDecoration(
              color: cs.surfaceContainer,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: () async {
                        final chosen = _pathCtrl.text.trim();
                        if (chosen.isEmpty) return;
                        try {
                          await Directory(chosen).create(recursive: true);
                        } catch (_) {}
                        if (context.mounted) {
                          Navigator.of(context).pop(chosen);
                        }
                      },
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('Usar esta carpeta'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
