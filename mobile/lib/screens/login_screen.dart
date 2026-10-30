import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/moodle_service.dart';
import 'courses_screen.dart';

class LoginScreen extends StatefulWidget {
  final MoodleService moodleService;

  const LoginScreen({super.key, required this.moodleService});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _tokenController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _loginWithToken() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      setState(() => _errorMessage = 'Ingresa un token de acceso válido.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final res = await widget.moodleService.loginWithToken(token);
    setState(() => _isLoading = false);

    if (res['success'] == true && mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => CoursesScreen(moodleService: widget.moodleService),
        ),
      );
    } else {
      setState(() => _errorMessage = res['message'] ?? 'Error desconocido');
    }
  }

  void _openWebViewLogin() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _WebViewLoginScreen(
          moodleService: widget.moodleService,
          onSuccess: () {
            Navigator.of(context).pop();
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => CoursesScreen(moodleService: widget.moodleService),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1117),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset(
                    'assets/logo.png',
                    width: 80,
                    height: 80,
                    errorBuilder: (_, __, ___) => Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: const Color(0xFF161B22),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFF30363D)),
                      ),
                      child: const Icon(Icons.school, color: Color(0xFF38BDF8), size: 40),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Aula-Scrapt',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Sincronizador USM para Obsidian',
                  style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFF8B949E),
                  ),
                ),
                const SizedBox(height: 36),

                // Error message banner
                if (_errorMessage != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF3D1619),
                      border: Border.all(color: const Color(0xFFF85149)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Color(0xFFFF7B72), fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                // Opción 1: Token de Acceso
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF161B22),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF30363D)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Token de Acceso (wstoken)',
                        style: TextStyle(
                          color: Color(0xFFC9D1D9),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Obtenlo en Aula USM > Perfil > Preferencias > Claves de seguridad',
                        style: TextStyle(color: Color(0xFF8B949E), fontSize: 12),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _tokenController,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          hintText: 'Pega tu token aquí...',
                          hintStyle: const TextStyle(color: Color(0xFF484F58)),
                          filled: true,
                          fillColor: const Color(0xFF0D1117),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const Color(0xFF30363D) == Colors.transparent
                                ? BorderSide.none
                                : const BorderSide(color: Color(0xFF30363D)),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        ),
                      ),
                      const SizedBox(height: 14),
                      ElevatedButton(
                        onPressed: _isLoading ? null : _loginWithToken,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF238636),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          elevation: 0,
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Text('Conectar con Token', style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),
                const Row(
                  children: [
                    Expanded(child: Divider(color: Color(0xFF30363D))),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14),
                      child: Text('o ingresa mediante navegador', style: TextStyle(color: Color(0xFF8B949E), fontSize: 12)),
                    ),
                    Expanded(child: Divider(color: Color(0xFF30363D))),
                  ],
                ),
                const SizedBox(height: 20),

                // Opción 2: Login con WebView (Microsoft 365)
                OutlinedButton.icon(
                  onPressed: _openWebViewLogin,
                  icon: const Icon(Icons.open_in_browser, size: 18, color: Color(0xFF58A6FF)),
                  label: const Text('Iniciar sesión en Navegador (WebView)', style: TextStyle(color: Color(0xFF58A6FF), fontWeight: FontWeight.w600)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF30363D)),
                    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    backgroundColor: const Color(0xFF161B22),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WebViewLoginScreen extends StatefulWidget {
  final MoodleService moodleService;
  final VoidCallback onSuccess;

  const _WebViewLoginScreen({required this.moodleService, required this.onSuccess});

  @override
  State<_WebViewLoginScreen> createState() => _WebViewLoginScreenState();
}

class _WebViewLoginScreenState extends State<_WebViewLoginScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            setState(() => _isLoading = true);
            _checkAuth(url);
          },
          onPageFinished: (url) {
            setState(() => _isLoading = false);
            _checkAuth(url);
          },
        ),
      )
      ..loadRequest(Uri.parse('https://aula.usm.cl/login/index.php'));
  }

  Future<void> _checkAuth(String url) async {
    final lower = url.toLowerCase();
    // Cuando el usuario entra a /my/ o cursos y sale de portada/login
    if (lower.contains('aula.usm.cl') &&
        !lower.contains('/portada') &&
        !lower.contains('/login') &&
        !lower.contains('/auth/')) {
      final cookie = await _controller.runJavaScriptReturningResult('document.cookie') as String;
      if (cookie.contains('MoodleSession=')) {
        final match = RegExp(r'MoodleSession=([^;]+)').firstMatch(cookie);
        if (match != null) {
          final cookieVal = match.group(0)!;
          await widget.moodleService.loginWithCookie(cookieVal);
          widget.onSuccess();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Aula USM — Iniciar sesión', style: TextStyle(fontSize: 16)),
        backgroundColor: const Color(0xFF161B22),
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
            ),
        ],
      ),
    );
  }
}
