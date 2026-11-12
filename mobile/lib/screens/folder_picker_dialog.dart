import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../services/settings_service.dart';

/// Abre un selector completo de carpeta para Android (accesos rápidos, explorador de directorios,
/// creación de carpetas, selector nativo del sistema y edición manual).
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
    backgroundColor: const Color(0xFF17171C),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      side: BorderSide(color: Color(0xFF2A2A33)),
    ),
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
      err = 'No se puede explorar esta carpeta (${e.message}). Concede permiso de almacenamiento o usa otra ruta.';
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
        backgroundColor: const Color(0xFF17171C),
        title: const Text('Nueva carpeta', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Ej: Obsidian o Ramos',
            hintStyle: TextStyle(color: Color(0xFF6B7280)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text.trim()),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF3F4F6),
              foregroundColor: const Color(0xFF0F0F12),
            ),
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
            SnackBar(content: Text('No se pudo crear la carpeta: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final parentPath = p.dirname(_currentPath);
    final canGoUp = parentPath != _currentPath && _currentPath != '/';

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Elegir carpeta de destino',
                      style: TextStyle(
                        color: Color(0xFFF3F4F6),
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF9CA3AF)),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(color: Color(0xFF2A2A33), height: 1),

            if (!_hasPermission && Platform.isAndroid)
              Container(
                color: const Color(0x33EAB308),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Permiso "Todos los archivos" desactivado.',
                        style: TextStyle(color: Color(0xFFFACC15), fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        await widget.settingsService.ensureStoragePermission(context);
                        await _loadDir(_currentPath);
                      },
                      child: const Text('Activar', style: TextStyle(color: Color(0xFFFACC15))),
                    ),
                  ],
                ),
              ),

            // Accesos rápidos + selector sistema
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _QuickPathChip(
                      label: 'Documents/Obsidian',
                      onTap: () => _loadDir('${widget.extRoot}/Documents/Obsidian'),
                    ),
                    const SizedBox(width: 8),
                    _QuickPathChip(
                      label: 'Documents/Aula-USM',
                      onTap: () => _loadDir('${widget.extRoot}/Documents/Aula-USM'),
                    ),
                    const SizedBox(width: 8),
                    _QuickPathChip(
                      label: 'Download/Aula-USM',
                      onTap: () => _loadDir('${widget.extRoot}/Download/Aula-USM'),
                    ),
                    const SizedBox(width: 8),
                    _QuickPathChip(
                      label: 'Selector del sistema...',
                      icon: Icons.folder_open,
                      onTap: () async {
                        final picked =
                            await widget.settingsService.pickNativeAndroidDirectory();
                        if (picked != null && picked.isNotEmpty) {
                          await _loadDir(picked);
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    _QuickPathChip(
                      label: 'Carpeta interna app',
                      onTap: () async {
                        final d = await getExternalStorageDirectory() ??
                            await getApplicationDocumentsDirectory();
                        await _loadDir(p.join(d.path, 'Aula-USM'));
                      },
                    ),
                  ],
                ),
              ),
            ),

            // Input ruta manual + acciones carpeta actual
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.arrow_upward,
                      size: 18,
                      color: canGoUp ? const Color(0xFFF3F4F6) : const Color(0xFF4B5563),
                    ),
                    tooltip: 'Subir un nivel',
                    onPressed: canGoUp ? () => _loadDir(parentPath) : null,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _pathCtrl,
                      style: const TextStyle(color: Color(0xFFF3F4F6), fontSize: 12),
                      onSubmitted: (val) => _loadDir(val.trim()),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: const Color(0xFF0F0F12),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(color: Color(0xFF2A2A33)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(6),
                          borderSide: const BorderSide(color: Color(0xFF2A2A33)),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.create_new_folder_outlined,
                        size: 20, color: Color(0xFF38BDF8)),
                    tooltip: 'Crear nueva carpeta aquí',
                    onPressed: _createNewFolder,
                  ),
                ],
              ),
            ),

            // Lista de subcarpetas
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF38BDF8)))
                  : _errorText != null && _subdirs.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(20),
                          child: Center(
                            child: Text(
                              _errorText!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 12),
                            ),
                          ),
                        )
                      : _subdirs.isEmpty
                          ? const Center(
                              child: Text(
                                'Carpeta sin subcarpetas.',
                                style: TextStyle(color: Color(0xFF6B7280), fontSize: 12),
                              ),
                            )
                          : ListView.separated(
                              itemCount: _subdirs.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(color: Color(0xFF2A2A33), height: 1),
                              itemBuilder: (ctx, idx) {
                                final d = _subdirs[idx];
                                return ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.folder, color: Color(0xFF38BDF8), size: 20),
                                  title: Text(
                                    p.basename(d.path),
                                    style: const TextStyle(color: Color(0xFFF3F4F6), fontSize: 13),
                                  ),
                                  trailing: const Icon(Icons.chevron_right,
                                      color: Color(0xFF6B7280), size: 18),
                                  onTap: () => _loadDir(d.path),
                                );
                              },
                            ),
            ),

            // Footer botones
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              decoration: const BoxDecoration(
                color: Color(0xFF1E1E24),
                border: Border(top: BorderSide(color: Color(0xFF2A2A33))),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF2A2A33)),
                        foregroundColor: const Color(0xFFF3F4F6),
                      ),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton(
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
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF3F4F6),
                        foregroundColor: const Color(0xFF0F0F12),
                      ),
                      child: const Text('Usar esta carpeta',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickPathChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  const _QuickPathChip({
    required this.label,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF0F0F12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF2A2A33)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: const Color(0xFF38BDF8)),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: const TextStyle(color: Color(0xFFF3F4F6), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
