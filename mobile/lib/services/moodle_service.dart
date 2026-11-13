import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/course.dart';
import 'settings_service.dart';

class SessionExpiredException implements Exception {
  final String message;
  SessionExpiredException([this.message = 'La sesión de Aula USM expiró.']);
  @override
  String toString() => message;
}

class DownloadedFileData {
  final List<int> bytes;
  final String filename;
  final int sizeBytes;

  DownloadedFileData({
    required this.bytes,
    required this.filename,
    required this.sizeBytes,
  });
}

class _HttpRedirectResult {
  final int statusCode;
  final Uri finalUri;
  final Map<String, String> headers;
  final List<int> bodyBytes;

  _HttpRedirectResult({
    required this.statusCode,
    required this.finalUri,
    required this.headers,
    required this.bodyBytes,
  });

  String get text => utf8.decode(bodyBytes, allowMalformed: true);
  String get contentType => (headers['content-type'] ?? '').toLowerCase();
}

class MoodleService {
  static const String baseUrl = 'https://aula.usm.cl';
  static const String wsUrl = '$baseUrl/webservice/rest/server.php';
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

  final http.Client _client = http.Client();
  final SettingsService settingsService;

  String? _token;
  String? _cookie;
  String? _sesskey;
  String? _userName;
  int? _userId;

  MoodleService(this.settingsService);

  String? get userName => _userName;
  int? get userId => _userId;
  String? get sesskey => _sesskey;
  String? get token => _token;
  String? get cookie => _cookie;
  String get authModeLabel =>
      isTokenAuth ? 'Token' : (isAuthenticated ? 'Cookie / Web' : 'Desconectado');
  bool get isAuthenticated =>
      (_token != null && _token!.isNotEmpty) ||
      (_cookie != null && _cookie!.isNotEmpty);
  bool get isTokenAuth => _token != null && _token!.isNotEmpty;

  Map<String, String> _cookieHeaders([Map<String, String>? extra]) => {
        'User-Agent': userAgent,
        if (_cookie != null && _cookie!.isNotEmpty) 'Cookie': _cookie!,
        ...?extra,
      };

