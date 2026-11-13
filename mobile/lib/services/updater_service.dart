import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppUpdateEnv {
  final String currentVersion;
  final int versionCode;
  final String packageName;
  final List<String> abis;
  final int sdkInt;

  const AppUpdateEnv({
    required this.currentVersion,
    required this.versionCode,
    required this.packageName,
    required this.abis,
    required this.sdkInt,
  });

  String get abiLabel {
    if (abis.any((a) => a.contains('arm64'))) return 'ARM 64-bit (arm64-v8a)';
    if (abis.any((a) => a.contains('armeabi-v7a'))) return 'ARM 32-bit (armeabi-v7a)';
    if (abis.isNotEmpty) return abis.first;
    return 'Android';
  }
}

class GitHubReleaseAsset {
  final String name;
  final String downloadUrl;
  final int size;
  final String archTag;

  const GitHubReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    required this.archTag,
  });

  String get sizeLabel {
    if (size <= 0) return '';
    if (size < 1024 * 1024) {
      return '${(size / 1024).toStringAsFixed(1)} KB';
    }
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class AppUpdateCheckResult {
  final bool ok;
  final bool noReleases;
  final bool updateAvailable;
  final String currentVersion;
  final String latestVersion;
  final String tagName;
  final String releaseName;
  final String publishedAt;
  final String changelog;
  final String htmlUrl;
  final GitHubReleaseAsset? asset;
  final AppUpdateEnv env;
  final String? error;

  const AppUpdateCheckResult({
    required this.ok,
    this.noReleases = false,
    required this.updateAvailable,
    required this.currentVersion,
    required this.latestVersion,
    required this.tagName,
    required this.releaseName,
    required this.publishedAt,
    required this.changelog,
    required this.htmlUrl,
    required this.asset,
    required this.env,
    this.error,
  });
}

class UpdaterService {
  static const String githubRepo = 'OscarAcosta17/Aula-Scrapt';
  static const String latestApiUrl =
      'https://api.github.com/repos/$githubRepo/releases/latest';
  static const String releasesUrl =
      'https://github.com/$githubRepo/releases';
  static const MethodChannel _channel =
      MethodChannel('cl.usm.aulascrapt/storage');

  final http.Client _httpClient;

  UpdaterService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  static ({int major, int minor, int patch}) parseSemver(String raw) {
    var clean = raw.trim();
    if (clean.startsWith('v') || clean.startsWith('V')) {
      clean = clean.substring(1);
    }
    clean = clean.split('+').first.split('-').first;
    final matches =
        RegExp(r'\d+').allMatches(clean).map((m) => int.parse(m.group(0)!)).toList();
    final major = matches.isNotEmpty ? matches[0] : 0;
    final minor = matches.length > 1 ? matches[1] : 0;
    final patch = matches.length > 2 ? matches[2] : 0;
    return (major: major, minor: minor, patch: patch);
  }

  static bool isNewerVersion(String remoteTag, String currentVersion) {
    final r = parseSemver(remoteTag);
    final c = parseSemver(currentVersion);
    if (r.major != c.major) return r.major > c.major;
    if (r.minor != c.minor) return r.minor > c.minor;
    return r.patch > c.patch;
  }

  static GitHubReleaseAsset? selectAndroidAsset(
    List<dynamic> rawAssets,
    List<String> deviceAbis,
  ) {
    final apks = <GitHubReleaseAsset>[];
    for (final entry in rawAssets) {
      if (entry is! Map) continue;
      final name = (entry['name'] ?? '').toString().trim();
      final url = (entry['browser_download_url'] ?? '').toString().trim();
      final size = (entry['size'] is num) ? (entry['size'] as num).toInt() : 0;
      final lower = name.toLowerCase();
      if (name.isEmpty || url.isEmpty || !lower.endsWith('.apk')) continue;

      final String archTag;
      if (lower.contains('v7a') || lower.contains('armeabi') || lower.contains('32')) {
        archTag = 'armeabi-v7a';
      } else if (lower.contains('universal') || lower.contains('fat')) {
        archTag = 'universal';
      } else if (lower.contains('x86_64')) {
        archTag = 'x86_64';
      } else if (lower.contains('arm64') ||
          lower.contains('v8a') ||
          lower.contains('android.apk')) {
        archTag = 'arm64-v8a';
      } else {
        archTag = 'universal';
      }

      apks.add(
        GitHubReleaseAsset(
          name: name,
          downloadUrl: url,
          size: size,
          archTag: archTag,
        ),
      );
    }

    if (apks.isEmpty) return null;

    // Respetar el orden de preferencia de ABI reportado por Android
    for (final abi in deviceAbis) {
      final norm = abi.toLowerCase();
      if (norm.contains('arm64') || norm.contains('v8')) {
        for (final apk in apks) {
          if (apk.archTag == 'arm64-v8a') return apk;
        }
      } else if (norm.contains('armeabi-v7a') || norm.contains('armeabi')) {
        for (final apk in apks) {
          if (apk.archTag == 'armeabi-v7a') return apk;
        }
      } else if (norm.contains('x86_64')) {
        for (final apk in apks) {
          if (apk.archTag == 'x86_64') return apk;
        }
      }
    }

    for (final apk in apks) {
      if (apk.archTag == 'universal') return apk;
    }
    return apks.first;
  }

  Future<AppUpdateEnv> loadEnvironment() async {
    if (!Platform.isAndroid) {
      return const AppUpdateEnv(
        currentVersion: '1.2.0',
        versionCode: 3,
        packageName: 'cl.usm.aulascrapt.aula_scrapt',
        abis: ['arm64-v8a'],
        sdkInt: 35,
      );
    }
    try {
      final info = await _channel.invokeMethod<Map<dynamic, dynamic>>('getAppInfo');
      if (info != null) {
        final rawAbis = info['abis'];
        final abis = rawAbis is List
            ? rawAbis.map((e) => e.toString()).toList()
            : const <String>['arm64-v8a'];
        return AppUpdateEnv(
          currentVersion: (info['versionName'] ?? '1.2.0').toString(),
          versionCode: (info['versionCode'] is num)
              ? (info['versionCode'] as num).toInt()
              : 3,
          packageName: (info['packageName'] ?? 'cl.usm.aulascrapt.aula_scrapt')
              .toString(),
          abis: abis,
          sdkInt: (info['sdkInt'] is num) ? (info['sdkInt'] as num).toInt() : 35,
        );
      }
    } catch (_) {
      // Fallback limpio si corre fuera de contexto Android
    }
    return const AppUpdateEnv(
      currentVersion: '1.2.0',
      versionCode: 3,
      packageName: 'cl.usm.aulascrapt.aula_scrapt',
      abis: ['arm64-v8a'],
      sdkInt: 35,
    );
  }

  Future<bool> canRequestPackageInstalls() async {
    if (!Platform.isAndroid) return true;
    try {
      final allowed =
          await _channel.invokeMethod<bool>('canRequestPackageInstalls');
      return allowed ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      final opened =
          await _channel.invokeMethod<bool>('openInstallPermissionSettings');
      return opened ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> installApk(String apkPath) async {
    if (!Platform.isAndroid) {
      throw PlatformException(
        code: 'UNSUPPORTED',
        message: 'La instalación de APK solo aplica en Android.',
      );
    }
    await _channel.invokeMethod('installApk', {'path': apkPath});
  }

  Future<AppUpdateCheckResult> checkForUpdates() async {
    final env = await loadEnvironment();
    http.Response response;
    try {
      response = await _httpClient
          .get(
            Uri.parse(latestApiUrl),
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'Aula-Scrapt-Android/${env.currentVersion}',
            },
          )
          .timeout(const Duration(seconds: 12));
    } catch (e) {
      return AppUpdateCheckResult(
        ok: false,
        updateAvailable: false,
        currentVersion: env.currentVersion,
        latestVersion: env.currentVersion,
        tagName: 'v${env.currentVersion}',
        releaseName: '',
        publishedAt: '',
        changelog: '',
        htmlUrl: releasesUrl,
        asset: null,
        env: env,
        error: 'No se pudo conectar con GitHub: $e',
      );
    }

    if (response.statusCode == 404) {
      return AppUpdateCheckResult(
        ok: true,
        noReleases: true,
        updateAvailable: false,
        currentVersion: env.currentVersion,
        latestVersion: env.currentVersion,
        tagName: 'v${env.currentVersion}',
        releaseName: '',
        publishedAt: '',
        changelog: '',
        htmlUrl: releasesUrl,
        asset: null,
        env: env,
      );
    }

    if (response.statusCode == 403 || response.statusCode == 429) {
      return AppUpdateCheckResult(
        ok: false,
        updateAvailable: false,
        currentVersion: env.currentVersion,
        latestVersion: env.currentVersion,
        tagName: 'v${env.currentVersion}',
        releaseName: '',
        publishedAt: '',
        changelog: '',
        htmlUrl: releasesUrl,
        asset: null,
        env: env,
        error: 'GitHub limitó temporalmente las consultas. Intenta en unos minutos.',
      );
    }

    if (response.statusCode != 200) {
      return AppUpdateCheckResult(
        ok: false,
        updateAvailable: false,
        currentVersion: env.currentVersion,
        latestVersion: env.currentVersion,
        tagName: 'v${env.currentVersion}',
        releaseName: '',
        publishedAt: '',
        changelog: '',
        htmlUrl: releasesUrl,
        asset: null,
        env: env,
        error: 'Respuesta inesperada de GitHub (HTTP ${response.statusCode}).',
      );
    }

    final data = json.decode(response.body) as Map<String, dynamic>;
    final tag = (data['tag_name'] ?? '').toString().trim();
    final latestClean =
        tag.replaceFirst(RegExp(r'^[vV]'), '').trim().isNotEmpty
            ? tag.replaceFirst(RegExp(r'^[vV]'), '').trim()
            : env.currentVersion;
    final hasUpdate =
        tag.isNotEmpty && isNewerVersion(latestClean, env.currentVersion);
    final rawAssets = (data['assets'] as List?) ?? const [];
    final matchedAsset = selectAndroidAsset(rawAssets, env.abis);

    return AppUpdateCheckResult(
      ok: true,
      noReleases: false,
      updateAvailable: hasUpdate,
      currentVersion: env.currentVersion,
      latestVersion: latestClean,
      tagName: tag.isNotEmpty ? tag : 'v$latestClean',
      releaseName: (data['name'] ?? 'v$latestClean').toString(),
      publishedAt: (data['published_at'] ?? '').toString(),
      changelog: (data['body'] ?? '').toString().trim(),
      htmlUrl: (data['html_url'] ?? releasesUrl).toString(),
      asset: matchedAsset,
      env: env,
    );
  }

  Future<File> downloadApk(
    GitHubReleaseAsset asset, {
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    if (!asset.downloadUrl.startsWith('https://')) {
      throw Exception('La URL de descarga del APK debe usar HTTPS.');
    }

    final tempRoot = await getTemporaryDirectory();
    final updatesDir = Directory(p.join(tempRoot.path, 'updates'));
    if (await updatesDir.exists()) {
      // Limpiar descargas previas para ahorrar caché del teléfono
      await for (final entity in updatesDir.list()) {
        if (entity is File && entity.path.toLowerCase().endsWith('.apk')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } else {
      await updatesDir.create(recursive: true);
    }

    final safeName = p.basename(asset.name).isNotEmpty
        ? p.basename(asset.name)
        : 'Aula-Scrapt-update.apk';
    final outFile = File(p.join(updatesDir.path, safeName));
    final request = http.Request('GET', Uri.parse(asset.downloadUrl));
    request.headers['User-Agent'] = 'Aula-Scrapt-Android-Updater';

    final streamed =
        await _httpClient.send(request).timeout(const Duration(seconds: 30));
    if (streamed.statusCode != 200) {
      throw Exception('No se pudo descargar el APK (HTTP ${streamed.statusCode}).');
    }

    final total = math.max(streamed.contentLength ?? 0, asset.size);
    int received = 0;
    final sink = outFile.openWrite();
    try {
      await for (final chunk in streamed.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    final length = await outFile.length();
    if (length < 100 * 1024) {
      await outFile.delete().catchError((_) => outFile);
      throw Exception('El archivo APK descargado está incompleto.');
    }

    // Validar cabecera ZIP/APK ('PK')
    final raf = await outFile.open();
    try {
      final header = await raf.read(2);
      if (header.length < 2 || header[0] != 0x50 || header[1] != 0x4B) {
        await outFile.delete().catchError((_) => outFile);
        throw Exception('El archivo descargado no tiene formato APK válido.');
      }
    } finally {
      await raf.close();
    }

    return outFile;
  }
}
