import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/course.dart';

class MoodleService {
  static const String baseUrl = 'https://aula.usm.cl';
  static const String wsUrl = '$baseUrl/webservice/rest/server.php';
  static const Map<String, String> baseHeaders = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
  };

  String? _token;
  String? _cookie;
  String? _userName;
  int? _userId;

  String? get userName => _userName;
  int? get userId => _userId;
  bool get isAuthenticated => (_token != null && _token!.isNotEmpty) || (_cookie != null && _cookie!.isNotEmpty);
  bool get isTokenAuth => _token != null && _token!.isNotEmpty;

  Future<void> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('moodle_token');
    _cookie = prefs.getString('moodle_cookie');
    _userName = prefs.getString('moodle_user_name');
    _userId = prefs.getInt('moodle_user_id');
  }

  Future<void> saveSession({String? token, String? cookie, String? userName, int? userId}) async {
    final prefs = await SharedPreferences.getInstance();
    _token = token;
    _cookie = cookie;
    _userName = userName;
    _userId = userId;

    if (token != null) await prefs.setString('moodle_token', token);
    if (cookie != null) await prefs.setString('moodle_cookie', cookie);
    if (userName != null) await prefs.setString('moodle_user_name', userName);
    if (userId != null) await prefs.setInt('moodle_user_id', userId);
  }

  Future<void> logout() async {
    _token = null;
    _cookie = null;
    _userName = null;
    _userId = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('moodle_token');
    await prefs.remove('moodle_cookie');
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
      ).timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) {
        return {'success': false, 'message': 'Error del servidor (código ${response.statusCode})'};
      }

      final data = json.decode(response.body);
      if (data is Map && data.containsKey('errorcode')) {
        return {'success': false, 'message': data['message'] ?? 'Token inválido'};
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

  /// Guarda una cookie obtenida vía WebView interactivo
  Future<Map<String, dynamic>> loginWithCookie(String cookieValue, {String? userName, int? userId}) async {
    await saveSession(
      token: null,
      cookie: cookieValue.trim(),
      userName: userName ?? 'Usuario Aula',
      userId: userId ?? 0,
    );
    return {'success': true, 'user_name': userName ?? 'Usuario Aula'};
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
    // Si usa cookie, consulta el endpoint mobile timeline de Moodle
    final response = await http.get(
      Uri.parse('$baseUrl/my/courses.php'),
      headers: {
        ...baseHeaders,
        'Cookie': _cookie!,
      },
    );

    final html = response.body;
    final List<MoodleCourse> list = [];
    final matches = RegExp(r'href="[^"]*\/course\/view\.php\?id=(\d+)"[^>]*>[\s\S]*?<span class="multiline"[^>]*>([\s\S]*?)<\/span>').allMatches(html);

    for (final m in matches) {
      final id = int.tryParse(m.group(1) ?? '0') ?? 0;
      final rawName = m.group(2)?.replaceAll(RegExp(r'<[^>]*>'), '').trim() ?? '';
      if (id > 0 && rawName.isNotEmpty) {
        list.add(MoodleCourse(
          id: id,
          fullname: rawName,
          cleanName: MoodleCourse.cleanCourseName(rawName),
          shortname: '',
        ));
      }
    }
    return list;
  }

  /// Obtiene las secciones y archivos de un curso
  Future<List<MoodleSection>> getCourseContents(int courseId) async {
    if (!isAuthenticated) throw Exception('No autenticado');

    if (isTokenAuth) {
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
    } else {
      // Retorna lista básica si es por cookie
      return [];
    }
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
