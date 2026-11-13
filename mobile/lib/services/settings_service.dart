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
  static const String _keyDownloadedIds = 'downloaded_ids_json';
  static const String _keyThemeMode = 'settings_theme_mode';
  static const String _keyUseDynamicColor = 'settings_use_dynamic_color';
  static const String _keyAccentSeed = 'settings_accent_seed';
  static const String _keyAutoCheckUpdates = 'settings_auto_check_updates';
  static const String _keyAutoCheckUpdatesMirror = 'auto_check_updates';
  static const String _keyBetaUpdates = 'settings_beta_updates';
  static const String _keyDefaultSubfolder = 'settings_default_subfolder';
  static const String _keyDefaultOrgSection = 'settings_default_org_section';
  static const String _keySkipDownloaded = 'settings_skip_downloaded';
  static const String _keySkipSeen = 'settings_skip_seen';
  static const String _keyAutoExportLinks = 'settings_auto_export_links';
  static const String _keyAutoExportForums = 'settings_auto_export_forums';
  static const String _keyDefaultFilter = 'settings_default_filter';
  static const String _keyHideEmptySections = 'settings_hide_empty_sections';
  static const String _keyHiddenCourses = 'hidden_courses_json';
  static const String _keyPreferredExts = 'settings_preferred_extensions';
  static const String _keyMaxAutoMb = 'settings_max_auto_mb';
  static const String _keyNotifyNative = 'notify_native_enabled';
  static const String _keyNotifyNewFiles = 'notify_on_new_files';
  static const String _keyNotifyDeadlines = 'notify_on_deadlines';
  static const String _keyNotifyDownloadDone = 'notify_on_download_done';
  static const String _keyBgSyncHours = 'background_sync_hours';
  static const String _keyNotificationsHistory = 'notifications_history_json';
  static const String _keyKnownItemIds = 'known_item_ids_json';

  static const String sharedIndexFileName = '.aula-scrapt-index.json';
  static const int maxNotifications = 80;

  static const Map<String, Color> accentPalette = {
    'sky': Color(0xFF38BDF8),
    'emerald': Color(0xFF10B981),
    'violet': Color(0xFF8B5CF6),
    'amber': Color(0xFFF59E0B),
    'rose': Color(0xFFF43F5E),
  };

  final ValueNotifier<int> themeNotifier = ValueNotifier<int>(0);
  final ValueNotifier<int> notificationsNotifier = ValueNotifier<int>(0);

  String _downloadRoot = '';
  ThemeMode _themeMode = ThemeMode.system;
  bool _useDynamicColor = true;
  String _accentSeedKey = 'sky';
  Color? _cachedSystemSeedColor;
  bool _betaUpdatesChannel = false;
  String _defaultSubfolder = 'Aula';
  bool _defaultOrganizeBySection = true;
  bool _skipAlreadyDownloaded = true;
  bool _skipSeenOnSelect = false;
  bool _autoExportLinksToObsidian = true;
  bool _autoExportForumsToObsidian = true;
  String _defaultFilterKey = 'files';
  bool _hideEmptySections = true;
  Set<int> _hiddenCourseIds = {};
  List<String> _preferredExtensions = [];
  int _maxAutoSelectMb = 0;
  bool _notifyNativeEnabled = true;
  bool _notifyOnNewFiles = true;
  bool _notifyOnDeadlines = true;
  bool _notifyOnDownloadDone = true;
  int _backgroundSyncHours = 6;
  Map<String, String> _courseFolders = {};
  Map<String, String> _courseSubfolders = {};
  Map<String, bool> _courseOrgBySection = {};
  Map<String, dynamic> _history = {
    'downloaded_ids': <String, dynamic>{},
    'seen_ids': <String, dynamic>{},
    'file_sizes': <String, dynamic>{},
  };
  List<Map<String, dynamic>> _notifications = [];

  String get downloadRoot => _downloadRoot;
  ThemeMode get themeMode => _themeMode;
  bool get useDynamicColor => _useDynamicColor;
  String get accentSeedKey => _accentSeedKey;
  Color get accentSeedColor => accentPalette[_accentSeedKey] ?? accentPalette['sky']!;
  Color? get systemSeedColor => _cachedSystemSeedColor;
  bool get betaUpdatesChannel => _betaUpdatesChannel;
  String get defaultSubfolder => _defaultSubfolder;
  bool get defaultOrganizeBySection => _defaultOrganizeBySection;
  bool get skipAlreadyDownloaded => _skipAlreadyDownloaded;
  bool get skipSeenOnSelect => _skipSeenOnSelect;
  bool get autoExportLinksToObsidian => _autoExportLinksToObsidian;
  bool get autoExportForumsToObsidian => _autoExportForumsToObsidian;
  String get defaultFilterKey => _defaultFilterKey;
  bool get hideEmptySections => _hideEmptySections;
  Set<int> get hiddenCourseIds => Set<int>.unmodifiable(_hiddenCourseIds);
  List<String> get preferredExtensions => List<String>.unmodifiable(_preferredExtensions);
  int get maxAutoSelectMb => _maxAutoSelectMb;
  bool get notifyNativeEnabled => _notifyNativeEnabled;
  bool get notifyOnNewFiles => _notifyOnNewFiles;
  bool get notifyOnDeadlines => _notifyOnDeadlines;
  bool get notifyOnDownloadDone => _notifyOnDownloadDone;
  int get backgroundSyncHours => _backgroundSyncHours;
  Map<String, dynamic> get history => _history;
  List<Map<String, dynamic>> get notifications => List<Map<String, dynamic>>.unmodifiable(_notifications);
  int get unreadNotificationsCount => _notifications.where((n) => n['read'] != true).length;

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
    try {
      await prefs.reload();
    } catch (_) {}
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
    final savedAccent = prefs.getString(_keyAccentSeed);
    if (savedAccent != null && accentPalette.containsKey(savedAccent)) {
      _accentSeedKey = savedAccent;
    }
    _autoCheckUpdates = prefs.getBool(_keyAutoCheckUpdates) ?? true;
    await prefs.setBool(_keyAutoCheckUpdatesMirror, _autoCheckUpdates);
    _betaUpdatesChannel = prefs.getBool(_keyBetaUpdates) ?? false;

    _defaultSubfolder = prefs.getString(_keyDefaultSubfolder) ?? 'Aula';
    _defaultOrganizeBySection = prefs.getBool(_keyDefaultOrgSection) ?? true;
    _skipAlreadyDownloaded = prefs.getBool(_keySkipDownloaded) ?? true;
    _skipSeenOnSelect = prefs.getBool(_keySkipSeen) ?? false;
    _autoExportLinksToObsidian = prefs.getBool(_keyAutoExportLinks) ?? true;
    _autoExportForumsToObsidian = prefs.getBool(_keyAutoExportForums) ?? true;
    _defaultFilterKey = prefs.getString(_keyDefaultFilter) ?? 'files';
    _hideEmptySections = prefs.getBool(_keyHideEmptySections) ?? true;
    _hiddenCourseIds = _decodeIntSet(prefs.getString(_keyHiddenCourses));
    _preferredExtensions = _decodeStringList(prefs.getString(_keyPreferredExts));
    _maxAutoSelectMb = prefs.getInt(_keyMaxAutoMb) ?? 0;

    _notifyNativeEnabled = prefs.getBool(_keyNotifyNative) ?? true;
    _notifyOnNewFiles = prefs.getBool(_keyNotifyNewFiles) ?? true;
    _notifyOnDeadlines = prefs.getBool(_keyNotifyDeadlines) ?? true;
    _notifyOnDownloadDone = prefs.getBool(_keyNotifyDownloadDone) ?? true;
    _backgroundSyncHours = prefs.getInt(_keyBgSyncHours) ?? 6;
    // Asegurar que las claves por defecto existan para BackgroundSyncWorker
    await prefs.setBool(_keyNotifyNative, _notifyNativeEnabled);
    await prefs.setBool(_keyNotifyNewFiles, _notifyOnNewFiles);
    await prefs.setBool(_keyNotifyDeadlines, _notifyOnDeadlines);

    _notifications = _decodeNotifications(prefs.getString(_keyNotificationsHistory));
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
    await prefs.setString(
      _keyDownloadedIds,
      json.encode(_history['downloaded_ids'] ?? {}),
    );
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

  Future<void> setAccentSeedKey(String key) async {
    if (!accentPalette.containsKey(key)) return;
    _accentSeedKey = key;
    themeNotifier.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyAccentSeed, key);
  }

  bool _autoCheckUpdates = true;
  bool get autoCheckUpdates => _autoCheckUpdates;

  Future<void> setAutoCheckUpdates(bool value) async {
    _autoCheckUpdates = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoCheckUpdates, value);
    await prefs.setBool(_keyAutoCheckUpdatesMirror, value);
  }

  Future<void> setBetaUpdatesChannel(bool value) async {
    _betaUpdatesChannel = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBetaUpdates, value);
  }

  Future<void> setDefaultSubfolder(String value) async {
    _defaultSubfolder = value.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDefaultSubfolder, _defaultSubfolder);
  }

  Future<void> setDefaultOrganizeBySection(bool value) async {
    _defaultOrganizeBySection = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyDefaultOrgSection, value);
  }

  Future<void> setSkipAlreadyDownloaded(bool value) async {
    _skipAlreadyDownloaded = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySkipDownloaded, value);
  }

  Future<void> setSkipSeenOnSelect(bool value) async {
    _skipSeenOnSelect = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keySkipSeen, value);
  }

  Future<void> setAutoExportLinksToObsidian(bool value) async {
    _autoExportLinksToObsidian = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoExportLinks, value);
  }

  Future<void> setAutoExportForumsToObsidian(bool value) async {
    _autoExportForumsToObsidian = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoExportForums, value);
  }

  Future<void> setDefaultFilterKey(String key) async {
    if (!{'files', 'pending', 'deadlines', 'all'}.contains(key)) return;
    _defaultFilterKey = key;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyDefaultFilter, key);
  }

  Future<void> setHideEmptySections(bool value) async {
    _hideEmptySections = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyHideEmptySections, value);
  }

  bool isCourseHidden(int courseId) => _hiddenCourseIds.contains(courseId);

  Future<void> setCourseHidden(int courseId, bool hidden) async {
    if (hidden) {
      _hiddenCourseIds.add(courseId);
    } else {
      _hiddenCourseIds.remove(courseId);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyHiddenCourses, json.encode(_hiddenCourseIds.toList()));
  }

  Future<void> setPreferredExtensions(List<String> exts) async {
    _preferredExtensions = exts
        .map((e) => e.trim().toLowerCase().replaceFirst('.', ''))
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPreferredExts, json.encode(_preferredExtensions));
  }

  Future<void> setMaxAutoSelectMb(int mb) async {
    _maxAutoSelectMb = mb < 0 ? 0 : mb;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyMaxAutoMb, _maxAutoSelectMb);
  }

  Future<void> setNotifyNativeEnabled(bool value) async {
    _notifyNativeEnabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyNotifyNative, value);
  }

  Future<void> setNotifyOnNewFiles(bool value) async {
    _notifyOnNewFiles = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyNotifyNewFiles, value);
  }

  Future<void> setNotifyOnDeadlines(bool value) async {
    _notifyOnDeadlines = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyNotifyDeadlines, value);
  }

  Future<void> setNotifyOnDownloadDone(bool value) async {
    _notifyOnDownloadDone = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyNotifyDownloadDone, value);
  }

  Future<void> setBackgroundSyncHours(int hours) async {
    _backgroundSyncHours = hours;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyBgSyncHours, hours);
    await scheduleBackgroundSync(hours);
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

  Set<int> _decodeIntSet(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final list = json.decode(raw) as List;
      return list.map((e) => int.tryParse(e.toString()) ?? -1).where((e) => e > 0).toSet();
    } catch (_) {
      return {};
    }
  }

  List<String> _decodeStringList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw) as List;
      return list.map((e) => e.toString().trim().toLowerCase()).where((e) => e.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  List<Map<String, dynamic>> _decodeNotifications(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw) as List;
      return list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .take(maxNotifications)
          .toList();
    } catch (_) {
      return [];
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
      _courseSubfolders[courseId.toString()] ?? _defaultSubfolder;

  bool getCourseOrganizeBySection(int courseId) =>
      _courseOrgBySection[courseId.toString()] ?? _defaultOrganizeBySection;

  Future<void> saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyHistory, json.encode(_history));
    await prefs.setString(
      _keyDownloadedIds,
      json.encode(_history['downloaded_ids'] ?? {}),
    );
  }

  /// Importa carpetas y reglas recibidas mediante emparejamiento QR / PIN desde PC
  Future<void> applyPairedSettings(Map<String, dynamic> rawPayload) async {
    final payload = rawPayload['settings'] is Map
        ? Map<String, dynamic>.from(rawPayload['settings'] as Map)
        : rawPayload;

    final courseFoldersRaw = payload['course_folders'];
    if (courseFoldersRaw is Map) {
      courseFoldersRaw.forEach((k, v) {
        final key = k.toString().trim();
        final val = v.toString().trim();
        if (key.isNotEmpty && val.isNotEmpty) {
          _courseFolders[key] = val;
        }
      });
    }

    final courseSubfoldersRaw = payload['course_subfolders'];
    if (courseSubfoldersRaw is Map) {
      courseSubfoldersRaw.forEach((k, v) {
        final key = k.toString().trim();
        final val = v.toString().trim();
        if (key.isNotEmpty) {
          _courseSubfolders[key] = val;
        }
      });
    }

    final courseOrgRaw =
        payload['course_org_sections'] ?? payload['course_organize_by_section'];
    if (courseOrgRaw is Map) {
      courseOrgRaw.forEach((k, v) {
        final key = k.toString().trim();
        if (key.isNotEmpty && v is bool) {
          _courseOrgBySection[key] = v;
        }
      });
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyCourseFolders, json.encode(_courseFolders));
    await prefs.setString(_keyCourseSubfolders, json.encode(_courseSubfolders));
    await prefs.setString(_keyCourseOrgSection, json.encode(_courseOrgBySection));

    final saveRules = payload['save_rules'] is Map
        ? Map<String, dynamic>.from(payload['save_rules'] as Map)
        : payload;
    if (saveRules['default_subfolder'] is String) {
      await setDefaultSubfolder(saveRules['default_subfolder'] as String);
    }
    if (saveRules['default_organize_by_section'] is bool) {
      await setDefaultOrganizeBySection(
        saveRules['default_organize_by_section'] as bool,
      );
    }
    if (saveRules['skip_already_downloaded'] is bool) {
      await setSkipAlreadyDownloaded(
        saveRules['skip_already_downloaded'] as bool,
      );
    }
    if (saveRules['skip_seen_on_select'] is bool) {
      await setSkipSeenOnSelect(saveRules['skip_seen_on_select'] as bool);
    }
    if (saveRules['auto_export_links_to_obsidian'] is bool) {
      await setAutoExportLinksToObsidian(
        saveRules['auto_export_links_to_obsidian'] as bool,
      );
    }
    if (saveRules['auto_export_forums_to_obsidian'] is bool) {
      await setAutoExportForumsToObsidian(
        saveRules['auto_export_forums_to_obsidian'] as bool,
      );
    }
    if (saveRules['preferred_extensions'] is List) {
      await setPreferredExtensions(
        (saveRules['preferred_extensions'] as List).map((e) => e.toString()).toList(),
      );
    }
    if (saveRules['max_auto_select_mb'] is num) {
      await setMaxAutoSelectMb((saveRules['max_auto_select_mb'] as num).toInt());
    }

    final viewPrefs = payload['view_preferences'] is Map
        ? Map<String, dynamic>.from(payload['view_preferences'] as Map)
        : payload;
    if (viewPrefs['hide_empty_sections'] is bool) {
      await setHideEmptySections(viewPrefs['hide_empty_sections'] as bool);
    }
    if (viewPrefs['hidden_courses'] is List) {
      for (final cid in viewPrefs['hidden_courses'] as List) {
        final parsed = int.tryParse(cid.toString());
        if (parsed != null && parsed > 0) _hiddenCourseIds.add(parsed);
      }
      await prefs.setString(_keyHiddenCourses, json.encode(_hiddenCourseIds.toList()));
    }
  }

  /// Índice compartido PC <-> Android guardado estrictamente dentro de downloadRoot
  Future<Map<String, dynamic>> loadSharedIndex() async {
    try {
      final rootDir = Directory(_downloadRoot);
      if (!await rootDir.exists()) return {'version': 1, 'items': <String, dynamic>{}};
      final file = File(p.join(_downloadRoot, sharedIndexFileName));
      if (!await file.exists()) return {'version': 1, 'items': <String, dynamic>{}};
      final decoded = json.decode(await file.readAsString());
      if (decoded is Map<String, dynamic>) {
        return {
          'version': decoded['version'] ?? 1,
          'items': Map<String, dynamic>.from(decoded['items'] ?? {}),
        };
      }
    } catch (_) {}
    return {'version': 1, 'items': <String, dynamic>{}};
  }

  Future<void> recordSharedIndexEntries(List<Map<String, dynamic>> entries) async {
    if (entries.isEmpty) return;
    try {
      final rootDir = Directory(_downloadRoot);
      if (!await rootDir.exists()) return;
      final index = await loadSharedIndex();
      final items = Map<String, dynamic>.from(index['items'] ?? {});
      final rootNorm = p.normalize(rootDir.absolute.path);

      for (final entry in entries) {
        final itemId = entry['item_id']?.toString() ?? '';
        final fullPath = entry['full_path']?.toString() ?? '';
        if (itemId.isEmpty || fullPath.isEmpty) continue;
        final absFile = p.normalize(File(fullPath).absolute.path);
        if (!p.isWithin(rootNorm, absFile)) continue;
        final relPath = p.relative(absFile, from: rootNorm).replaceAll('\\', '/');
        items[itemId] = {
          'relative_path': relPath,
          'filename': entry['filename'] ?? p.basename(absFile),
          'title': entry['title'] ?? '',
          'course_id': entry['course_id'],
          'source': 'android',
          'updated_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        };
      }

      index['items'] = items;
      index['updated_at'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final outFile = File(p.join(_downloadRoot, sharedIndexFileName));
      await outFile.writeAsString(const JsonEncoder.withIndent('  ').convert(index));
    } catch (_) {}
  }

  /// Guarda el último escaneo completo para arranque instantáneo offline
  Future<void> saveScanCache(List<MoodleCourse> courses) async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      final cacheFile = File(p.join(supportDir.path, 'scan_cache.json'));
      final payload = {
        'version': 1,
        'cached_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'courses': courses.map((c) => c.toJson()).toList(),
      };
      await cacheFile.writeAsString(json.encode(payload));
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> loadScanCache() async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      final cacheFile = File(p.join(supportDir.path, 'scan_cache.json'));
      if (!await cacheFile.exists()) return null;
      final decoded = json.decode(await cacheFile.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      final rawCourses = decoded['courses'];
      if (rawCourses is! List) return null;
      final parsedCourses = rawCourses
          .whereType<Map>()
          .map((m) => MoodleCourse.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      return {
        'cachedAt': decoded['cached_at'] as int? ?? 0,
        'courses': parsedCourses,
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> saveKnownItemIds(Iterable<String> itemIds) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final unique = itemIds.where((id) => id.isNotEmpty).toSet().take(5000).toList();
      await prefs.setString(_keyKnownItemIds, json.encode(unique));
    } catch (_) {}
  }

  Future<void> reloadNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.reload();
    } catch (_) {}
    _notifications = _decodeNotifications(prefs.getString(_keyNotificationsHistory));
    notificationsNotifier.value++;
  }

  Future<bool> addNotification({
    required String title,
    required String body,
    String kind = 'info',
    String courseName = '',
    String dedupKey = '',
    bool triggerNative = false,
    String nativeChannelId = 'aula_new_files',
  }) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.reload();
    } catch (_) {}
    _notifications = _decodeNotifications(prefs.getString(_keyNotificationsHistory));

    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (dedupKey.isNotEmpty) {
      final existsRecent = _notifications.any((n) {
        if (n['dedup_key'] != dedupKey) return false;
        final createdAt = (n['created_at'] as num?)?.toInt() ?? 0;
        return (nowSec - createdAt) < 18 * 3600;
      });
      if (existsRecent) return false;
    }

    final entry = <String, dynamic>{
      'id': '${nowSec}_${_notifications.length}_${dedupKey.hashCode.abs()}',
      'title': title,
      'body': body,
      'kind': kind,
      'course_name': courseName,
      'dedup_key': dedupKey,
      'created_at': nowSec,
      'read': false,
    };

    _notifications = [entry, ..._notifications].take(maxNotifications).toList();
    await prefs.setString(_keyNotificationsHistory, json.encode(_notifications));
    notificationsNotifier.value++;

    if (triggerNative && _notifyNativeEnabled) {
      await showNativeNotification(
        title: title,
        body: body,
        channelId: nativeChannelId,
      );
    }
    return true;
  }

  Future<void> markAllNotificationsRead() async {
    _notifications = _notifications
        .map((n) => {...n, 'read': true})
        .toList();
    notificationsNotifier.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyNotificationsHistory, json.encode(_notifications));
  }

  Future<void> clearNotifications() async {
    _notifications = [];
    notificationsNotifier.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyNotificationsHistory, '[]');
  }

  Future<bool> openLocalFile(String filePath) async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('openLocalFile', {'path': filePath});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<String?> computeFileSha256(String filePath) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('computeFileSha256', {'path': filePath});
    } catch (_) {
      return null;
    }
  }

  Future<bool> hasNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final ok = await _channel.invokeMethod<bool>('hasNotificationPermission');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final ok = await _channel.invokeMethod<bool>('requestNotificationPermission');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> showNativeNotification({
    required String title,
    required String body,
    String channelId = 'aula_new_files',
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('showNativeNotification', {
        'title': title,
        'body': body,
        'channelId': channelId,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> scheduleBackgroundSync(int intervalHours) async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('scheduleBackgroundSync', {
        'intervalHours': intervalHours,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<String?> scanQrCode() async {
    if (!Platform.isAndroid) return null;
    return await _channel.invokeMethod<String>('scanQrCode');
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
