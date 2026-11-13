import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/moodle_service.dart';
import '../services/settings_service.dart';
import 'auth_sheets.dart';
import 'courses_screen.dart';

class LoginScreen extends StatefulWidget {
  final MoodleService moodleService;
  final SettingsService settingsService;

  const LoginScreen({
    super.key,
    required this.moodleService,
    required this.settingsService,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  int _selectedMode = 0; // 0 = WebView, 1 = Token, 2 = Cookie
  final _inputController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  void _goToCourses() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CoursesScreen(
          moodleService: widget.moodleService,
          settingsService: widget.settingsService,
        ),
      ),
    );
  }

  Future<void> _openWebViewLogin() async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WebViewLoginScreen(
          moodleService: widget.moodleService,
          clearExistingCookies: false,
        ),
      ),
    );
    if (ok == true) {
      _goToCourses();
    }
  }

  Future<void> _pasteFromClipboard() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final txt = clip?.text?.trim() ?? '';
    if (txt.isNotEmpty) {
      _inputController.text = txt;
      setState(() => _errorMessage = null);
    }
  }

  Future<void> _submitCredential() async {
    final val = _inputController.text.trim();
    if (val.isEmpty) {
      setState(() => _errorMessage = _selectedMode == 1
          ? 'Ingresa un token de acceso válido.'
          : 'Ingresa el valor de la cookie MoodleSession.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final res = _selectedMode == 1
        ? await widget.moodleService.loginWithToken(val)
        : await widget.moodleService.loginWithCookie(val);

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (res['success'] == true) {
      _goToCourses();
    } else {
      setState(() => _errorMessage = res['message']?.toString() ?? 'Error al autenticar');
    }
  }

  Widget _buildHeroSection(BuildContext context, {bool alignedLeft = false}) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          alignedLeft ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: cs.primaryContainer.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(24),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Image.asset(
              'assets/logo.png',
              width: 76,
              height: 76,
              errorBuilder: (_, _, _) => Container(
                width: 76,
                height: 76,
                color: cs.surfaceContainerHighest,
                child: Icon(Icons.layers_rounded, color: cs.primary, size: 38),
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'Aula-Scrapt USM',
          textAlign: alignedLeft ? TextAlign.left : TextAlign.center,
          style: tt.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Sincroniza materiales de tus ramos y grafos Obsidian (.md) directamente en tu Android.',
          textAlign: alignedLeft ? TextAlign.left : TextAlign.center,
          style: tt.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.verified_user_outlined, size: 15, color: cs.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Sesión cifrada localmente en el teléfono',
                  textAlign: TextAlign.center,
                  style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAuthPanel(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<int>(
          showSelectedIcon: false,
          selected: {_selectedMode},
          onSelectionChanged: (sel) {
            setState(() {
              _selectedMode = sel.first;
              _errorMessage = null;
              if (_selectedMode != 0) _inputController.clear();
            });
          },
          segments: const [
            ButtonSegment<int>(
              value: 0,
              icon: Icon(Icons.public_rounded, size: 17),
              label: Text('Navegador', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ButtonSegment<int>(
              value: 1,
              icon: Icon(Icons.key_rounded, size: 17),
              label: Text('Token', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ButtonSegment<int>(
              value: 2,
              icon: Icon(Icons.cookie_outlined, size: 17),
              label: Text('Cookie', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Card(
          color: cs.surfaceContainerHigh,
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: _selectedMode == 0
                  ? Column(
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
                              child: Icon(
                                Icons.school_rounded,
                                color: cs.onPrimaryContainer,
                                size: 22,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Cuenta Institucional USM',
                                    style: tt.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    'Microsoft 365 con verificación en 2 pasos',
                                    style: tt.bodySmall?.copyWith(
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Se abrirá Aula USM dentro de la app para capturar tu sesión automáticamente al completar el ingreso.',
                          style: tt.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 22),
                        FilledButton.icon(
                          onPressed: _openWebViewLogin,
                          icon: const Icon(Icons.login_rounded),
                          label: const Text('Iniciar sesión en Aula USM'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _selectedMode == 1
                              ? 'Token de Acceso (wstoken)'
                              : 'Cookie MoodleSession',
                          style: tt.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _selectedMode == 1
                              ? 'Obtenlo en Aula USM > Perfil > Preferencias > Claves de seguridad.'
                              : 'Pega el valor de la cookie MoodleSession activa de aula.usm.cl.',
                          style: tt.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _inputController,
                          style: const TextStyle(
                            fontSize: 14,
                            fontFamily: 'monospace',
                          ),
                          decoration: InputDecoration(
                            labelText: _selectedMode == 1 ? 'Token' : 'MoodleSession',
                            hintText: _selectedMode == 1
                                ? 'Ej: 7a8b9c0d1e2f3a4b...'
                                : 'Valor de la cookie',
                            suffixIcon: IconButton(
                              tooltip: 'Pegar del portapapeles',
                              onPressed: _pasteFromClipboard,
                              icon: const Icon(Icons.content_paste_rounded),
                            ),
                          ),
                        ),
                        if (_errorMessage != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: cs.errorContainer,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              _errorMessage!,
                              style: tt.bodySmall?.copyWith(
                                color: cs.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 18),
                        FilledButton(
                          onPressed: _isLoading ? null : _submitCredential,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                          ),
                          child: _isLoading
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: cs.onPrimary,
                                  ),
                                )
                              : Text(
                                  _selectedMode == 1
                                      ? 'Conectar con Token'
                                      : 'Verificar y guardar Cookie',
                                ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              cs.primaryContainer.withValues(alpha: 0.22),
              cs.surface,
              cs.secondaryContainer.withValues(alpha: 0.14),
            ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 680;
              return Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: isWide ? 36 : 20,
                    vertical: 24,
                  ),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: isWide ? 920 : 440),
                    child: isWide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                flex: 5,
                                child: _buildHeroSection(context, alignedLeft: true),
                              ),
                              const SizedBox(width: 40),
                              Expanded(
                                flex: 6,
                                child: _buildAuthPanel(context),
                              ),
                            ],
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildHeroSection(context),
                              const SizedBox(height: 28),
                              _buildAuthPanel(context),
                            ],
                          ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
