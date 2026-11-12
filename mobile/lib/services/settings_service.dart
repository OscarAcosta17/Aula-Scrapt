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

  String _downloadRoot = '';
  Map<String, String> _courseFolders = {};
  Map<String, String> _courseSubfolders = {};
  Map<String, bool> _courseOrgBySection = {};
  Map<String, dynamic> _history = {
    'downloaded_ids': <String, dynamic>{},
    'seen_ids': <String, dynamic>{},
    'file_sizes': <String, dynamic>{},
  };

  String get downloadRoot => _downloadRoot;
  Map<String, dynamic> get history => _history;

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
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF17171C),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFF2A2A33)),
          ),
          title: const Text(
            'Permiso de almacenamiento requerido',
            style: TextStyle(color: Color(0xFFF3F4F6), fontSize: 16, fontWeight: FontWeight.w600),
          ),
          content: const Text(
            'Android 11 o superior requiere habilitar el permiso "Acceso a todos los archivos" para que Aula-Scrapt pueda guardar PDFs y notas .md en la carpeta que elijas (como Documentos o tu bóveda de Obsidian).\n\nEn la siguiente pantalla activa el interruptor de Aula-Scrapt y vuelve atrás.',
            style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13, height: 1.45),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar', style: TextStyle(color: Color(0xFF9CA3AF))),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFF3F4F6),
                foregroundColor: const Color(0xFF0F0F12),
              ),
              child: const Text('Conceder permiso', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
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
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF17171C),
            title: const Text('Permiso denegado', style: TextStyle(color: Colors.white, fontSize: 16)),
            content: const Text(
              'Habilita el permiso de Almacenamiento en Ajustes de la aplicación para descargar archivos.',
              style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cerrar'),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  openAppSettings();
                },
                child: const Text('Abrir Ajustes'),
              ),
            ],
          ),
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
