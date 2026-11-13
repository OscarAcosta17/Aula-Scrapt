import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/course.dart';

class StoragePermissionException implements Exception {
  final String message;
  StoragePermissionException(this.message);
  @override
  String toString() => message;
}

class SettingsService {
  static const MethodChannel _channel = MethodChannel('cl.usm.aulascrapt/storage');

  static const String _keyDownloadRoot = 'settings_download_root';
  static const String _keyCourseFolders = 'settings_course_folders';
  static const String _keyCourseSubfolders = 'settings_course_subfolders';
  static const String _keyCourseOrgSection = 'settings_course_org_section';
  static const String _keyHistory = 'download_history_json';
  static const String _keyThemeMode = 'settings_theme_mode';
  static const String _keyUseDynamicColor = 'settings_use_dynamic_color';
  static const String _keyAutoCheckUpdates = 'settings_auto_check_updates';

  final ValueNotifier<int> themeNotifier = ValueNotifier<int>(0);

  String _downloadRoot = '';
  ThemeMode _themeMode = ThemeMode.system;
  bool _useDynamicColor = true;
  Color? _cachedSystemSeedColor;
  Map<String, String> _courseFolders = {};
  Map<String, String> _courseSubfolders = {};
  Map<String, bool> _courseOrgBySection = {};
  Map<String, dynamic> _history = {
    'downloaded_ids': <String, dynamic>{},
    'seen_ids': <String, dynamic>{},
    'file_sizes': <String, dynamic>{},
  };

  String get downloadRoot => _downloadRoot;
  ThemeMode get themeMode => _themeMode;
  bool get useDynamicColor => _useDynamicColor;
  Color? get systemSeedColor => _cachedSystemSeedColor;
  Map<String, dynamic> get history => _history;

  /// Versión compacta legible de la ruta de guardado para tarjetas móviles
  String get shortDownloadRoot {
    if (_downloadRoot.startsWith('/storage/emulated/0/')) {
      return _downloadRoot.substring('/storage/emulated/0/'.length);
    }
    if (_downloadRoot == '/storage/emulated/0') return 'Almacenamiento interno';
    return _downloadRoot;
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final savedRoot = prefs.getString(_keyDownloadRoot);

    if (savedRoot != null && savedRoot.trim().isNotEmpty) {
      _downloadRoot = savedRoot.trim();
    } else if (Platform.isAndroid) {
      final obsidianDefault = Directory('/storage/emulated/0/Documents/Obsidian');
      if (await obsidianDefault.exists()) {
        _downloadRoot = obsidianDefault.path;
      } else {
        _downloadRoot = '/storage/emulated/0/Documents/Aula-USM';
      }
    } else {
      final doc = await getApplicationDocumentsDirectory();
      _downloadRoot = p.join(doc.path, 'Aula-USM');
    }

    final savedTheme = prefs.getString(_keyThemeMode);
    _themeMode = switch (savedTheme) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
    _useDynamicColor = prefs.getBool(_keyUseDynamicColor) ?? true;
    _autoCheckUpdates = prefs.getBool(_keyAutoCheckUpdates) ?? true;
    await refreshSystemSeedColor();

    _courseFolders = _decodeStringMap(prefs.getString(_keyCourseFolders));
    _courseSubfolders = _decodeStringMap(prefs.getString(_keyCourseSubfolders));
    _courseOrgBySection = _decodeBoolMap(prefs.getString(_keyCourseOrgSection));

    final histStr = prefs.getString(_keyHistory);
    if (histStr != null && histStr.isNotEmpty) {
      try {
        final decoded = json.decode(histStr) as Map<String, dynamic>;
        _history = {
          'downloaded_ids': Map<String, dynamic>.from(decoded['downloaded_ids'] ?? {}),
          'seen_ids': Map<String, dynamic>.from(decoded['seen_ids'] ?? {}),
          'file_sizes': Map<String, dynamic>.from(decoded['file_sizes'] ?? {}),
        };
      } catch (_) {}
    }
  }

  Future<void> refreshSystemSeedColor() async {
    if (!Platform.isAndroid) return;
    try {
      final raw = await _channel.invokeMethod<int>('getSystemSeedColor');
      _cachedSystemSeedColor = raw != null ? Color(raw.toUnsigned(32)) : null;
    } catch (_) {
      _cachedSystemSeedColor = null;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    themeNotifier.value++;
    final prefs = await SharedPreferences.getInstance();
    final str = switch (mode) {
      ThemeMode.dark => 'dark',
      ThemeMode.light => 'light',
      ThemeMode.system => 'system',
    };
    await prefs.setString(_keyThemeMode, str);
  }

  Future<void> setUseDynamicColor(bool value) async {
    _useDynamicColor = value;
    await refreshSystemSeedColor();
    themeNotifier.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyUseDynamicColor, value);
  }

  bool _autoCheckUpdates = true;
  bool get autoCheckUpdates => _autoCheckUpdates;

