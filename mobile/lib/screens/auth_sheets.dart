import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/moodle_service.dart';

/// Muestra el modal para ingresar Token de Acceso (wstoken), equivalente a #token-modal en .exe
Future<bool> showTokenLoginDialog(
  BuildContext context,
  MoodleService moodleService,
) async {
  final controller = TextEditingController();
  bool isLoading = false;
  String? errorMsg;

  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        backgroundColor: const Color(0xFF17171C),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF2A2A33)),
        ),
        title: const Text(
          'Token de Acceso (wstoken)',
          style: TextStyle(color: Color(0xFFF3F4F6), fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Obtenlo en Aula USM > Perfil > Preferencias > Claves de seguridad:',
                style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(
                  color: Color(0xFFF3F4F6),
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
                decoration: InputDecoration(
                  hintText: 'Pega tu token de Moodle aquí',
                  hintStyle: const TextStyle(color: Color(0xFF6B7280)),
                  filled: true,
                  fillColor: const Color(0xFF0F0F12),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF2A2A33)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF2A2A33)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF38BDF8)),
                  ),
                ),
              ),
              if (errorMsg != null) ...[
                const SizedBox(height: 10),
                Text(
                  errorMsg!,
                  style: const TextStyle(color: Color(0xFFF87171), fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: isLoading ? null : () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar', style: TextStyle(color: Color(0xFF9CA3AF))),
          ),
          ElevatedButton(
            onPressed: isLoading
                ? null
                : () async {
                    setDialogState(() {
                      isLoading = true;
                      errorMsg = null;
                    });
                    final res = await moodleService.loginWithToken(controller.text);
                    if (!ctx.mounted) return;
                    if (res['success'] == true) {
                      Navigator.of(ctx).pop(true);
                    } else {
                      setDialogState(() {
                        isLoading = false;
                        errorMsg = res['message']?.toString() ?? 'Token inválido';
                      });
                    }
                  },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF3F4F6),
              foregroundColor: const Color(0xFF0F0F12),
            ),
            child: isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0F0F12)),
                  )
                : const Text('Conectar con Token', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  return result == true;
}

/// Muestra el modal para ingresar Cookie MoodleSession, equivalente a #cookie-modal en .exe
Future<bool> showCookieLoginDialog(
  BuildContext context,
  MoodleService moodleService,
) async {
  final controller = TextEditingController();
  bool isLoading = false;
  String? errorMsg;

  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        backgroundColor: const Color(0xFF17171C),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: Color(0xFF2A2A33)),
        ),
        title: const Text(
          'Cookie MoodleSession',
          style: TextStyle(color: Color(0xFFF3F4F6), fontSize: 16, fontWeight: FontWeight.w600),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Pega el valor de la cookie MoodleSession de aula.usm.cl:',
                style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12, height: 1.4),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(
                  color: Color(0xFFF3F4F6),
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
                decoration: InputDecoration(
                  hintText: 'Valor de MoodleSession',
                  hintStyle: const TextStyle(color: Color(0xFF6B7280)),
                  filled: true,
                  fillColor: const Color(0xFF0F0F12),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF2A2A33)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF2A2A33)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFF38BDF8)),
                  ),
                ),
              ),
              if (errorMsg != null) ...[
                const SizedBox(height: 10),
                Text(
                  errorMsg!,
                  style: const TextStyle(color: Color(0xFFF87171), fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: isLoading ? null : () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar', style: TextStyle(color: Color(0xFF9CA3AF))),
          ),
          ElevatedButton(
            onPressed: isLoading
                ? null
                : () async {
                    setDialogState(() {
                      isLoading = true;
                      errorMsg = null;
                    });
                    final res = await moodleService.loginWithCookie(controller.text);
                    if (!ctx.mounted) return;
                    if (res['success'] == true) {
                      Navigator.of(ctx).pop(true);
                    } else {
                      setDialogState(() {
                        isLoading = false;
                        errorMsg = res['message']?.toString() ?? 'Cookie inválida';
                      });
                    }
                  },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF3F4F6),
              foregroundColor: const Color(0xFF0F0F12),
            ),
            child: isLoading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0F0F12)),
                  )
                : const Text('Verificar y guardar', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  return result == true;
}

/// Pantalla WebView interactiva para iniciar sesión con Microsoft 365 + 2FA y capturar todas las cookies de aula.usm.cl
class WebViewLoginScreen extends StatefulWidget {
  final MoodleService moodleService;
  final bool clearExistingCookies;

  const WebViewLoginScreen({
    super.key,
    required this.moodleService,
    this.clearExistingCookies = false,
  });

  @override
  State<WebViewLoginScreen> createState() => _WebViewLoginScreenState();
}

class _WebViewLoginScreenState extends State<WebViewLoginScreen> {
  WebViewController? _controller;
  late final WebViewCookieManager _cookieManager;
  bool _isLoading = true;
  bool _isVerifying = false;
  bool _foundSession = false;
  String _currentUrl = 'https://aula.usm.cl/login/index.php';

  @override
  void initState() {
    super.initState();
    _cookieManager = WebViewCookieManager();
    _initWebView();
  }

