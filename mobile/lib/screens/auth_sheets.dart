import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/moodle_service.dart';

/// Sheet modal Material 3 para ingresar Token de Acceso (wstoken)
Future<bool> showTokenLoginDialog(
  BuildContext context,
  MoodleService moodleService,
) {
  return _showCredentialSheet(
    context: context,
    title: 'Token de Acceso (wstoken)',
    subtitle: 'Obtenlo en Aula USM > Perfil > Preferencias > Claves de seguridad.',
    fieldLabel: 'Token de Moodle',
    hintText: 'Pega aquí tu wstoken',
    actionLabel: 'Conectar con Token',
    icon: Icons.key_rounded,
    onSubmit: moodleService.loginWithToken,
  );
}

/// Sheet modal Material 3 para ingresar Cookie MoodleSession
Future<bool> showCookieLoginDialog(
  BuildContext context,
  MoodleService moodleService,
) {
  return _showCredentialSheet(
    context: context,
    title: 'Cookie MoodleSession',
    subtitle: 'Pega el valor de la cookie MoodleSession activa de aula.usm.cl.',
    fieldLabel: 'MoodleSession',
    hintText: 'Valor de MoodleSession',
    actionLabel: 'Verificar y guardar',
    icon: Icons.cookie_outlined,
    onSubmit: moodleService.loginWithCookie,
  );
}

Future<bool> _showCredentialSheet({
  required BuildContext context,
  required String title,
  required String subtitle,
  required String fieldLabel,
  required String hintText,
  required String actionLabel,
  required IconData icon,
  required Future<Map<String, dynamic>> Function(String value) onSubmit,
}) async {
  final controller = TextEditingController();
  bool isLoading = false;
  String? errorMsg;

  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) {
        final cs = Theme.of(ctx).colorScheme;
        final tt = Theme.of(ctx).textTheme;
        final keyboardInset = MediaQuery.of(ctx).viewInsets.bottom;

        return Padding(
          padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + keyboardInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: cs.onPrimaryContainer, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                subtitle,
                style: tt.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(fontSize: 13.5, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: fieldLabel,
                  hintText: hintText,
                  suffixIcon: IconButton(
                    tooltip: 'Pegar del portapapeles',
                    onPressed: () async {
                      final clip = await Clipboard.getData(Clipboard.kTextPlain);
                      final txt = clip?.text?.trim() ?? '';
                      if (txt.isNotEmpty) {
                        controller.text = txt;
                        setSheetState(() => errorMsg = null);
                      }
                    },
                    icon: const Icon(Icons.content_paste_rounded),
                  ),
                ),
              ),
              if (errorMsg != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    errorMsg!,
                    style: tt.bodySmall?.copyWith(color: cs.onErrorContainer),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: isLoading ? null : () => Navigator.of(ctx).pop(false),
                      child: const Text('Cancelar'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: isLoading
                          ? null
                          : () async {
                              setSheetState(() {
                                isLoading = true;
                                errorMsg = null;
                              });
                              final res = await onSubmit(controller.text);
                              if (!ctx.mounted) return;
                              if (res['success'] == true) {
                                Navigator.of(ctx).pop(true);
                              } else {
                                setSheetState(() {
                                  isLoading = false;
                                  errorMsg = res['message']?.toString() ?? 'Credencial inválida';
                                });
                              }
                            },
                      child: isLoading
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: cs.onPrimary,
                              ),
                            )
                          : Text(actionLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );

  controller.dispose();
  return result == true;
}

/// Pantalla WebView interactiva para iniciar sesión con Microsoft 365 + 2FA
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
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Aula USM — Iniciar sesión', style: TextStyle(fontSize: 16)),
            Text(
              _currentUrl,
              style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: FilledButton.tonal(
              onPressed:
                  _isVerifying ? null : () => _checkAuth(_currentUrl, manualTrigger: true),
              style: FilledButton.styleFrom(
                minimumSize: const Size(84, 38),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              child: _isVerifying
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Verificar'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            if (_controller != null)
              WebViewWidget(controller: _controller!)
            else
              const Center(child: CircularProgressIndicator()),
            if (_isLoading)
              const LinearProgressIndicator(minHeight: 3),
          ],
        ),
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
      appBar: AppBar(
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new_rounded),
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
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            if (_controller != null)
              WebViewWidget(controller: _controller!)
            else
              const Center(child: CircularProgressIndicator()),
            if (_isLoading)
              const LinearProgressIndicator(minHeight: 3),
          ],
        ),
      ),
    );
  }
}