  Future<void> setAutoCheckUpdates(bool value) async {
    _autoCheckUpdates = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoCheckUpdates, value);
  }

  Map<String, String> _decodeStringMap(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, String>.from(json.decode(raw));
    } catch (_) {
      return {};
    }
  }

  Map<String, bool> _decodeBoolMap(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      return Map<String, bool>.from(json.decode(raw));
    } catch (_) {
      return {};
    }
  }

  Future<void> setDownloadRoot(String path) async {
    final clean = path.trim();
    if (clean.isEmpty) return;
    _downloadRoot = clean;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDownloadRoot, _downloadRoot);
  }

  Future<void> setCourseFolder(int courseId, String folderName) async {
    final clean = folderName.trim();
    if (clean.isEmpty) return;
    _courseFolders[courseId.toString()] = clean;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCourseFolders, json.encode(_courseFolders));
  }

  Future<void> setCourseSubfolder(int courseId, String subfolder) async {
    _courseSubfolders[courseId.toString()] = subfolder.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCourseSubfolders, json.encode(_courseSubfolders));
  }

  Future<void> setCourseOrganizeBySection(int courseId, bool value) async {
    _courseOrgBySection[courseId.toString()] = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCourseOrgSection, json.encode(_courseOrgBySection));
  }

  String getCourseSubfolder(int courseId) =>
      _courseSubfolders[courseId.toString()] ?? 'Aula';

  bool getCourseOrganizeBySection(int courseId) =>
      _courseOrgBySection[courseId.toString()] ?? true;

  Future<void> saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyHistory, json.encode(_history));
  }

  Future<int> getAndroidSdkInt() async {
    if (!Platform.isAndroid) return 0;
    try {
      final sdk = await _channel.invokeMethod<int>('getSdkInt');
      return sdk ?? 30;
    } catch (_) {
      return 30;
    }
  }

  Future<String> getExternalRootPath() async {
    if (!Platform.isAndroid) {
      final doc = await getApplicationDocumentsDirectory();
      return doc.path;
    }
    try {
      final root = await _channel.invokeMethod<String>('getExternalRoot');
      if (root != null && root.isNotEmpty) return root;
    } catch (_) {}
    return '/storage/emulated/0';
  }

  /// Verifica si la app tiene permiso para escribir en el almacenamiento elegido
  Future<bool> hasStoragePermission() async {
    if (!Platform.isAndroid) return true;
    final sdk = await getAndroidSdkInt();
    if (sdk >= 30) {
      return await Permission.manageExternalStorage.isGranted;
    } else {
      return await Permission.storage.isGranted;
    }
  }

  /// Solicita permisos de almacenamiento mostrando explicación clara en Android
  Future<bool> ensureStoragePermission(BuildContext context) async {
    if (!Platform.isAndroid) return true;
    final sdk = await getAndroidSdkInt();

    if (sdk >= 30) {
      if (await Permission.manageExternalStorage.isGranted) return true;
      if (!context.mounted) return false;

      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          final cs = Theme.of(ctx).colorScheme;
          return AlertDialog(
            icon: Icon(Icons.folder_copy_rounded, color: cs.primary, size: 28),
            title: const Text('Permiso de almacenamiento'),
            content: const Text(
              'Android 11 o superior requiere habilitar "Acceso a todos los archivos" para guardar PDFs y notas .md en la carpeta que elijas (como Documentos o Obsidian).\n\nEn la siguiente pantalla activa el interruptor de Aula-Scrapt y vuelve atrás.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Conceder permiso'),
              ),
            ],
          );
        },
      );

      if (proceed != true) return false;
      final status = await Permission.manageExternalStorage.request();
      return status.isGranted;
    } else {
      var status = await Permission.storage.status;
      if (status.isGranted) return true;
      status = await Permission.storage.request();
      if (status.isPermanentlyDenied && context.mounted) {
        await showDialog(
          context: context,
          builder: (ctx) {
            final cs = Theme.of(ctx).colorScheme;
            return AlertDialog(
              icon: Icon(Icons.security_rounded, color: cs.error, size: 28),
              title: const Text('Permiso denegado'),
              content: const Text(
                'Habilita el permiso de Almacenamiento en Ajustes de la aplicación para descargar archivos.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cerrar'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    openAppSettings();
                  },
                  child: const Text('Abrir Ajustes'),
                ),
              ],
            );
          },
        );
      }
      return status.isGranted;
    }
  }

  /// Abre el selector nativo de carpetas de Android (ACTION_OPEN_DOCUMENT_TREE)
  Future<String?> pickNativeAndroidDirectory() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('pickDirectory');
    } catch (_) {
      return null;
    }
  }

  /// Lista las subcarpetas existentes dentro de la ruta raíz actual
  Future<List<String>> listExistingSubfolders() async {
    try {
      final rootDir = Directory(_downloadRoot);
      if (!await rootDir.exists()) return [];
      final dirs = <String>[];
      await for (final entity in rootDir.list(followLinks: false)) {
        if (entity is Directory) {
          final name = p.basename(entity.path);
          if (!name.startsWith('.')) {
            dirs.add(name);
          }
        }
      }
      dirs.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return dirs;
    } catch (_) {
      return [];
    }
  }

  /// Determina la carpeta del ramo (configurada manualmente o coincidencia automática en disco)
  String resolveCourseFolderSync(int courseId, String fullname, List<String> existingDirs) {
    final custom = _courseFolders[courseId.toString()];
    if (custom != null && custom.trim().isNotEmpty) {
      return custom.trim();
    }

    final cleanName = MoodleCourse.cleanCourseName(fullname);
    final normCourse = MoodleCourse.normalizeForMatch(cleanName);

    for (final folder in existingDirs) {
      final normFolder = MoodleCourse.normalizeForMatch(folder);
      if (normFolder.isEmpty) continue;
      if (normFolder.contains(normCourse) || normCourse.contains(normFolder)) {
        return folder;
      }
      final words = normFolder
          .split(RegExp(r'[^a-z0-9]+'))
          .where((w) => w.length > 3)
          .toList();
      if (words.isNotEmpty && words.every((w) => normCourse.contains(w))) {
        return folder;
      }
    }

    return MoodleCourse.sanitizeFileName(cleanName);
  }
}
