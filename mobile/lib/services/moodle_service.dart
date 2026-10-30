import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/course.dart';

class MoodleService {
  static const String baseUrl = 'https://aula.usm.cl';
  static const String wsUrl = '$baseUrl/webservice/rest/server.php';
  static const Map<String, String> baseHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
  };

  String? _token;
  String? _cookie;
  String? _sesskey;
  String? _userName;
  int? _userId;

  String? get userName => _userName;
  int? get userId => _userId;
  String? get sesskey => _sesskey;
  bool get isAuthenticated =>
      (_token != null && _token!.isNotEmpty) ||
      (_cookie != null && _cookie!.isNotEmpty);
  bool get isTokenAuth => _token != null && _token!.isNotEmpty;

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

    if (token != null) await prefs.setString('moodle_token', token);
    if (cookie != null) await prefs.setString('moodle_cookie', cookie);
    if (sesskey != null) await prefs.setString('moodle_sesskey', sesskey);
    if (userName != null) await prefs.setString('moodle_user_name', userName);
    if (userId != null) await prefs.setInt('moodle_user_id', userId);
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

  /// Valida y guarda un token de acceso (wstoken)
  Future<Map<String, dynamic>> loginWithToken(String token) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) {
      return {'success': false, 'message': 'El token no puede estar vacío.'};
    }

    try {
      final response = await http.post(
        Uri.parse(wsUrl),
        headers: baseHeaders,
        body: {
          'wstoken': cleanToken,
          'wsfunction': 'core_webservice_get_site_info',
          'moodlewsrestformat': 'json',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        return {
          'success': false,
          'message': 'Error del servidor (código ${response.statusCode})',
        };
      }

      final data = json.decode(response.body);
      if (data is Map && data.containsKey('errorcode')) {
        return {
          'success': false,
          'message': data['message'] ?? 'Token inválido',
        };
      }

      final user = data['fullname'] ?? data['username'] ?? 'Usuario';
      final uid = data['userid'] ?? 0;

      await saveSession(
        token: cleanToken,
        cookie: null,
        userName: user,
        userId: uid,
      );

      return {'success': true, 'user_name': user, 'user_id': uid};
    } catch (e) {
      return {'success': false, 'message': 'Error de conexión: $e'};
    }
  }

  /// Guarda una cookie obtenida vía WebView interactivo y extrae sesskey e info de usuario
  Future<Map<String, dynamic>> loginWithCookie(String cookieValue) async {
    final cleanCookie = cookieValue.trim();
    await saveSession(
      token: null,
      cookie: cleanCookie,
      userName: 'Usuario Aula',
      userId: 0,
    );

    // Intentar extraer sesskey y nombre del perfil visitando /my/
    try {
      final resp = await http.get(
        Uri.parse('$baseUrl/my/'),
        headers: {...baseHeaders, 'Cookie': cleanCookie},
      ).timeout(const Duration(seconds: 12));

      if (resp.statusCode == 200) {
        final html = resp.body;
        String? sesskeyFound;
        final mSess = RegExp(r'"sesskey"\s*:\s*"([^"]+)"').firstMatch(html) ??
            RegExp(r'logout\.php\?sesskey=([a-zA-Z0-9]+)').firstMatch(html) ??
            RegExp(r'sesskey=([a-zA-Z0-9]+)').firstMatch(html);
        if (mSess != null) sesskeyFound = mSess.group(1);

        String? userFound;
        final doc = html_parser.parse(html);
        final userEl = doc.querySelector(
          '.usermenu .usertext, .userbutton .usertext, [data-region="usermenu"] .usertext, .logininfo a[href*="user/profile.php"]',
        );
        if (userEl != null && userEl.text.trim().isNotEmpty) {
          userFound = userEl.text.trim();
        }

        int uid = 0;
        final mUid = RegExp(r'"userid"\s*:\s*(\d+)').firstMatch(html);
        if (mUid != null) uid = int.tryParse(mUid.group(1) ?? '0') ?? 0;

        await saveSession(
          token: null,
          cookie: cleanCookie,
          sesskey: sesskeyFound,
          userName: userFound ?? 'Usuario Aula',
          userId: uid,
        );
        return {'success': true, 'user_name': userFound ?? 'Usuario Aula'};
      }
    } catch (_) {}

    return {'success': true, 'user_name': 'Usuario Aula'};
  }

  /// Obtiene la lista de cursos inscritos
  Future<List<MoodleCourse>> getCourses() async {
    if (!isAuthenticated) throw Exception('No autenticado');

    if (isTokenAuth) {
      return _getCoursesWithToken();
    } else {
      return _getCoursesWithCookie();
    }
  }

  Future<List<MoodleCourse>> _getCoursesWithToken() async {
    final response = await http.post(
      Uri.parse(wsUrl),
      headers: baseHeaders,
      body: {
        'wstoken': _token!,
        'wsfunction': 'core_enrolled_courses_get_enrolled_courses',
        'userid': _userId.toString(),
        'moodlewsrestformat': 'json',
      },
    );

    final data = json.decode(response.body);
    if (data is Map && data.containsKey('errorcode')) {
      throw Exception(data['message'] ?? 'Error al obtener cursos');
    }

    final List<MoodleCourse> list = [];
    if (data is List) {
      for (final item in data) {
        final id = item['id'] as int;
        final fullname = item['fullname'] as String;
        final shortname = (item['shortname'] ?? '') as String;
        final clean = MoodleCourse.cleanCourseName(fullname);
        list.add(MoodleCourse(
          id: id,
          fullname: fullname,
          cleanName: clean,
          shortname: shortname,
        ));
      }
    }
    return list;
  }

  Future<List<MoodleCourse>> _getCoursesWithCookie() async {
    final Map<int, MoodleCourse> coursesById = {};

    // 1. Intentar vía endpoint AJAX interno de Moodle si tenemos sesskey
    if (_sesskey != null && _sesskey!.isNotEmpty) {
      for (final classification in ['inprogress', 'all']) {
        try {
          final ajaxUrl =
              '$baseUrl/lib/ajax/service.php?sesskey=$_sesskey&info=core_course_get_enrolled_courses_by_timeline_classification';
          final payload = json.encode([
            {
              'index': 0,
              'methodname':
                  'core_course_get_enrolled_courses_by_timeline_classification',
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

          final resp = await http.post(
            Uri.parse(ajaxUrl),
            headers: {
              ...baseHeaders,
              'Content-Type': 'application/json',
              'Cookie': _cookie!,
            },
            body: payload,
          );

          if (resp.statusCode == 200) {
            final data = json.decode(resp.body);
            if (data is List && data.isNotEmpty && data[0]['error'] != true) {
              final rawCourses = data[0]['data']?['courses'] as List? ?? [];
              for (final c in rawCourses) {
                final cid = c['id'] as int? ?? 0;
                if (cid <= 1) continue;
                final fn = (c['fullname'] as String? ?? '').trim();
                final sn = (c['shortname'] as String? ?? '').trim();
                if (fn.isNotEmpty) {
                  coursesById[cid] = MoodleCourse(
                    id: cid,
                    fullname: fn,
                    cleanName: MoodleCourse.cleanCourseName(fn),
                    shortname: sn,
                  );
                }
              }
            }
          }
        } catch (_) {}
      }
    }

    // 2. Extraer además desde HTML de /my/courses.php y /my/
    for (final pagePath in ['/my/courses.php', '/my/']) {
      try {
        final resp = await http.get(
          Uri.parse('$baseUrl$pagePath'),
          headers: {...baseHeaders, 'Cookie': _cookie!},
        );

        if (resp.statusCode == 200) {
          final doc = html_parser.parse(resp.body);

          // Buscar sesskey si aún no lo teníamos
          if (_sesskey == null || _sesskey!.isEmpty) {
            final mSess = RegExp(r'"sesskey"\s*:\s*"([^"]+)"')
                .firstMatch(resp.body);
            if (mSess != null) {
              _sesskey = mSess.group(1);
              saveSession(
                cookie: _cookie,
                sesskey: _sesskey,
                userName: _userName,
                userId: _userId,
              );
            }
          }

          final links = doc.querySelectorAll('a[href*="/course/view.php"]');
          for (final a in links) {
            final href = a.attributes['href'] ?? '';
            final mId = RegExp(r'[?&]id=(\d+)').firstMatch(href);
            if (mId == null) continue;
            final cid = int.tryParse(mId.group(1) ?? '0') ?? 0;
            if (cid <= 1 || coursesById.containsKey(cid)) continue;

            final multiline = a.querySelector('.multiline');
            var rawName = multiline != null ? multiline.text : a.text;
            rawName = rawName.replaceAll(RegExp(r'\s+'), ' ').trim();
            if (rawName.isNotEmpty && rawName.length > 2) {
              coursesById[cid] = MoodleCourse(
                id: cid,
                fullname: rawName,
                cleanName: MoodleCourse.cleanCourseName(rawName),
                shortname: '',
              );
            }
          }
        }
      } catch (_) {}
    }

    final result = coursesById.values.toList();
    result.sort((a, b) => a.cleanName.compareTo(b.cleanName));
    return result;
  }

  /// Obtiene las secciones y archivos de un curso (compatible con token y con cookie)
  Future<List<MoodleSection>> getCourseContents(int courseId) async {
    if (!isAuthenticated) throw Exception('No autenticado');

    if (isTokenAuth) {
      return _getContentsWithToken(courseId);
    } else {
      return _getContentsWithCookie(courseId);
    }
  }

  Future<List<MoodleSection>> _getContentsWithToken(int courseId) async {
    final response = await http.post(
      Uri.parse(wsUrl),
      headers: baseHeaders,
      body: {
        'wstoken': _token!,
        'wsfunction': 'core_course_get_contents',
        'courseid': courseId.toString(),
        'moodlewsrestformat': 'json',
      },
    );

    final data = json.decode(response.body);
    if (data is Map && data.containsKey('errorcode')) {
      throw Exception(data['message'] ?? 'Error al obtener contenidos');
    }

    final List<MoodleSection> sections = [];
    if (data is List) {
      for (final sec in data) {
        final secId = sec['id'] as int? ?? 0;
        final secName = (sec['name'] as String? ?? 'General').trim();
        final rawModules = sec['modules'] as List? ?? [];
        final List<MoodleModule> modules = [];

        for (final mod in rawModules) {
          final modName = (mod['name'] as String? ?? '').trim();
          final modType = (mod['modname'] as String? ?? '').trim();
          final contents = mod['contents'] as List? ?? [];

          if (contents.isNotEmpty) {
            for (final c in contents) {
              final fileUrl = c['fileurl'] as String? ?? '';
              final fileName = c['filename'] as String? ?? modName;
              final fileSize = c['filesize'] as int? ?? 0;

              if (fileUrl.isNotEmpty) {
                modules.add(MoodleModule(
                  id: mod['id'] as int? ?? 0,
                  name: modName.isNotEmpty ? modName : fileName,
                  modname: modType,
                  fileUrl: fileUrl,
                  fileName: fileName,
                  fileSize: fileSize,
                ));
              }
            }
          }
        }

        if (modules.isNotEmpty) {
          sections.add(MoodleSection(
            id: secId,
            name: secName.isNotEmpty ? secName : 'Contenido',
            modules: modules,
          ));
        }
      }
    }
    return sections;
  }

  Future<List<MoodleSection>> _getContentsWithCookie(int courseId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/course/view.php?id=$courseId'),
      headers: {...baseHeaders, 'Cookie': _cookie!},
    );

    if (response.statusCode != 200) {
      throw Exception('Error al acceder al curso ($courseId)');
    }

    final doc = html_parser.parse(response.body);
    final List<MoodleSection> resultSections = [];
    final Set<String> seenUrls = {};

    var sectionElements = doc.querySelectorAll(
      'li.section.main, section.course-section, div.course-section, li.section',
    );
    if (sectionElements.isEmpty) {
      sectionElements = [doc.body ?? doc.documentElement!];
    }

    for (var idx = 0; idx < sectionElements.length; idx++) {
      final sec = sectionElements[idx];
      final titleEl = sec.querySelector(
        '.sectionname, .course-section-header h3, [data-region="section-title"], h3.sectionname',
      );
      var sectionTitle = titleEl != null
          ? _cleanMoodleTitle(titleEl.text)
          : (sectionElements.length == 1 ? 'General' : 'Sección $idx');
      if (sectionTitle.isEmpty) sectionTitle = 'General';

      var activities = sec.querySelectorAll(
        'li.activity, .activity-item, [data-region="activity-item"]',
      );
      if (activities.isEmpty) {
        activities = sec.querySelectorAll(
          'a[href*="/mod/"], a[href*="pluginfile.php"]',
        );
      }

      final List<MoodleModule> modules = [];

      for (final act in activities) {
        final link = act.localName == 'a'
            ? act
            : act.querySelector(
                'a.aalink, a[href*="/mod/"], a[href*="pluginfile.php"]',
              );
        if (link == null) continue;

        var href = link.attributes['href']?.trim() ?? '';
        if (href.isEmpty) continue;
        if (!href.startsWith('http')) {
          href = Uri.parse(baseUrl).resolve(href).toString();
        }
        if (seenUrls.contains(href)) continue;
        seenUrls.add(href);

        final instancename = link.querySelector('.instancename');
        String title;
        if (instancename != null) {
          for (final h in instancename.querySelectorAll('.accesshide')) {
            h.remove();
          }
          title = instancename.text.trim();
        } else {
          title = _cleanMoodleTitle(link.text);
        }
        if (title.isEmpty) title = 'Recurso sin título';

        // Archivos descargables directos
        if (href.contains('/mod/resource/') || href.contains('pluginfile.php')) {
          final mId = RegExp(r'[?&]id=(\d+)').firstMatch(href);
          final idNum = int.tryParse(mId?.group(1) ?? '0') ?? href.hashCode;

          // Derivar nombre de archivo
          String fileName = title;
          final uriPath = Uri.tryParse(href)?.path ?? '';
          if (uriPath.contains('.')) {
            final ext = uriPath.split('.').last.split('?').first;
            if (ext.length <= 4 && !fileName.toLowerCase().endsWith('.$ext')) {
              fileName = '$fileName.$ext';
            }
          }

          modules.add(MoodleModule(
            id: idNum,
            name: title,
            modname: 'resource',
            fileUrl: href,
            fileName: fileName,
            fileSize: 0,
          ));
        } else if (href.contains('/mod/folder/')) {
          // Extraer archivos de carpetas
          final folderFiles = await _extractFolderFiles(href, sectionTitle);
          modules.addAll(folderFiles);
        }
      }

      if (modules.isNotEmpty) {
        resultSections.add(MoodleSection(
          id: idx,
          name: sectionTitle,
          modules: modules,
        ));
      }
    }

    return resultSections;
  }

  Future<List<MoodleModule>> _extractFolderFiles(
    String folderUrl,
    String sectionName,
  ) async {
    final List<MoodleModule> items = [];
    try {
      final resp = await http.get(
        Uri.parse(folderUrl),
        headers: {...baseHeaders, 'Cookie': _cookie!},
      );
      if (resp.statusCode != 200) return items;

      final doc = html_parser.parse(resp.body);
      final links = doc.querySelectorAll(
        '.fp-filename-icon a, .ygtvcontent a, a[href*="pluginfile.php"]',
      );

      for (final a in links) {
        var href = a.attributes['href']?.trim() ?? '';
        if (href.isEmpty) continue;
        if (!href.startsWith('http')) {
          href = Uri.parse(baseUrl).resolve(href).toString();
        }

        final title = a.text.trim();
        final fileName = title.isNotEmpty
            ? title
            : (Uri.tryParse(href)?.pathSegments.last ?? 'archivo');
        final idNum = href.hashCode;

        items.add(MoodleModule(
          id: idNum,
          name: fileName,
          modname: 'folder_file',
          fileUrl: href,
          fileName: fileName,
          fileSize: 0,
        ));
      }
    } catch (_) {}
    return items;
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

  /// Descarga los bytes de un archivo usando el token o la cookie
  Future<List<int>> downloadFileBytes(String fileUrl) async {
    var finalUrl = fileUrl;
    if (isTokenAuth && !finalUrl.contains('token=')) {
      finalUrl += (finalUrl.contains('?') ? '&' : '?') + 'token=$_token';
    }

    final headers = <String, String>{...baseHeaders};
    if (!isTokenAuth && _cookie != null) {
      headers['Cookie'] = _cookie!;
    }

    final resp = await http.get(Uri.parse(finalUrl), headers: headers);
    if (resp.statusCode != 200) {
      throw Exception('HTTP error ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }
}