  Future<void> _initWebView() async {
    if (widget.clearExistingCookies) {
      await _cookieManager.clearCookies();
    }

    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(MoodleService.userAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            if (!mounted) return;
            setState(() {
              _isLoading = true;
              _currentUrl = url;
            });
          },
          onPageFinished: (url) {
            if (!mounted) return;
            setState(() {
              _isLoading = false;
              _currentUrl = url;
            });
            _checkAuth(url, manualTrigger: false);
          },
        ),
      )
      ..loadRequest(Uri.parse('https://aula.usm.cl/login/index.php'));

    if (mounted) {
      setState(() => _controller = ctrl);
    }
  }

  Future<void> _checkAuth(String url, {bool manualTrigger = false}) async {
    if (_foundSession || _isVerifying) return;
    final lower = url.toLowerCase();
    final isInsideAula = lower.contains('aula.usm.cl') &&
        !lower.contains('/portada') &&
        !lower.contains('/login') &&
        !lower.contains('/auth/') &&
        !lower.contains('microsoftonline.com');

    if (!isInsideAula && !manualTrigger) return;

    setState(() => _isVerifying = true);
    try {
      final cookies = await _cookieManager.getCookies(
        domain: Uri.parse('https://aula.usm.cl'),
      );
      final moodleSession = cookies.firstWhere(
        (c) => c.name == 'MoodleSession',
        orElse: () => const WebViewCookie(name: '', value: '', domain: ''),
      );

      if (moodleSession.value.isNotEmpty) {
        final cookieHeader = cookies
            .where((c) => c.name.isNotEmpty && c.value.isNotEmpty)
            .map((c) => '${c.name}=${c.value}')
            .join('; ');
        final res = await widget.moodleService.loginWithCookie(cookieHeader);
        if (res['success'] == true) {
          _foundSession = true;
          if (mounted) {
            Navigator.of(context).pop(true);
          }
          return;
        }
      }

      if (manualTrigger && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Aún no se detecta sesión activa en Aula USM. Completa el login primero.'),
            backgroundColor: Color(0xFFB45309),
          ),
        );
      }
    } catch (_) {
    } finally {
      if (mounted) {
        setState(() => _isVerifying = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF17171C),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Aula USM — Iniciar sesión', style: TextStyle(fontSize: 15)),
            Text(
              _currentUrl,
              style: const TextStyle(fontSize: 10, color: Color(0xFF9CA3AF)),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _isVerifying ? null : () => _checkAuth(_currentUrl, manualTrigger: true),
            child: _isVerifying
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF38BDF8)),
                  )
                : const Text('Verificar', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 12)),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_controller != null)
            WebViewWidget(controller: _controller!)
          else
            const Center(
              child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
            ),
          if (_isLoading)
            const LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: Color(0xFF38BDF8),
            ),
        ],
      ),
    );
  }
}

/// Visor autenticado para botón 'Abrir' en tareas, foros, enlaces o páginas
class AuthenticatedWebViewerScreen extends StatefulWidget {
  final String title;
  final String url;
  final MoodleService moodleService;

  const AuthenticatedWebViewerScreen({
    super.key,
    required this.title,
    required this.url,
    required this.moodleService,
  });

  @override
  State<AuthenticatedWebViewerScreen> createState() =>
      _AuthenticatedWebViewerScreenState();
}

class _AuthenticatedWebViewerScreenState extends State<AuthenticatedWebViewerScreen> {
  WebViewController? _controller;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initViewer();
  }

  Future<void> _initViewer() async {
    final cm = WebViewCookieManager();
    final rawCookie = widget.moodleService.cookie;
    if (rawCookie != null &&
        rawCookie.isNotEmpty &&
        widget.url.toLowerCase().contains('aula.usm.cl')) {
      for (final part in rawCookie.split(';')) {
        final idx = part.indexOf('=');
        if (idx > 0) {
          final k = part.substring(0, idx).trim();
          final v = part.substring(idx + 1).trim();
          if (k.isNotEmpty && v.isNotEmpty) {
            await cm.setCookie(
              WebViewCookie(name: k, value: v, domain: 'aula.usm.cl', path: '/'),
            );
          }
        }
      }
    }

    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(MoodleService.userAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _isLoading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _isLoading = false);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));

    if (mounted) setState(() => _controller = ctrl);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F12),
      appBar: AppBar(
        backgroundColor: const Color(0xFF17171C),
        title: Text(widget.title, style: const TextStyle(fontSize: 15)),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new, size: 20),
            tooltip: 'Abrir en navegador externo',
            onPressed: () async {
              final uri = Uri.tryParse(widget.url);
              if (uri != null) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_controller != null)
            WebViewWidget(controller: _controller!)
          else
            const Center(
              child: CircularProgressIndicator(color: Color(0xFF38BDF8)),
            ),
          if (_isLoading)
            const LinearProgressIndicator(
              minHeight: 2,
              backgroundColor: Colors.transparent,
              color: Color(0xFF38BDF8),
            ),
        ],
      ),
    );
  }
}
