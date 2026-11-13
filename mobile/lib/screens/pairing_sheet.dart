import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/moodle_service.dart';
import '../services/settings_service.dart';

/// Muestra el modal Material 3 para vincular el teléfono con Aula-Scrapt PC vía QR o PIN.
Future<bool> showPairingSheet(
  BuildContext context, {
  required MoodleService moodleService,
  required SettingsService settingsService,
}) async {
  final res = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => _PairingSheet(
      moodleService: moodleService,
      settingsService: settingsService,
    ),
  );
  return res == true;
}

class _PairingSheet extends StatefulWidget {
  final MoodleService moodleService;
  final SettingsService settingsService;

  const _PairingSheet({
    required this.moodleService,
    required this.settingsService,
  });

  @override
  State<_PairingSheet> createState() => _PairingSheetState();
}

class _PairingSheetState extends State<_PairingSheet> {
  final TextEditingController _hostController = TextEditingController();
  final TextEditingController _pinController = TextEditingController();

  bool _isWorking = false;
  String? _statusText;
  String? _errorText;

  @override
  void dispose() {
    _hostController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  String _normalizeHost(String raw) {
    var clean = raw.trim();
    if (clean.isEmpty) return '';
    if (!clean.startsWith('http://') && !clean.startsWith('https://')) {
      clean = 'http://$clean';
    }
    final uri = Uri.tryParse(clean);
    if (uri == null || uri.host.isEmpty) return '';
    final port = uri.hasPort ? uri.port : 8000;
    return '${uri.scheme}://${uri.host}:$port';
  }

  Future<void> _scanWithCamera() async {
    setState(() {
      _errorText = null;
      _statusText = null;
    });

    try {
      final raw = await widget.settingsService.scanQrCode();
      if (!mounted || raw == null || raw.trim().isEmpty) return;

      final trimmed = raw.trim();
      String host = '';
      String pin = '';

      if (trimmed.startsWith('{')) {
        final decoded = json.decode(trimmed);
        if (decoded is Map) {
          host = (decoded['u'] ?? decoded['url'] ?? '').toString().trim();
          pin = (decoded['p'] ?? decoded['pin'] ?? '').toString().trim();
        }
      } else {
        final uri = Uri.tryParse(trimmed);
        if (uri != null && uri.host.isNotEmpty) {
          host = '${uri.scheme}://${uri.host}:${uri.hasPort ? uri.port : 8000}';
          pin = (uri.queryParameters['pin'] ?? '').trim();
        }
      }

      if (host.isEmpty || pin.isEmpty) {
        setState(() {
          _errorText = 'El código QR no corresponde a un emparejamiento de Aula-Scrapt.';
        });
        return;
      }

      _hostController.text = host;
      _pinController.text = pin;
      await _claimPairing(host, pin);
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      if (msg.contains('CANCELLED')) return;
      setState(() {
        _errorText = 'No se pudo usar el escáner QR ($msg). Ingresa la IP y el PIN manualmente.';
      });
    }
  }

  Future<void> _submitManual() async {
    final host = _normalizeHost(_hostController.text);
    final pin = _pinController.text.replaceAll(RegExp(r'\s+'), '').trim();
    if (host.isEmpty) {
      setState(() => _errorText = 'Ingresa la IP o URL del PC (ej. 192.168.1.25:8000).');
      return;
    }
    if (pin.length < 4) {
      setState(() => _errorText = 'Ingresa el PIN de 6 dígitos mostrado en tu computador.');
      return;
    }
    await _claimPairing(host, pin);
  }

  Future<void> _claimPairing(String rawHost, String pin) async {
    final baseUrl = _normalizeHost(rawHost);
    if (baseUrl.isEmpty) {
      setState(() => _errorText = 'Dirección del PC inválida.');
      return;
    }

    setState(() {
      _isWorking = true;
      _errorText = null;
      _statusText = 'Conectando con $baseUrl...';
    });

    try {
      final claimUri = Uri.parse(
        '$baseUrl/api/pair/claim?pin=${Uri.encodeQueryComponent(pin)}',
      );
      final resp = await http.get(claimUri).timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) {
        String detail = 'Código inválido o expirado (HTTP ${resp.statusCode}).';
        try {
          final errJson = json.decode(resp.body);
          if (errJson is Map && errJson['detail'] != null) {
            detail = errJson['detail'].toString();
          }
        } catch (_) {}
        if (!mounted) return;
        setState(() {
          _isWorking = false;
          _statusText = null;
          _errorText = detail;
        });
        return;
      }

      final payload = json.decode(resp.body);
      if (payload is! Map<String, dynamic> || payload['ok'] != true) {
        if (!mounted) return;
        setState(() {
          _isWorking = false;
          _statusText = null;
          _errorText = 'Respuesta inesperada del servidor PC.';
        });
        return;
      }

      if (!mounted) return;
      setState(() => _statusText = 'Validando sesión de Aula y aplicando carpetas...');

      final authRes = await widget.moodleService.loginFromPairingClaim(payload);
      if (!mounted) return;

      if (authRes['success'] == true) {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _isWorking = false;
          _statusText = null;
          _errorText = authRes['message']?.toString() ??
              'No se pudo validar la sesión recibida del PC.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isWorking = false;
        _statusText = null;
        _errorText =
            'No se pudo conectar al PC en $baseUrl. Verifica que ambos estén en la misma red Wi-Fi. ($e)';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final inset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + inset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.devices_rounded,
                    color: cs.onPrimaryContainer,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sincronizar desde PC',
                        style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        'Importa tu sesión, carpetas de ramos y reglas en un paso.',
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                'En Aula-Scrapt PC abre Configuración > Sincronizar con Móvil para generar el QR o PIN de 6 dígitos (misma red Wi-Fi).',
                style: tt.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              onPressed: _isWorking ? null : _scanWithCamera,
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Escanear código QR del PC'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Divider(color: cs.outlineVariant)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    'o ingresa IP y PIN',
                    style: tt.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                Expanded(child: Divider(color: cs.outlineVariant)),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _hostController,
              enabled: !_isWorking,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'IP o URL del PC',
                hintText: '192.168.1.25:8000',
                prefixIcon: Icon(Icons.lan_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pinController,
              enabled: !_isWorking,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: 'PIN de 6 dígitos',
                hintText: '123456',
                prefixIcon: Icon(Icons.pin_rounded),
                counterText: '',
              ),
            ),
            if (_statusText != null) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _statusText!,
                      style: tt.bodySmall?.copyWith(color: cs.primary),
                    ),
                  ),
                ],
              ),
            ],
            if (_errorText != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.errorContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline_rounded, color: cs.onErrorContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _errorText!,
                        style: tt.bodySmall?.copyWith(color: cs.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _isWorking ? null : _submitManual,
              icon: const Icon(Icons.link_rounded),
              label: Text(_isWorking ? 'Vinculando...' : 'Vincular con PIN'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
