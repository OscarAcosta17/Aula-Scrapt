import 'package:flutter/material.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F12),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Image.asset(
                        'assets/logo.png',
                        width: 74,
                        height: 74,
                        errorBuilder: (_, _, _) => Container(
                          width: 74,
                          height: 74,
                          color: const Color(0xFF17171C),
                          child: const Icon(Icons.layers, color: Color(0xFF38BDF8), size: 38),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Aula-Scrapt USM',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFF3F4F6),
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Sincroniza archivos y grafos Obsidian (.md) directamente en tu dispositivo.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                  ),
                  const SizedBox(height: 24),

                  // Selector de los 3 métodos de acceso (paridad .exe)
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF17171C),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF2A2A33)),
                    ),
                    child: Row(
                      children: [
                        _AuthTabButton(
                          label: 'Navegador',
                          selected: _selectedMode == 0,
                          onTap: () => setState(() {
                            _selectedMode = 0;
                            _errorMessage = null;
                          }),
                        ),
                        _AuthTabButton(
                          label: 'Token',
                          selected: _selectedMode == 1,
                          onTap: () => setState(() {
                            _selectedMode = 1;
                            _errorMessage = null;
                            _inputController.clear();
                          }),
                        ),
                        _AuthTabButton(
                          label: 'Cookie',
                          selected: _selectedMode == 2,
                          onTap: () => setState(() {
                            _selectedMode = 2;
                            _errorMessage = null;
                            _inputController.clear();
                          }),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Tarjeta activa según método elegido
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFF17171C),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF2A2A33)),
                    ),
                    child: _selectedMode == 0
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Inicio de sesión interactivo (Microsoft 365)',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFF3F4F6),
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Se abrirá Aula USM dentro de la app para ingresar con tu cuenta institucional USM y verificación en 2 pasos.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF9CA3AF),
                                  height: 1.45,
                                ),
                              ),
                              const SizedBox(height: 18),
                              ElevatedButton.icon(
                                onPressed: _openWebViewLogin,
                                icon: const Icon(Icons.login, size: 18),
                                label: const Text(
                                  'Iniciar sesión en Aula USM',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFF3F4F6),
                                  foregroundColor: const Color(0xFF0F0F12),
                                  padding: const EdgeInsets.symmetric(vertical: 13),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(7),
                                  ),
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
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFF3F4F6),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _selectedMode == 1
                                    ? 'Obtenlo en Aula USM > Perfil > Preferencias > Claves de seguridad.'
                                    : 'Pega el valor de la cookie MoodleSession activa de aula.usm.cl.',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF9CA3AF),
                                  height: 1.45,
                                ),
                              ),
                              const SizedBox(height: 14),
                              TextField(
                                controller: _inputController,
                                style: const TextStyle(
                                  color: Color(0xFFF3F4F6),
                                  fontSize: 13,
                                  fontFamily: 'monospace',
                                ),
                                decoration: InputDecoration(
                                  hintText: _selectedMode == 1
                                      ? 'Ej: 7a8b9c0d1e2f3a4b...'
                                      : 'Valor de MoodleSession',
                                  hintStyle: const TextStyle(color: Color(0xFF6B7280)),
                                  filled: true,
                                  fillColor: const Color(0xFF0F0F12),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 11,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(7),
                                    borderSide: const BorderSide(color: Color(0xFF2A2A33)),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(7),
                                    borderSide: const BorderSide(color: Color(0xFF2A2A33)),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(7),
                                    borderSide: const BorderSide(color: Color(0xFF38BDF8)),
                                  ),
                                ),
                              ),
                              if (_errorMessage != null) ...[
                                const SizedBox(height: 10),
                                Text(
                                  _errorMessage!,
                                  style: const TextStyle(color: Color(0xFFF87171), fontSize: 12),
                                ),
                              ],
                              const SizedBox(height: 16),
                              ElevatedButton(
                                onPressed: _isLoading ? null : _submitCredential,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFFF3F4F6),
                                  foregroundColor: const Color(0xFF0F0F12),
                                  padding: const EdgeInsets.symmetric(vertical: 13),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(7),
                                  ),
                                ),
                                child: _isLoading
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Color(0xFF0F0F12),
                                        ),
                                      )
                                    : Text(
                                        _selectedMode == 1
                                            ? 'Conectar con Token'
                                            : 'Verificar y guardar Cookie',
                                        style: const TextStyle(fontWeight: FontWeight.w600),
                                      ),
                              ),
                            ],
                          ),
                  ),

                  const SizedBox(height: 16),
                  const Text(
                    'Tu sesión se guarda únicamente de forma local en este teléfono.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthTabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _AuthTabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF26262E) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: selected ? Border.all(color: const Color(0xFF38BDF8), width: 1) : null,
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? const Color(0xFFF3F4F6) : const Color(0xFF9CA3AF),
            ),
          ),
        ),
      ),
    );
  }
}