  Future<void> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('moodle_token');
    _cookie = prefs.getString('moodle_cookie');
    _sesskey = prefs.getString('moodle_sesskey');
    _userName = prefs.getString('moodle_user_name');
    _userId = prefs.getInt('moodle_user_id');
  }

  Future<void> saveSession({
    String? token,
    String? cookie,
    String? sesskey,
    String? userName,
    int? userId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    _token = token;
    _cookie = cookie;
    _sesskey = sesskey;
    _userName = userName;
    _userId = userId;

    if (token != null && token.isNotEmpty) {
      await prefs.setString('moodle_token', token);
    } else {
      await prefs.remove('moodle_token');
    }

    if (cookie != null && cookie.isNotEmpty) {
      await prefs.setString('moodle_cookie', cookie);
    } else {
      await prefs.remove('moodle_cookie');
    }

    if (sesskey != null && sesskey.isNotEmpty) {
      await prefs.setString('moodle_sesskey', sesskey);
    } else {
      await prefs.remove('moodle_sesskey');
    }

    if (userName != null) {
      await prefs.setString('moodle_user_name', userName);
    } else {
      await prefs.remove('moodle_user_name');
    }

    if (userId != null) {
      await prefs.setInt('moodle_user_id', userId);
    } else {
      await prefs.remove('moodle_user_id');
    }
  }

  Future<void> logout() async {
    _token = null;
    _cookie = null;
    _sesskey = null;
    _userName = null;
    _userId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('moodle_token');
    await prefs.remove('moodle_cookie');
    await prefs.remove('moodle_sesskey');
    await prefs.remove('moodle_user_name');
    await prefs.remove('moodle_user_id');
  }

  /// Realiza GET siguiendo redirecciones manualmente para conservar cookies y conocer finalUri exacta
  Future<_HttpRedirectResult> _getFollowingRedirects(
    String rawUrl, {
    Duration timeout = const Duration(seconds: 20),
    int maxRedirects = 8,
    bool sendCookie = true,
  }) async {
    var currentUri = Uri.parse(rawUrl);
    for (var hop = 0; hop <= maxRedirects; hop++) {
      final req = http.Request('GET', currentUri)..followRedirects = false;
      req.headers['User-Agent'] = userAgent;
      if (sendCookie &&
          _cookie != null &&
          _cookie!.isNotEmpty &&
          currentUri.host.toLowerCase().endsWith('aula.usm.cl')) {
        req.headers['Cookie'] = _cookie!;
      }

      final streamed = await _client.send(req).timeout(timeout);
      final bytes = await streamed.stream.toBytes();
      final status = streamed.statusCode;
      final headers = <String, String>{};
      streamed.headers.forEach((k, v) => headers[k.toLowerCase()] = v);

      if (status >= 300 && status < 400 && headers['location'] != null) {
        final next = currentUri.resolve(headers['location']!);
        currentUri = next;
        continue;
      }

      return _HttpRedirectResult(
        statusCode: status,
        finalUri: currentUri,
        headers: headers,
        bodyBytes: bytes,
      );
    }
    throw Exception('Demasiadas redirecciones al consultar $rawUrl');
  }

  static bool isAuthenticatedMoodleHtml(String url, String html) {
    final lower = url.toLowerCase();
    if (lower.contains('/portada') ||
        lower.contains('/login') ||
        lower.contains('/auth/') ||
        lower.contains('microsoftonline.com')) {
      return false;
    }
    if (html.contains('manual-login-form')) {
      return false;
    }
    final hasUserId = RegExp(r'"userid"\s*:\s*([1-9]\d*)').hasMatch(html);
    final hasLogout = html.contains('logout.php');
    return hasUserId || hasLogout;
  }

  static ({String? sesskey, String? userName, int userId}) extractSessionDetails(
    String html,
  ) {
    final mSess = RegExp(r'"sesskey"\s*:\s*"([^"]+)"').firstMatch(html) ??
        RegExp(r'logout\.php\?sesskey=([a-zA-Z0-9]+)').firstMatch(html) ??
        RegExp(r'sesskey=([a-zA-Z0-9]+)').firstMatch(html);
    final sesskey = mSess?.group(1);

    final mUid = RegExp(r'"userid"\s*:\s*(\d+)').firstMatch(html);
    final userId = int.tryParse(mUid?.group(1) ?? '0') ?? 0;

    final doc = html_parser.parse(html);
    String? userName;
    for (final selector in [
      '.usermenu .usertext',
      '.userbutton .usertext',
      '[data-region="usermenu"] .usertext',
      '.logininfo a[href*="user/profile.php"]',
    ]) {
      final el = doc.querySelector(selector);
      if (el != null && el.text.trim().isNotEmpty) {
        userName = el.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        break;
      }
    }

    if (userName == null || userName.isEmpty) {
      final btn = doc.querySelector('#user-menu-toggle, .usermenu button');
      if (btn != null) {
        final label = btn.attributes['aria-label'] ?? btn.attributes['title'] ?? '';
        if (label.isNotEmpty && !label.toLowerCase().contains('menú de usuario')) {
          userName = label.trim();
        }
      }
    }

    return (sesskey: sesskey, userName: userName, userId: userId);
  }

  /// Verifica en vivo la sesión activa (token o cookie)
  Future<Map<String, dynamic>> verifySessionLive() async {
    if (!isAuthenticated) {
      return {'authenticated': false, 'reason': 'Sin sesión activa.'};
    }

    if (isTokenAuth) {
      try {
        final response = await _client.post(
          Uri.parse(wsUrl),
          headers: {'User-Agent': userAgent},
          body: {
            'wstoken': _token!,
            'wsfunction': 'core_webservice_get_site_info',
            'moodlewsrestformat': 'json',
          },
        ).timeout(const Duration(seconds: 12));

        final data = json.decode(response.body);
        if (data is Map && !data.containsKey('errorcode') && data.containsKey('userid')) {
          final uname = (data['fullname'] ?? data['username'] ?? _userName ?? 'Usuario').toString();
          final uid = (data['userid'] as int?) ?? _userId ?? 0;
          await saveSession(token: _token, userName: uname, userId: uid);
          return {'authenticated': true, 'user_name': uname, 'user_id': uid};
        } else {
          await logout();
          return {'authenticated': false, 'reason': 'Token de acceso expirado o inválido.'};
        }
      } catch (_) {
        // Sin internet momentáneo: mantener sesión local
        return {'authenticated': true, 'user_name': _userName ?? 'Usuario', 'user_id': _userId ?? 0};
      }
    } else {
      try {
        final res = await _getFollowingRedirects('$baseUrl/my/courses.php', timeout: const Duration(seconds: 12));
        final html = res.text;
        if (!isAuthenticatedMoodleHtml(res.finalUri.toString(), html)) {
          await logout();
          return {
            'authenticated': false,
            'reason': 'Sesión expirada en Aula USM (redirigido a portada de acceso).',
          };
        }
        final details = extractSessionDetails(html);
        final finalName = details.userName ?? _userName ?? 'Usuario Aula';
        final finalUid = details.userId > 0 ? details.userId : (_userId ?? 0);
        await saveSession(
          cookie: _cookie,
          sesskey: details.sesskey ?? _sesskey,
          userName: finalName,
          userId: finalUid,
        );
        return {'authenticated': true, 'user_name': finalName, 'user_id': finalUid};
      } catch (e) {
        return {'authenticated': true, 'user_name': _userName ?? 'Usuario Aula', 'offline_warning': e.toString()};
      }
    }
  }

  /// Valida y guarda un token de acceso (wstoken)
  Future<Map<String, dynamic>> loginWithToken(String tokenInput) async {
    final cleanToken = tokenInput.trim();
    if (cleanToken.isEmpty) {
      return {'success': false, 'message': 'El token de acceso no puede estar vacío.'};
    }

    try {
      final response = await _client.post(
        Uri.parse(wsUrl),
        headers: {'User-Agent': userAgent},
        body: {
          'wstoken': cleanToken,
          'wsfunction': 'core_webservice_get_site_info',
          'moodlewsrestformat': 'json',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        return {
          'success': false,
          'message': 'Error del servidor (HTTP ${response.statusCode})',
        };
      }

      final data = json.decode(response.body);
      if (data is Map && data.containsKey('errorcode')) {
        return {
          'success': false,
          'message': data['message']?.toString() ?? 'Token inválido (${data['errorcode']})',
        };
      }

      final user = (data['fullname'] ?? data['username'] ?? 'Usuario').toString();
      final uid = (data['userid'] as int?) ?? 0;

      await saveSession(
        token: cleanToken,
        cookie: null,
        sesskey: null,
        userName: user,
        userId: uid,
      );

      return {'success': true, 'user_name': user, 'user_id': uid};
    } catch (e) {
      return {'success': false, 'message': 'Error de conexión: $e'};
    }
  }

  /// Normaliza, guarda y VERIFICA una cookie MoodleSession ingresada manualmente o capturada vía WebView
  Future<Map<String, dynamic>> loginWithCookie(String rawCookieInput) async {
    var clean = rawCookieInput.trim();
    if (clean.isEmpty) {
      return {'success': false, 'message': 'La cookie no puede estar vacía.'};
    }
    // Si el usuario pegó solo el valor hexadecimal/alfanumérico sin "MoodleSession="
    if (!clean.contains('=')) {
      clean = 'MoodleSession=$clean';
    }

    _cookie = clean;
    _token = null;

    try {
      // Verificar contra /my/courses.php (con redirección) igual que scraper/auth.py
      var res = await _getFollowingRedirects('$baseUrl/my/courses.php', timeout: const Duration(seconds: 15));
      var html = res.text;
      var finalUrl = res.finalUri.toString();

      if (!isAuthenticatedMoodleHtml(finalUrl, html)) {
        res = await _getFollowingRedirects('$baseUrl/my/', timeout: const Duration(seconds: 15));
        html = res.text;
        finalUrl = res.finalUri.toString();
      }

      if (!isAuthenticatedMoodleHtml(finalUrl, html)) {
        _cookie = null;
        return {
          'success': false,
          'message': 'La cookie MoodleSession no es válida o ya expiró.',
        };
      }

      final details = extractSessionDetails(html);
      final userName = details.userName ?? 'Usuario ID ${details.userId}';

      await saveSession(
        token: null,
        cookie: clean,
        sesskey: details.sesskey,
        userName: userName,
        userId: details.userId,
      );

      return {'success': true, 'user_name': userName, 'user_id': details.userId};
    } catch (e) {
      _cookie = null;
      return {'success': false, 'message': 'Error al verificar cookie: $e'};
    }
  }

  /// Obtiene la lista de cursos inscritos
  Future<List<MoodleCourse>> getCourses() async {
    if (!isAuthenticated) throw SessionExpiredException('No autenticado');
    final existingDirs = await settingsService.listExistingSubfolders();

    if (isTokenAuth) {
      return _getCoursesWithToken(existingDirs);
    } else {
      return _getCoursesWithCookie(existingDirs);
    }
  }

  Future<List<MoodleCourse>> _getCoursesWithToken(List<String> existingDirs) async {
    final Map<int, MoodleCourse> coursesById = {};

    // 1. Función estándar Moodle REST: core_enrol_get_users_courses
    try {
      final response = await _client.post(
        Uri.parse(wsUrl),
        headers: {'User-Agent': userAgent},
        body: {
          'wstoken': _token!,
          'wsfunction': 'core_enrol_get_users_courses',
          'userid': (_userId ?? 0).toString(),
          'moodlewsrestformat': 'json',
        },
      ).timeout(const Duration(seconds: 15));

      final data = json.decode(response.body);
      if (data is List) {
        for (final item in data) {
          final id = item['id'] as int? ?? 0;
          if (id <= 1) continue;
          final fullname = (item['fullname'] ?? 'Curso $id').toString().trim();
          final shortname = (item['shortname'] ?? '').toString().trim();
          coursesById[id] = _buildCourseObj(id, fullname, shortname, existingDirs);
        }
      } else if (data is Map && data.containsKey('errorcode')) {
        // Fallback abajo si la función no está habilitada
        final code = data['errorcode'].toString();
        if (code == 'invalidtoken') {
          throw SessionExpiredException(data['message']?.toString() ?? 'Token inválido');
        }
      }
    } catch (e) {
      if (e is SessionExpiredException) rethrow;
    }

    // 2. Complemento/Fallback: core_course_get_enrolled_courses_by_timeline_classification
    if (coursesById.isEmpty) {
      for (final classification in ['inprogress', 'all']) {
        try {
          final response = await _client.post(
            Uri.parse(wsUrl),
            headers: {'User-Agent': userAgent},
            body: {
              'wstoken': _token!,
              'wsfunction': 'core_course_get_enrolled_courses_by_timeline_classification',
              'classification': classification,
              'limit': '0',
              'offset': '0',
              'moodlewsrestformat': 'json',
            },
          ).timeout(const Duration(seconds: 15));

          final data = json.decode(response.body);
          if (data is Map && data.containsKey('courses') && data['courses'] is List) {
            for (final item in data['courses'] as List) {
              final id = item['id'] as int? ?? 0;
              if (id <= 1 || coursesById.containsKey(id)) continue;
              final fullname = (item['fullname'] ?? 'Curso $id').toString().trim();
              final shortname = (item['shortname'] ?? '').toString().trim();
              coursesById[id] = _buildCourseObj(id, fullname, shortname, existingDirs);
            }
          } else if (data is Map && data.containsKey('errorcode')) {
            throw Exception(data['message']?.toString() ?? 'Error al obtener cursos');
          }
        } catch (e) {
          if (coursesById.isEmpty) rethrow;
        }
      }
    }

    final result = coursesById.values.toList();
    result.sort((a, b) => a.cleanName.compareTo(b.cleanName));
    return result;
  }

  Future<List<MoodleCourse>> _getCoursesWithCookie(List<String> existingDirs) async {
    final Map<int, MoodleCourse> coursesById = {};

    // Asegurar sesskey si falta
    if (_sesskey == null || _sesskey!.isEmpty) {
      final verifyRes = await verifySessionLive();
      if (verifyRes['authenticated'] != true) {
        throw SessionExpiredException(verifyRes['reason']?.toString() ?? 'Sesión expirada');
      }
    }

    // 1. Consulta vía AJAX interno de Moodle (classifications: inprogress y all)
    if (_sesskey != null && _sesskey!.isNotEmpty) {
      for (final classification in ['inprogress', 'all']) {
        try {
          final ajaxUrl =
              '$baseUrl/lib/ajax/service.php?sesskey=$_sesskey&info=core_course_get_enrolled_courses_by_timeline_classification';
          final payload = json.encode([
            {
              'index': 0,
              'methodname': 'core_course_get_enrolled_courses_by_timeline_classification',
              'args': {
                'offset': 0,
                'limit': 0,
                'classification': classification,
                'sort': 'fullname',
                'customfieldname': '',
                'customfieldvalue': '',
              },
            }
          ]);

          final resp = await _client
              .post(
                Uri.parse(ajaxUrl),
                headers: _cookieHeaders({'Content-Type': 'application/json'}),
                body: payload,
              )
              .timeout(const Duration(seconds: 14));

          if (resp.statusCode == 200) {
            final data = json.decode(resp.body);
            if (data is List && data.isNotEmpty && data[0]['error'] != true) {
              final rawCourses = data[0]['data']?['courses'] as List? ?? [];
              for (final c in rawCourses) {
                final cid = c['id'] as int? ?? 0;
                if (cid <= 1 || coursesById.containsKey(cid)) continue;
                final fn = (c['fullname'] ?? 'Curso $cid').toString().trim();
                final sn = (c['shortname'] ?? '').toString().trim();
                if (fn.isNotEmpty) {
                  coursesById[cid] = _buildCourseObj(cid, fn, sn, existingDirs);
                }
              }
            }
          }
        } catch (_) {}
      }
    }

    // 2. Complemento por HTML en /my/courses.php y /my/
    for (final pagePath in ['/my/courses.php', '/my/']) {
      try {
        final res = await _getFollowingRedirects('$baseUrl$pagePath', timeout: const Duration(seconds: 14));
        if (!isAuthenticatedMoodleHtml(res.finalUri.toString(), res.text)) {
          continue;
        }
        final doc = html_parser.parse(res.text);
        final links = doc.querySelectorAll('a[href*="/course/view.php?id="]');
        for (final a in links) {
          final href = a.attributes['href'] ?? '';
          final mId = RegExp(r'[?&]id=(\d+)').firstMatch(href);
          if (mId == null) continue;
          final cid = int.tryParse(mId.group(1) ?? '0') ?? 0;
          if (cid <= 1 || coursesById.containsKey(cid)) continue;

          final multiline = a.querySelector('.multiline');
          var rawName = multiline != null ? multiline.text : a.text;
          rawName = _cleanMoodleTitle(rawName);
          if (rawName.length >= 3) {
            coursesById[cid] = _buildCourseObj(cid, rawName, rawName, existingDirs);
          }
        }
      } catch (_) {}
    }

    final result = coursesById.values.toList();
    result.sort((a, b) => a.cleanName.compareTo(b.cleanName));
    return result;
  }

  MoodleCourse _buildCourseObj(
    int id,
    String fullname,
    String shortname,
    List<String> existingDirs,
  ) {
    final folder = settingsService.resolveCourseFolderSync(id, fullname, existingDirs);
    return MoodleCourse(
      id: id,
      fullname: fullname,
      cleanName: MoodleCourse.cleanCourseName(fullname),
      shortname: shortname,
      url: '$baseUrl/course/view.php?id=$id',
      obsidianFolder: folder,
      targetSubfolder: settingsService.getCourseSubfolder(id),
      organizeBySection: settingsService.getCourseOrganizeBySection(id),
      isHidden: settingsService.isCourseHidden(id),
    );
  }

  /// Empareja la sesión y configuración desde el servidor PC local (`/api/pair/claim`)
  Future<Map<String, dynamic>> loginFromPairingClaim(
    Map<String, dynamic> claimPayload,
  ) async {
    final auth = claimPayload['auth'] is Map
        ? Map<String, dynamic>.from(claimPayload['auth'] as Map)
        : <String, dynamic>{};
    final token = (auth['token'] ?? '').toString().trim();
    final rawCookies = auth['cookies'];

    Map<String, dynamic> authResult = {'success': false, 'message': 'Sin credenciales válidas en el PC.'};
    if (token.isNotEmpty) {
      authResult = await loginWithToken(token);
    } else if (rawCookies is List && rawCookies.isNotEmpty) {
      final cookiePairs = <String>[];
      for (final c in rawCookies) {
        if (c is Map) {
          final cname = (c['name'] ?? '').toString().trim();
          final cval = (c['value'] ?? '').toString().trim();
          if (cname.isNotEmpty && cval.isNotEmpty) {
            cookiePairs.add('$cname=$cval');
          }
        }
      }
      if (cookiePairs.isNotEmpty) {
        authResult = await loginWithCookie(cookiePairs.join('; '));
      }
    } else if (rawCookies is String && rawCookies.trim().isNotEmpty) {
      authResult = await loginWithCookie(rawCookies.trim());
    }

    if (authResult['success'] != true) {
      return authResult;
    }

    await settingsService.applyPairedSettings(claimPayload);
    await settingsService.addNotification(
      title: 'Vinculado con PC',
      body: 'Sesión, carpetas de ramos y reglas importadas desde el computador.',
      kind: 'info',
      dedupKey: 'paired_${DateTime.now().millisecondsSinceEpoch ~/ 60000}',
    );
    return authResult;
  }

  /// Normaliza títulos o nombres de archivo para emparejamiento local PC <-> Android
  static String normalizeMatchKey(String input) {
    final normalized = MoodleCourse.normalizeForMatch(input);
    final noExt = normalized.replaceFirst(RegExp(r'\.[a-z0-9]{1,6}$'), '');
    return noExt
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String inferFileExt(String fileName, String title) {
    for (final candidate in [fileName, title]) {
      final clean = candidate.trim().toLowerCase();
      final dot = clean.lastIndexOf('.');
      if (dot > 0 && dot < clean.length - 1) {
        final ext = clean.substring(dot + 1).trim();
        if (ext.length <= 6 && RegExp(r'^[a-z0-9]+$').hasMatch(ext)) {
          return ext;
        }
      }
    }
    return '';
  }

  static int? parseDueTimestamp(String rawText) {
    final clean = rawText
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (clean.isEmpty) return null;

    const months = {
      'enero': 1,
      'ene': 1,
      'febrero': 2,
      'feb': 2,
      'marzo': 3,
      'mar': 3,
      'abril': 4,
      'abr': 4,
      'mayo': 5,
      'may': 5,
      'junio': 6,
      'jun': 6,
      'julio': 7,
      'jul': 7,
      'agosto': 8,
      'ago': 8,
      'septiembre': 9,
      'setiembre': 9,
      'sep': 9,
      'sept': 9,
      'octubre': 10,
      'oct': 10,
      'noviembre': 11,
      'nov': 11,
      'diciembre': 12,
      'dic': 12,
      'january': 1,
      'jan': 1,
      'february': 2,
      'march': 3,
      'april': 4,
      'may_en': 5,
      'june': 6,
      'july': 7,
      'august': 8,
      'september': 9,
      'october': 10,
      'november': 11,
      'december': 12,
    };

    // Ej: "18 de noviembre de 2026, 23:59" o "18 noviembre 2026 23:59"
    final mText = RegExp(
      r'(\d{1,2})\s+(?:de\s+)?([a-záéíóú]+)(?:\s+(?:de\s+)?(\d{4}))?(?:[,\s]+(\d{1,2}):(\d{2}))?',
    ).firstMatch(clean);
    if (mText != null) {
      final day = int.tryParse(mText.group(1) ?? '');
      final monName = MoodleCourse.normalizeForMatch(mText.group(2) ?? '');
      final month = months[monName];
      if (day != null && month != null && day >= 1 && day <= 31) {
        final year = int.tryParse(mText.group(3) ?? '') ?? DateTime.now().year;
        final hour = int.tryParse(mText.group(4) ?? '') ?? 23;
        final min = int.tryParse(mText.group(5) ?? '') ?? 59;
        try {
          return DateTime(year, month, day, hour, min).millisecondsSinceEpoch ~/ 1000;
        } catch (_) {}
      }
    }

    // Ej: "18/11/2026 23:59" o "18-11-2026"
    final mNum = RegExp(
      r'(\d{1,2})[/-](\d{1,2})[/-](\d{4})(?:[,\s]+(\d{1,2}):(\d{2}))?',
    ).firstMatch(clean);
    if (mNum != null) {
      final day = int.tryParse(mNum.group(1) ?? '');
      final month = int.tryParse(mNum.group(2) ?? '');
      final year = int.tryParse(mNum.group(3) ?? '');
      if (day != null && month != null && year != null) {
        final hour = int.tryParse(mNum.group(4) ?? '') ?? 23;
        final min = int.tryParse(mNum.group(5) ?? '') ?? 59;
        try {
          return DateTime(year, month, day, hour, min).millisecondsSinceEpoch ~/ 1000;
        } catch (_) {}
      }
    }

    return null;
  }

  /// Escanea todas las secciones, pestañas, archivos, carpetas, tareas, cuestionarios, foros y enlaces de un curso
  Future<List<MoodleItem>> scanCourseContents(MoodleCourse course) async {
    if (!isAuthenticated) throw SessionExpiredException('No autenticado');

    final List<MoodleItem> items = isTokenAuth
        ? await _scanContentsWithToken(course.id)
        : await _scanContentsWithCookie(course.id);

    if (isTokenAuth) {
      await _attachWebServiceDeadlines(course.id, items);
    }

    await enrichItemsWithLocalStatus(items, course.obsidianFolder);
    return items;
  }

  /// Consulta WebServices de tareas y cuestionarios para completar timestamps de cierre
  Future<void> _attachWebServiceDeadlines(
    int courseId,
    List<MoodleItem> items,
  ) async {
    if (_token == null || _token!.isEmpty) return;
    final hasTargets = items.any((i) => i.type == 'assignment' || i.type == 'quiz');
    if (!hasTargets) return;

    final assignDeadlinesByCmid = <int, int>{};
    final assignDeadlinesByName = <String, int>{};
    try {
      final resp = await _client.post(
        Uri.parse(wsUrl),
        headers: {'User-Agent': userAgent},
        body: {
          'wstoken': _token!,
          'wsfunction': 'mod_assign_get_assignments',
          'moodlewsrestformat': 'json',
          'courseids[0]': courseId.toString(),
        },
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final decoded = json.decode(resp.body);
        if (decoded is Map && decoded['courses'] is List) {
          for (final c in decoded['courses'] as List) {
            if (c is Map && c['assignments'] is List) {
              for (final a in c['assignments'] as List) {
                if (a is! Map) continue;
                final due = (a['duedate'] as num?)?.toInt() ?? 0;
                if (due <= 0) continue;
                final cmid = (a['cmid'] as num?)?.toInt() ?? 0;
                final name = normalizeMatchKey((a['name'] ?? '').toString());
                if (cmid > 0) assignDeadlinesByCmid[cmid] = due;
                if (name.isNotEmpty) assignDeadlinesByName[name] = due;
              }
            }
          }
        }
      }
    } catch (_) {}

    final quizDeadlinesByCmid = <int, int>{};
    final quizDeadlinesByName = <String, int>{};
    try {
      final resp = await _client.post(
        Uri.parse(wsUrl),
        headers: {'User-Agent': userAgent},
        body: {
          'wstoken': _token!,
          'wsfunction': 'mod_quiz_get_quizzes_by_courses',
          'moodlewsrestformat': 'json',
          'courseids[0]': courseId.toString(),
        },
      ).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final decoded = json.decode(resp.body);
        if (decoded is Map && decoded['quizzes'] is List) {
          for (final q in decoded['quizzes'] as List) {
            if (q is! Map) continue;
            final closeTs = (q['timeclose'] as num?)?.toInt() ?? 0;
            if (closeTs <= 0) continue;
            final cmid = (q['coursemodule'] as num?)?.toInt() ?? 0;
            final name = normalizeMatchKey((q['name'] ?? '').toString());
            if (cmid > 0) quizDeadlinesByCmid[cmid] = closeTs;
            if (name.isNotEmpty) quizDeadlinesByName[name] = closeTs;
          }
        }
      }
    } catch (_) {}

    for (final item in items) {
      if ((item.dueTimestamp ?? 0) > 0) continue;
      final mId = RegExp(r'id=(\d+)').firstMatch(item.url);
      final cmid = int.tryParse(mId?.group(1) ?? '') ?? 0;
      final normTitle = normalizeMatchKey(item.title);
      int? foundTs;
      if (item.type == 'assignment') {
        foundTs = assignDeadlinesByCmid[cmid] ?? assignDeadlinesByName[normTitle];
      } else if (item.type == 'quiz') {
        foundTs = quizDeadlinesByCmid[cmid] ?? quizDeadlinesByName[normTitle];
      }
      if (foundTs != null && foundTs > 0) {
        item.dueTimestamp = foundTs;
        if (item.dueText.isEmpty) {
          final dt = DateTime.fromMillisecondsSinceEpoch(foundTs * 1000).toLocal();
          item.dueText =
              '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
        }
      }
    }
  }

  /// Sincroniza IDs conocidos para BackgroundSyncWorker y genera alertas en app/OS
  Future<void> processScanNotifications(
    List<MoodleCourse> courses, {
    Set<String>? previousKnownIds,
  }) async {
    final allIds = <String>{};
    for (final course in courses) {
      for (final item in course.items) {
        allIds.add(item.id);
      }
    }
    await settingsService.saveKnownItemIds(allIds);

    if (courses.isEmpty) return;

    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    for (final course in courses) {
      if (course.isHidden) continue;

      if (previousKnownIds != null &&
          previousKnownIds.isNotEmpty &&
          settingsService.notifyOnNewFiles) {
        final newItems = course.items
            .where(
              (i) =>
                  i.downloadable &&
                  !i.isDownloaded &&
                  !previousKnownIds.contains(i.id),
            )
            .toList();
        if (newItems.isNotEmpty) {
          final first = newItems.first;
          final title = newItems.length == 1
              ? 'Nuevo archivo en ${course.cleanName}'
              : '${newItems.length} archivos nuevos en ${course.cleanName}';
          final body = newItems.length == 1
              ? first.title
              : 'Incluye: ${first.title}';
          await settingsService.addNotification(
            title: title,
            body: body,
            kind: 'new_file',
            courseName: course.cleanName,
            dedupKey: 'new:${course.id}:${first.id}:${newItems.length}',
            triggerNative: true,
            nativeChannelId: 'aula_new_files',
          );
        }
      }

      if (settingsService.notifyOnDeadlines) {
        for (final item in course.items) {
          if (!item.isUrgentDeadline) continue;
          final diffHours = ((item.dueTimestamp! - nowSec) / 3600).ceil().clamp(1, 48);
          await settingsService.addNotification(
            title: 'Entrega en ${diffHours}h',
            body: '${course.cleanName}: ${item.title}',
            kind: 'deadline',
            courseName: course.cleanName,
            dedupKey: 'due:${item.id}:${item.dueTimestamp}',
            triggerNative: true,
            nativeChannelId: 'aula_deadlines',
          );
        }
      }
    }
  }

  Future<List<MoodleItem>> _scanContentsWithToken(int courseId) async {
    final response = await _client.post(
      Uri.parse(wsUrl),
      headers: {'User-Agent': userAgent},
      body: {
        'wstoken': _token!,
        'wsfunction': 'core_course_get_contents',
        'courseid': courseId.toString(),
        'moodlewsrestformat': 'json',
      },
    ).timeout(const Duration(seconds: 20));

    final data = json.decode(response.body);
    if (data is Map && data.containsKey('errorcode')) {
      if (data['errorcode'] == 'invalidtoken') {
        throw SessionExpiredException(data['message']?.toString() ?? 'Token expirado');
      }
      throw Exception(data['message']?.toString() ?? 'Error al obtener contenidos');
    }

    final List<MoodleItem> items = [];
    if (data is List) {
      for (final sec in data) {
        final rawSecName = (sec['name'] ?? '').toString().trim();
        final secName = rawSecName.isNotEmpty ? rawSecName : 'General';
        final rawModules = sec['modules'] as List? ?? [];

        for (final mod in rawModules) {
          final modId = mod['id'] as int? ?? 0;
          final modName = (mod['name'] ?? '').toString().trim();
          final modType = (mod['modname'] ?? '').toString().trim();
          final modUrl = (mod['url'] ?? '').toString().trim();
          final contents = mod['contents'] as List? ?? [];

          final modDates = mod['dates'] as List? ?? [];
          int? modDueTs;
          String modDueText = '';
          for (final d in modDates) {
            if (d is! Map) continue;
            final label = (d['label'] ?? '').toString().toLowerCase();
            final ts = (d['timestamp'] as num?)?.toInt() ?? 0;
            if (ts > 0 &&
                (label.contains('venc') ||
                    label.contains('cierra') ||
                    label.contains('close') ||
                    label.contains('due') ||
                    modDueTs == null)) {
              modDueTs = ts;
              final dt = DateTime.fromMillisecondsSinceEpoch(ts * 1000).toLocal();
              modDueText =
                  '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
            }
          }

          if (modType == 'folder' && contents.isNotEmpty) {
            for (final c in contents) {
              final fileUrl = (c['fileurl'] ?? '').toString();
              final fileName = (c['filename'] ?? modName).toString();
              final fileSize = c['filesize'] as int? ?? 0;
              if (fileUrl.isEmpty) continue;
              items.add(MoodleItem(
                id: 'folderfile_${modId}_${fileName.hashCode}',
                courseId: courseId,
                title: fileName,
                section: modName.isNotEmpty ? '$secName / $modName' : secName,
                type: 'file',
                url: fileUrl,
                fileName: fileName,
                fileExt: inferFileExt(fileName, modName),
                downloadable: true,
                sizeBytes: fileSize,
              ));
            }
          } else if (modType == 'url') {
            final linkUrl = contents.isNotEmpty
                ? (contents.first['fileurl'] ?? modUrl).toString()
                : modUrl;
            if (linkUrl.isNotEmpty) {
              items.add(MoodleItem(
                id: 'url_$modId',
                courseId: courseId,
                title: modName.isNotEmpty ? modName : 'Enlace externo',
                section: secName,
                type: 'link',
                url: linkUrl,
                fileName: modName,
                downloadable: false,
              ));
            }
          } else if (modType == 'assign') {
            items.add(MoodleItem(
              id: 'assign_$modId',
              courseId: courseId,
              title: modName.isNotEmpty ? modName : 'Tarea',
              section: secName,
              type: 'assignment',
              url: modUrl,
              fileName: modName,
              downloadable: false,
              dueTimestamp: modDueTs,
              dueText: modDueText,
            ));
          } else if (modType == 'quiz') {
            items.add(MoodleItem(
              id: 'quiz_$modId',
              courseId: courseId,
              title: modName.isNotEmpty ? modName : 'Cuestionario',
              section: secName,
              type: 'quiz',
              url: modUrl,
              fileName: modName,
              downloadable: false,
              dueTimestamp: modDueTs,
              dueText: modDueText,
            ));
          } else if (modType == 'forum') {
            items.add(MoodleItem(
              id: 'forum_$modId',
              courseId: courseId,
              title: modName.isNotEmpty ? modName : 'Foro',
              section: secName,
              type: 'forum',
              url: modUrl,
              fileName: modName,
              downloadable: false,
            ));
          } else if (contents.isNotEmpty && modType != 'page') {
            for (var idx = 0; idx < contents.length; idx++) {
              final c = contents[idx];
              final fileUrl = (c['fileurl'] ?? '').toString();
              final fileName = (c['filename'] ?? modName).toString();
              final fileSize = c['filesize'] as int? ?? 0;
              if (fileUrl.isEmpty) continue;
              final title = contents.length == 1 && modName.isNotEmpty ? modName : fileName;
              items.add(MoodleItem(
                id: contents.length == 1 ? 'res_$modId' : 'res_${modId}_$idx',
                courseId: courseId,
                title: title,
                section: secName,
                type: 'file',
                url: fileUrl,
                fileName: fileName,
                fileExt: inferFileExt(fileName, title),
                downloadable: true,
                sizeBytes: fileSize,
              ));
            }
          } else if (modType == 'page' || modType == 'book') {
            if (modUrl.isNotEmpty) {
              items.add(MoodleItem(
                id: 'page_$modId',
                courseId: courseId,
                title: modName.isNotEmpty ? modName : 'Página',
                section: secName,
                type: 'page',
                url: modUrl,
                fileName: modName,
                downloadable: false,
              ));
            }
          }
        }
      }
    }
    return items;
  }

  Future<List<MoodleItem>> _scanContentsWithCookie(int courseId) async {
    final courseUrl = '$baseUrl/course/view.php?id=$courseId';
    final res = await _getFollowingRedirects(courseUrl, timeout: const Duration(seconds: 18));
    if (!isAuthenticatedMoodleHtml(res.finalUri.toString(), res.text)) {
      throw SessionExpiredException('La sesión de Aula USM no es válida o expiró.');
    }

    final doc = html_parser.parse(res.text);
    final Set<String> seenUrls = {};
    final List<MoodleItem> allItems = [];

    // 1. Actividades visibles en la página principal del curso
    final mainItems = await _parseActivitiesFromDoc(courseId, doc, seenUrls);
    allItems.addAll(mainItems);

    // 2. Detectar si el curso usa pestañas/secciones por página (onetopic, Tiles, section.php, etc.)
    final List<({String url, String title})> tabLinks = [];
    final Set<String> seenTabUrls = {courseUrl};

    for (final a in doc.querySelectorAll(
      'a[href*="/course/view.php?id=$courseId&section="], a[href*="/course/section.php?id="]',
    )) {
      var href = a.attributes['href']?.trim() ?? '';
      if (href.isEmpty) continue;
      href = Uri.parse(baseUrl).resolve(href).toString().split('#').first;
      if (seenTabUrls.contains(href)) continue;
      seenTabUrls.add(href);
      final tabTitle = _cleanMoodleTitle(a.text);
      tabLinks.add((url: href, title: tabTitle.isNotEmpty ? tabTitle : 'Pestaña'));
    }

    // Recorrer pestañas en paralelo en lotes de 5 (hasta 30 pestañas para capturar todas las unidades)
    if (tabLinks.isNotEmpty) {
      final limitedTabs = tabLinks.take(30).toList();
      for (var i = 0; i < limitedTabs.length; i += 5) {
        final batch = limitedTabs.sublist(i, (i + 5).clamp(0, limitedTabs.length));
        final batchResults = await Future.wait(batch.map((tab) async {
          try {
            final tRes = await _getFollowingRedirects(tab.url, timeout: const Duration(seconds: 10));
            if (isAuthenticatedMoodleHtml(tRes.finalUri.toString(), tRes.text)) {
              final tDoc = html_parser.parse(tRes.text);
              return await _parseActivitiesFromDoc(
                courseId,
                tDoc,
                seenUrls,
                defaultSection: tab.title,
              );
            }
          } catch (_) {}
          return <MoodleItem>[];
        }));
        for (final sub in batchResults) {
          allItems.addAll(sub);
        }
      }
    }

    return allItems;
  }

  Future<List<MoodleItem>> _parseActivitiesFromDoc(
    int courseId,
    dom.Document doc,
    Set<String> seenUrls, {
    String defaultSection = 'General',
  }) async {
    final List<MoodleItem> items = [];
    final List<({String href, String sectionName, String folderTitle})> pendingFolders = [];

    final root = doc.querySelector('#region-main') ??
        doc.querySelector('#page-content') ??
        doc.body ??
        doc.documentElement;
    if (root == null) return items;

    final rawSections = root.querySelectorAll(
      'li.section.main, section.course-section, div.course-section, [data-region="section"], li.section',
    );
    // Filtrar secciones anidadas para evitar procesar la misma sección dos veces
    final rawSet = rawSections.toSet();
    final List<dom.Element> sections = rawSections.where((el) {
      var parent = el.parent;
      while (parent != null) {
        if (rawSet.contains(parent)) return false;
        parent = parent.parent;
      }
      return true;
    }).toList();

    if (sections.isEmpty) {
      sections.add(root);
    }

    for (var idx = 0; idx < sections.length; idx++) {
      final sec = sections[idx];
      final titleEl = sec.querySelector(
        '.sectionname, .course-section-header h3, .course-section-header h4, [data-region="section-title"], h3.sectionname',
      );
      var sectionName = titleEl != null
          ? _cleanMoodleTitle(titleEl.text)
          : (sections.length == 1 ? defaultSection : 'Sección $idx');
      if (sectionName.isEmpty) {
        sectionName = sections.length == 1 ? defaultSection : 'Sección $idx';
      }

      var activities = sec.querySelectorAll(
        'li.activity, .activity-item, [data-region="activity-item"]',
      );
      if (activities.isEmpty) {
        activities = sec.querySelectorAll('a[href*="/mod/"], a[href*="pluginfile.php"]');
      }

      for (final act in activities) {
        // En elementos normales, tomar enlace principal + eventuales archivos embebidos en su descripción
        final List<dom.Element> links = [];
        if (act.localName == 'a') {
          links.add(act);
        } else {
          final mainLink = act.querySelector('a.aalink, a[href*="/mod/"], a[href*="pluginfile.php"]');
          if (mainLink != null) links.add(mainLink);
          for (final extraLink in act.querySelectorAll(
            '.no-overflow a[href*="pluginfile.php"], .activity-altcontent a[href*="pluginfile.php"], .description a[href*="pluginfile.php"]',
          )) {
            if (!links.contains(extraLink)) links.add(extraLink);
          }
          if (links.isEmpty) {
            links.addAll(act.querySelectorAll('a[href*="/mod/"], a[href*="pluginfile.php"]'));
          }
        }

        for (final link in links) {
          var href = (link.attributes['href'] ?? '').trim();
          if (href.isEmpty || href.startsWith('#') || href.startsWith('javascript:')) {
            continue;
          }
          href = Uri.parse(baseUrl).resolve(href).toString();
          if (seenUrls.contains(href)) continue;
          seenUrls.add(href);

          final instancename = link.querySelector('.instancename');
          String title;
          if (instancename != null) {
            final clone = instancename.clone(true);
            for (final hidden in clone.querySelectorAll('.accesshide')) {
              hidden.remove();
            }
            title = clone.text.replaceAll(RegExp(r'\s+'), ' ').trim();
          } else {
            title = _cleanMoodleTitle(link.text);
          }
          if (title.isEmpty) {
            final segs = Uri.tryParse(href)?.pathSegments ?? [];
            title = segs.isNotEmpty ? Uri.decodeComponent(segs.last) : 'Recurso sin título';
          }

          final modIdMatch = RegExp(r'[?&]id=(\d+)').firstMatch(href);
          final cmId = modIdMatch?.group(1);

          String actDueText = '';
          int? actDueTs;
          if (href.contains('/mod/assign/') || href.contains('/mod/quiz/')) {
            final dateContainer = act.querySelector(
              '[data-region="activity-dates"], .activity-dates, .description, .activity-altcontent',
            );
            final rawDateBlock = (dateContainer?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
            if (rawDateBlock.isNotEmpty) {
              for (final clause in rawDateBlock.split(RegExp(r'[\r\n|•]+'))) {
                final cLower = clause.toLowerCase();
                if (cLower.contains('venc') ||
                    cLower.contains('cierra') ||
                    cLower.contains('cierre') ||
                    cLower.contains('entrega') ||
                    cLower.contains('due') ||
                    cLower.contains('close')) {
                  final parsed = parseDueTimestamp(clause);
                  if (parsed != null) {
                    actDueTs = parsed;
                    final dt = DateTime.fromMillisecondsSinceEpoch(parsed * 1000).toLocal();
                    actDueText =
                        '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                    break;
                  }
                }
              }
              if (actDueTs == null) {
                final parsed = parseDueTimestamp(rawDateBlock);
                if (parsed != null) {
                  actDueTs = parsed;
                  final dt = DateTime.fromMillisecondsSinceEpoch(parsed * 1000).toLocal();
                  actDueText =
                      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                }
              }
            }
          }

          if (href.contains('/mod/resource/') || href.contains('pluginfile.php')) {
            final itemId = cmId != null ? 'res_$cmId' : 'file_${href.hashCode.abs()}';
            items.add(MoodleItem(
              id: itemId,
              courseId: courseId,
              title: title,
              section: sectionName,
              type: 'file',
              url: href,
              fileName: title,
              fileExt: inferFileExt(title, href),
              downloadable: true,
            ));
          } else if (href.contains('/mod/folder/')) {
            pendingFolders.add((href: href, sectionName: sectionName, folderTitle: title));
          } else if (href.contains('/mod/assign/')) {
            final itemId = cmId != null ? 'assign_$cmId' : 'assign_${href.hashCode.abs()}';
            items.add(MoodleItem(
              id: itemId,
              courseId: courseId,
              title: title,
              section: sectionName,
              type: 'assignment',
              url: href,
              fileName: title,
              downloadable: false,
              dueTimestamp: actDueTs,
              dueText: actDueText,
            ));
          } else if (href.contains('/mod/quiz/')) {
            final itemId = cmId != null ? 'quiz_$cmId' : 'quiz_${href.hashCode.abs()}';
            items.add(MoodleItem(
              id: itemId,
              courseId: courseId,
              title: title,
              section: sectionName,
              type: 'quiz',
              url: href,
              fileName: title,
              downloadable: false,
              dueTimestamp: actDueTs,
              dueText: actDueText,
            ));
          } else if (href.contains('/mod/url/')) {
            final itemId = cmId != null ? 'url_$cmId' : 'url_${href.hashCode.abs()}';
            items.add(MoodleItem(
              id: itemId,
              courseId: courseId,
              title: title,
              section: sectionName,
              type: 'link',
              url: href,
              fileName: title,
              downloadable: false,
            ));
          } else if (href.contains('/mod/forum/')) {
            final itemId = cmId != null ? 'forum_$cmId' : 'forum_${href.hashCode.abs()}';
            items.add(MoodleItem(
              id: itemId,
              courseId: courseId,
              title: title,
              section: sectionName,
              type: 'forum',
              url: href,
              fileName: title,
              downloadable: false,
            ));
          } else if (href.contains('/mod/page/') || href.contains('/mod/book/')) {
            final itemId = cmId != null ? 'page_$cmId' : 'page_${href.hashCode.abs()}';
            items.add(MoodleItem(
              id: itemId,
              courseId: courseId,
              title: title,
              section: sectionName,
              type: 'page',
              url: href,
              fileName: title,
              downloadable: false,
            ));
          }
        }
      }
    }

    // Extraer archivos de todas las carpetas encontradas en paralelo
    if (pendingFolders.isNotEmpty) {
      final folderResults = await Future.wait(
        pendingFolders.map(
          (f) => _extractFolderFiles(courseId, f.href, f.sectionName, f.folderTitle, seenUrls),
        ),
      );
      for (final files in folderResults) {
        items.addAll(files);
      }
    }

    return items;
  }

  Future<List<MoodleItem>> _extractFolderFiles(
    int courseId,
    String folderUrl,
    String sectionName,
    String folderTitle,
    Set<String> seenUrls,
  ) async {
    final List<MoodleItem> items = [];
    try {
      final res = await _getFollowingRedirects(folderUrl, timeout: const Duration(seconds: 12));
      if (!isAuthenticatedMoodleHtml(res.finalUri.toString(), res.text)) {
        return items;
      }
      final doc = html_parser.parse(res.text);
      for (final a in doc.querySelectorAll('a[href*="pluginfile.php"]')) {
        var href = (a.attributes['href'] ?? '').trim();
        if (href.isEmpty) continue;
        href = Uri.parse(baseUrl).resolve(href).toString();
        if (seenUrls.contains(href)) continue;
        seenUrls.add(href);

        final fnEl = a.querySelector('.fp-filename');
        var title = (fnEl != null ? fnEl.text : a.text).trim();
        if (title.isEmpty) {
          final segs = Uri.tryParse(href)?.pathSegments ?? [];
          title = segs.isNotEmpty ? Uri.decodeComponent(segs.last) : 'Archivo';
        }
        final tail = href.split('?').first;
        final shortTail = tail.length > 60 ? tail.substring(tail.length - 60) : tail;
        final safeKey = shortTail.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');

        items.add(MoodleItem(
          id: 'folderfile_$safeKey',
          courseId: courseId,
          title: title,
          section: '$sectionName / $folderTitle',
          type: 'file',
          url: href,
          fileName: title,
          downloadable: true,
        ));
      }
    } catch (_) {}
    return items;
  }

  /// Enriquece ítems con estado 'En carpeta' / 'Pendiente' y tamaño conocido desde historial o disco
  /// Enriquece ítems con estado local inteligente (historial, .aula-scrapt-index.json y disco)
  Future<void> enrichItemsWithLocalStatus(
    List<MoodleItem> items,
    String obsidianFolderName,
  ) async {
    final history = settingsService.history;
    final downloadedIds = history['downloaded_ids'] as Map<String, dynamic>;
    final seenIds = history['seen_ids'] as Map<String, dynamic>;
    final fileSizes = history['file_sizes'] as Map<String, dynamic>;
    final sharedIndex = await settingsService.loadSharedIndex();
    final sharedItems = sharedIndex['items'] as Map<String, dynamic>? ?? {};
    final rootDir = Directory(settingsService.downloadRoot);

    // Recolectar archivos ya presentes en disco estrictamente dentro de downloadRoot/<curso>
    final List<({String path, String normKey})> diskFiles = [];
    try {
      final courseDir = Directory(
        p.join(
          settingsService.downloadRoot,
          MoodleCourse.sanitizeFileName(obsidianFolderName),
        ),
      );
      if (await courseDir.exists()) {
        await for (final entity in courseDir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final base = p.basename(entity.path);
            if (base.startsWith('.') ||
                base.startsWith('00 - Indice') ||
                base.startsWith('00 - Seccion')) {
              continue;
            }
            diskFiles.add((
              path: entity.path,
              normKey: normalizeMatchKey(base),
            ));
          }
        }
      }
    } catch (_) {}

    String? findDiskMatch(MoodleItem item) {
      final rawFileKey = normalizeMatchKey(item.fileName);
      final titleKey = normalizeMatchKey(item.title);
      final targetKeys = {
        if (rawFileKey.isNotEmpty) rawFileKey,
        if (titleKey.isNotEmpty) titleKey,
      };
      if (targetKeys.isEmpty) return null;

      for (final lf in diskFiles) {
        if (lf.normKey.isNotEmpty && targetKeys.contains(lf.normKey)) {
          return lf.path;
        }
      }
      for (final lf in diskFiles) {
        if (lf.normKey.isEmpty) continue;
        for (final target in targetKeys) {
          if (target.length >= 6 &&
              lf.normKey.length >= 6 &&
              (lf.normKey.contains(target) || target.contains(lf.normKey))) {
            return lf.path;
          }
          final targetTokens =
              target.split(' ').where((t) => t.length >= 3).toSet();
          final diskTokens =
              lf.normKey.split(' ').where((t) => t.length >= 3).toSet();
          if (targetTokens.length >= 2 && diskTokens.isNotEmpty) {
            final common = targetTokens.intersection(diskTokens).length;
            if (common >= targetTokens.length ||
                (common >= 3 && common / targetTokens.length >= 0.8)) {
              return lf.path;
            }
          }
        }
      }
      return null;
    }

    for (final item in items) {
      bool isDownloaded = false;
      String? localPath;
      int sz = item.sizeBytes;

      if (downloadedIds.containsKey(item.id)) {
        final rawInfo = downloadedIds[item.id];
        final savedPath = rawInfo is Map
            ? (rawInfo['path'] ?? '').toString()
            : rawInfo?.toString() ?? '';
        if (savedPath.isNotEmpty) {
          final f = File(savedPath);
          if (await f.exists()) {
            isDownloaded = true;
            localPath = savedPath;
            try {
              sz = await f.length();
              fileSizes[item.id] = sz;
            } catch (_) {}
          }
        }
      }

      // Revisar índice compartido PC <-> Android (.aula-scrapt-index.json) dentro de downloadRoot
      if (!isDownloaded && sharedItems[item.id] is Map && await rootDir.exists()) {
        final rel = (sharedItems[item.id]['relative_path'] ?? '').toString();
        if (rel.isNotEmpty && !rel.contains('..')) {
          final candidate = File(p.normalize(p.join(rootDir.path, rel)));
          if (p.isWithin(p.normalize(rootDir.absolute.path), p.normalize(candidate.absolute.path)) &&
              await candidate.exists()) {
            isDownloaded = true;
            localPath = candidate.path;
            try {
              sz = await candidate.length();
              fileSizes[item.id] = sz;
            } catch (_) {}
          }
        }
      }

      // Escaneo inteligente por nombre/título dentro de la carpeta del ramo
      if (!isDownloaded && item.downloadable) {
        final diskHit = findDiskMatch(item);
        if (diskHit != null) {
          isDownloaded = true;
          localPath = diskHit;
          try {
            sz = await File(diskHit).length();
            fileSizes[item.id] = sz;
          } catch (_) {}
        }
      }

      if (sz <= 0 && fileSizes.containsKey(item.id)) {
        sz = (fileSizes[item.id] as num?)?.toInt() ?? 0;
      }

      item.sizeBytes = sz;
      item.isDownloaded = isDownloaded;
      item.localPath = localPath;
      item.isNew = !isDownloaded && !seenIds.containsKey(item.id);
    }
  }

  /// Obtiene tamaños faltantes vía HEAD concurrente para ítems mostrados
  Future<bool> fetchMissingFileSizes(List<MoodleItem> items) async {
    final missing = items
        .where((i) => i.downloadable && i.sizeBytes <= 0 && i.url.isNotEmpty)
        .take(40)
        .toList();
    if (missing.isEmpty || isTokenAuth) return false;

    bool changed = false;
    final fileSizes = settingsService.history['file_sizes'] as Map<String, dynamic>;

    for (var i = 0; i < missing.length; i += 6) {
      final batch = missing.sublist(i, (i + 6).clamp(0, missing.length));
      await Future.wait(batch.map((item) async {
        try {
          final req = http.Request('HEAD', Uri.parse(item.url))
            ..followRedirects = true
            ..headers['User-Agent'] = userAgent;
          if (_cookie != null && _cookie!.isNotEmpty) {
            req.headers['Cookie'] = _cookie!;
          }
          final res = await _client.send(req).timeout(const Duration(seconds: 4));
          await res.stream.drain();
          final cl = int.tryParse(res.headers['content-length'] ?? '');
          if (cl != null && cl > 0) {
            item.sizeBytes = cl;
            fileSizes[item.id] = cl;
            changed = true;
          }
        } catch (_) {}
      }));
    }

    if (changed) {
      await settingsService.saveHistory();
    }
    return changed;
  }

  String _appendQueryParam(String url, String keyValue) {
    final sep = url.contains('?') ? '&' : '?';
    return '$url$sep$keyValue';
  }

  /// Descarga un recurso resolviendo redirecciones Moodle, páginas intermedias HTML y nombre real de archivo
  Future<DownloadedFileData> downloadItemData(MoodleItem item) async {
    var targetUrl = item.url;

    if (isTokenAuth) {
      // Para wstoken, Moodle exige /webservice/pluginfile.php cuando la URL viene como /pluginfile.php/
      if (targetUrl.contains('/pluginfile.php/') &&
          !targetUrl.contains('/webservice/pluginfile.php/')) {
        targetUrl = targetUrl.replaceFirst('/pluginfile.php/', '/webservice/pluginfile.php/');
      }
      if (!targetUrl.contains('token=')) {
        targetUrl = _appendQueryParam(targetUrl, 'token=$_token');
      }
    } else {
      if (targetUrl.contains('pluginfile.php') && !targetUrl.contains('forcedownload=')) {
        targetUrl = _appendQueryParam(targetUrl, 'forcedownload=1');
      } else if (targetUrl.contains('/mod/resource/view.php') &&
          !targetUrl.contains('redirect=')) {
        targetUrl = _appendQueryParam(targetUrl, 'redirect=1');
      }
    }

    var res = await _getFollowingRedirects(
      targetUrl,
      timeout: const Duration(seconds: 45),
      sendCookie: !isTokenAuth,
    );

    if (res.statusCode != 200) {
      throw Exception('Error HTTP ${res.statusCode} al descargar "${item.title}"');
    }

    // Si Moodle devolvió página HTML envolviendo el archivo (o expiró sesión)
    if (res.contentType.contains('text/html')) {
      final htmlText = res.text;
      final lowerFinal = res.finalUri.toString().toLowerCase();
      if (lowerFinal.contains('/login/') ||
          lowerFinal.contains('/portada/') ||
          htmlText.contains('manual-login-form')) {
        throw SessionExpiredException('La sesión de Aula USM expiró. Vuelve a iniciar sesión.');
      }

      final doc = html_parser.parse(htmlText);
      final directEl = doc.querySelector(
        'a[href*="pluginfile.php"], object[data*="pluginfile.php"], iframe[src*="pluginfile.php"], embed[src*="pluginfile.php"]',
      );
      if (directEl == null) {
        throw Exception('No se encontró enlace de descarga directa en "${item.title}".');
      }

      var directUrl = directEl.attributes['href'] ??
          directEl.attributes['data'] ??
          directEl.attributes['src'] ??
          '';
      directUrl = Uri.parse(baseUrl).resolve(directUrl).toString();
      if (isTokenAuth) {
        if (directUrl.contains('/pluginfile.php/') &&
            !directUrl.contains('/webservice/pluginfile.php/')) {
          directUrl = directUrl.replaceFirst('/pluginfile.php/', '/webservice/pluginfile.php/');
        }
        if (!directUrl.contains('token=')) {
          directUrl = _appendQueryParam(directUrl, 'token=$_token');
        }
      } else if (directUrl.contains('pluginfile.php') &&
          !directUrl.contains('forcedownload=')) {
        directUrl = _appendQueryParam(directUrl, 'forcedownload=1');
      }

      res = await _getFollowingRedirects(
        directUrl,
        timeout: const Duration(seconds: 45),
        sendCookie: !isTokenAuth,
      );
      if (res.statusCode != 200 || res.contentType.contains('text/html')) {
        throw Exception('El servidor no devolvió un archivo binario para "${item.title}".');
      }
    }

    final filename = _extractFilenameFromResponse(res, item.title);
    return DownloadedFileData(
      bytes: res.bodyBytes,
      filename: filename,
      sizeBytes: res.bodyBytes.length,
    );
  }

  String _extractFilenameFromResponse(_HttpRedirectResult res, String fallbackTitle) {
    final cd = res.headers['content-disposition'] ?? '';
    if (cd.isNotEmpty) {
      final mUtf8 = RegExp(r"filename\*=UTF-8''([^;\r\n]+)", caseSensitive: false).firstMatch(cd);
      if (mUtf8 != null) {
        return MoodleCourse.sanitizeFileName(Uri.decodeComponent(mUtf8.group(1)!));
      }
      final mStd = RegExp(r'filename="?([^";\r\n]+)"?', caseSensitive: false).firstMatch(cd);
      if (mStd != null) {
        var raw = mStd.group(1)!;
        try {
          raw = Uri.decodeComponent(raw);
        } catch (_) {}
        return MoodleCourse.sanitizeFileName(_fixLatin1Utf8(raw));
      }
    }

    final pathSegs = res.finalUri.pathSegments;
    if (pathSegs.isNotEmpty) {
      var urlFn = Uri.decodeComponent(pathSegs.last);
      if (urlFn.contains('.') && !urlFn.toLowerCase().endsWith('.php')) {
        return MoodleCourse.sanitizeFileName(_fixLatin1Utf8(urlFn));
      }
    }

    var cleanFallback = MoodleCourse.sanitizeFileName(_fixLatin1Utf8(fallbackTitle));
    final ct = res.contentType;
    if (!cleanFallback.contains('.')) {
      if (ct.contains('pdf')) {
        cleanFallback += '.pdf';
      } else if (ct.contains('presentation') || ct.contains('powerpoint')) {
        cleanFallback += '.pptx';
      } else if (ct.contains('word')) {
        cleanFallback += '.docx';
      } else if (ct.contains('zip')) {
        cleanFallback += '.zip';
      } else if (ct.contains('sheet') || ct.contains('excel')) {
        cleanFallback += '.xlsx';
      } else if (ct.contains('text/plain')) {
        cleanFallback += '.txt';
      } else if (ct.contains('image/png')) {
        cleanFallback += '.png';
      } else if (ct.contains('image/jpeg')) {
        cleanFallback += '.jpg';
      }
    }
    return cleanFallback;
  }

  String _fixLatin1Utf8(String text) {
    try {
      // Corrige secuencias tipo Ã¡ -> á si alguna cabecera HTTP vino en latin1
      if (text.contains('Ã')) {
        final bytes = latin1.encode(text);
        return utf8.decode(bytes);
      }
    } catch (_) {}
    return text;
  }

  String _cleanMoodleTitle(String rawTitle) {
    var text = rawTitle.replaceAll(RegExp(r'\s+'), ' ').trim();
    const suffixes = [
      ' Archivo',
      ' Documento PDF',
      ' Carpeta',
      ' Tarea',
      ' Foro',
      ' URL',
      ' Página',
      ' File',
      ' Folder',
      ' Assignment',
    ];
    for (final s in suffixes) {
      if (text.endsWith(s)) {
        text = text.substring(0, text.length - s.length).trim();
      }
    }
    return text;
  }
}
