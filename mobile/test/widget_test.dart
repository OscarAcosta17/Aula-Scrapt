import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aula_scrapt/main.dart';
import 'package:aula_scrapt/models/course.dart';
import 'package:aula_scrapt/services/moodle_service.dart';
import 'package:aula_scrapt/screens/update_sheet.dart';
import 'package:aula_scrapt/services/settings_service.dart';
import 'package:aula_scrapt/services/updater_service.dart';

class _TestSettingsService extends SettingsService {
  Map<String, dynamic>? _memoryCache;

  @override
  Future<bool> hasStoragePermission() async => true;

  @override
  Future<List<String>> listExistingSubfolders() async => [
        'Ingeniería de Software',
        'Inteligencia Artificial',
      ];

  @override
  Future<Map<String, dynamic>?> loadScanCache() async => _memoryCache;

  @override
  Future<void> saveScanCache(List<MoodleCourse> courses) async {
    _memoryCache = {
      'cachedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'courses': courses,
    };
  }

  @override
  Future<bool> scheduleBackgroundSync(int intervalHours) async => true;

  @override
  Future<bool> hasNotificationPermission() async => true;

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<bool> showNativeNotification({
    required String title,
    required String body,
    String channelId = 'new_resources',
  }) async =>
      true;

  @override
  Future<void> refreshSystemSeedColor() async {}

  @override
  Future<Map<String, dynamic>> loadSharedIndex() async => {};

  @override
  Future<void> recordSharedIndexEntries(List<Map<String, dynamic>> entries) async {}
}

class _FakeMoodleService extends MoodleService {
  _FakeMoodleService(super.settingsService);

  @override
  bool get isAuthenticated => true;

  @override
  String? get userName => 'Estudiante USM';

  @override
  Future<Map<String, dynamic>> verifySessionLive() async => {
        'authenticated': true,
        'user_name': 'Estudiante USM',
      };

  @override
  Future<List<MoodleCourse>> getCourses() async => [
        MoodleCourse(
          id: 101,
          fullname: '(202602)(INF236) INGENIERÍA DE SOFTWARE|Paralelos:200',
          cleanName: 'Ingeniería de Software',
          shortname: 'INF236',
          url: 'https://aula.usm.cl/course/view.php?id=101',
          obsidianFolder: 'Ingeniería de Software',
        ),
        MoodleCourse(
          id: 102,
          fullname: '(202602)(INF295) INTELIGENCIA ARTIFICIAL|Paralelos:200',
          cleanName: 'Inteligencia Artificial',
          shortname: 'INF295',
          url: 'https://aula.usm.cl/course/view.php?id=102',
          obsidianFolder: 'Inteligencia Artificial',
        ),
      ];

  @override
  Future<List<MoodleItem>> scanCourseContents(MoodleCourse course) async {
    if (course.id == 101) {
      return [
        MoodleItem(
          id: '101_mod_1',
          courseId: 101,
          title: 'Clase 01 - Arquitectura de Software y Diseño Limpio en Sistemas',
          section: 'Semana 1',
          type: 'file',
          url: 'https://aula.usm.cl/mod/resource/view.php?id=1',
          fileName: 'Clase_01.pdf',
          downloadable: true,
          sizeBytes: 1540000,
          isDownloaded: false,
          isNew: true,
        ),
        MoodleItem(
          id: '101_mod_2',
          courseId: 101,
          title: 'Entrega Proyecto 1',
          section: 'Semana 1',
          type: 'assignment',
          url: 'https://aula.usm.cl/mod/assign/view.php?id=2',
          fileName: 'Entrega Proyecto 1',
          downloadable: false,
        ),
      ];
    }
    return [];
  }

  @override
  Future<void> enrichItemsWithLocalStatus(
    List<MoodleItem> items,
    String courseFolder,
  ) async {}

  @override
  Future<bool> fetchMissingFileSizes(List<MoodleItem> items) async => false;
}

void main() {
  test('Clean course name smoke test', () {
    const raw = '(202602)(INF266) SISTEMAS DE GESTIÓN|Paralelos:200/201';
    final clean = MoodleCourse.cleanCourseName(raw);
    expect(clean, 'Sistemas de Gestión');
  });

  testWidgets('LoginScreen renders Material 3 adaptive phone and wide layouts',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'settings_download_root': '/tmp/aula_scrapt_test',
    });
    final settings = _TestSettingsService();
    await tester.runAsync(() => settings.init());
    final moodle = MoodleService(settings);

    // Teléfono (vertical)
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(AulaScraptApp(
      moodleService: moodle,
      settingsService: settings,
    ));
    await tester.pumpAndSettle();

    expect(find.text('Aula-Scrapt USM'), findsOneWidget);
    expect(find.text('Navegador'), findsOneWidget);
    expect(find.text('Token'), findsOneWidget);
    expect(find.text('Cookie'), findsOneWidget);

    // Cambiar pestaña Token vía SegmentedButton
    await tester.tap(find.text('Token'));
    await tester.pumpAndSettle();
    expect(find.text('Conectar con Token'), findsOneWidget);

    // Tablet / ancho >= 680dp (layout 2 paneles sin overflow)
    tester.view.physicalSize = const Size(900, 700);
    await tester.pumpAndSettle();
    expect(find.text('Aula-Scrapt USM'), findsOneWidget);
    expect(find.text('Conectar con Token'), findsOneWidget);
  });

  testWidgets('CoursesScreen renders M3 Expressive phone and wide master-detail layouts',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'settings_download_root': '/storage/emulated/0/Documents/Obsidian',
    });
    final settings = _TestSettingsService();
    await tester.runAsync(() => settings.init());
    final moodle = _FakeMoodleService(settings);

    // Teléfono angosto (360x780)
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(AulaScraptApp(
      moodleService: moodle,
      settingsService: settings,
    ));
    await tester.pumpAndSettle();

    expect(find.text('Aula-Scrapt'), findsOneWidget);
    expect(find.text('Ingeniería de Software'), findsAtLeastNWidgets(1));
    expect(find.text('Inteligencia Artificial'), findsAtLeastNWidgets(1));

    // Expandir ramo y sección, luego marcar pendientes
    await tester.tap(find.text('Ingeniería de Software').first);
    await tester.pumpAndSettle();
    expect(find.text('Semana 1'), findsOneWidget);

    await tester.tap(find.text('Semana 1'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Marcar pendientes'));
    await tester.pumpAndSettle();
    expect(find.text('1 seleccionado(s)'), findsOneWidget);
    expect(find.text('Descargar'), findsOneWidget);

    // Vista adaptativa Tablet / Desktop Android (900x700)
    tester.view.physicalSize = const Size(900, 700);
    await tester.pumpAndSettle();
    expect(find.text('Ingeniería de Software'), findsAtLeastNWidgets(1));
    expect(find.text('Semana 1'), findsOneWidget);
  });

  test('UpdaterService version parsing and ABI asset selection', () {
    expect(UpdaterService.parseSemver('v1.2.0+3'), (major: 1, minor: 2, patch: 0));
    expect(UpdaterService.isNewerVersion('v1.2.1', '1.2.0'), isTrue);
    expect(UpdaterService.isNewerVersion('v1.3.0', '1.2.9'), isTrue);
    expect(UpdaterService.isNewerVersion('v1.2.0', '1.2.0'), isFalse);
    expect(UpdaterService.isNewerVersion('v1.1.5', '1.2.0'), isFalse);

    final assets = [
      {
        'name': 'Aula-Scrapt-Windows.exe',
        'browser_download_url': 'https://example.com/win.exe',
        'size': 85 * 1024 * 1024,
      },
      {
        'name': 'Aula-Scrapt-Android.apk',
        'browser_download_url': 'https://example.com/app64.apk',
        'size': 25 * 1024 * 1024,
      },
      {
        'name': 'Aula-Scrapt-Android-v7a.apk',
        'browser_download_url': 'https://example.com/app32.apk',
        'size': 22 * 1024 * 1024,
      },
    ];

    final arm64Asset = UpdaterService.selectAndroidAsset(assets, ['arm64-v8a', 'armeabi-v7a']);
    expect(arm64Asset?.name, 'Aula-Scrapt-Android.apk');
    expect(arm64Asset?.archTag, 'arm64-v8a');

    final armv7Asset = UpdaterService.selectAndroidAsset(assets, ['armeabi-v7a']);
    expect(armv7Asset?.name, 'Aula-Scrapt-Android-v7a.apk');
    expect(armv7Asset?.archTag, 'armeabi-v7a');
  });

  testWidgets('Update sheet renders available release without overflow', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final result = AppUpdateCheckResult(
      ok: true,
      updateAvailable: true,
      currentVersion: '1.2.0',
      latestVersion: '1.3.0',
      tagName: 'v1.3.0',
      releaseName: 'Aula-Scrapt v1.3.0',
      publishedAt: '2026-11-13T12:00:00Z',
      changelog: '- Auto-actualización in-app\n- Soporte Material 3 Expressive',
      htmlUrl: 'https://github.com/OscarAcosta17/Aula-Scrapt/releases/tag/v1.3.0',
      asset: const GitHubReleaseAsset(
        name: 'Aula-Scrapt-Android.apk',
        downloadUrl: 'https://example.com/Aula-Scrapt-Android.apk',
        size: 24 * 1024 * 1024,
        archTag: 'arm64-v8a',
      ),
      env: const AppUpdateEnv(
        currentVersion: '1.2.0',
        versionCode: 3,
        packageName: 'cl.usm.aulascrapt.aula_scrapt',
        abis: ['arm64-v8a'],
        sdkInt: 35,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showAppUpdateSheet(
                  context,
                  updaterService: UpdaterService(),
                  initialResult: result,
                ),
                child: const Text('Abrir actualizaciones'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Abrir actualizaciones'));
    await tester.pumpAndSettle();

    expect(find.text('Actualizaciones de la app'), findsOneWidget);
    expect(find.text('v1.3.0'), findsOneWidget);
    expect(find.text('Descargar e instalar v1.3.0'), findsOneWidget);
    expect(find.text('Ver releases en GitHub'), findsOneWidget);
  });

  test('v1.3.0 helpers: normalizeMatchKey, parseDueTimestamp, inferFileExt & checksums', () {
    expect(
      MoodleService.normalizeMatchKey('Guía Nº 1 - Introducción_2026.PDF'),
      'guia n 1 introduccion 2026',
    );
    expect(MoodleService.inferFileExt('Clase_01.pptx', 'Clase 01'), 'pptx');
    expect(MoodleService.parseDueTimestamp('18 de noviembre de 2026, 23:59'), isNotNull);
    expect(MoodleService.parseDueTimestamp('25/11/2026 18:30'), isNotNull);

    final item = MoodleItem(
      id: 'assign_42',
      courseId: 101,
      title: 'Entrega Final',
      section: 'Evaluaciones',
      type: 'assignment',
      url: 'https://aula.usm.cl/mod/assign/view.php?id=42',
      fileName: 'Entrega Final',
      downloadable: false,
      dueTimestamp: 1795046340,
      dueText: '18/11/2026 23:59',
    );
    final course = MoodleCourse(
      id: 101,
      fullname: 'INF236',
      cleanName: 'Ingeniería de Software',
      shortname: 'INF236',
      url: 'https://aula.usm.cl/course/view.php?id=101',
      obsidianFolder: 'Ingeniería de Software',
      items: [item],
    );
    final decoded = MoodleCourse.fromJson(course.toJson());
    expect(decoded.id, 101);
    expect(decoded.items.length, 1);
    expect(decoded.items.first.dueTimestamp, 1795046340);

    const sampleChecksums =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  Aula-Scrapt-Android.apk\n'
        'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210 *Aula-Scrapt-Android-v7a.apk\n';
    final parsedMap = UpdaterService.parseChecksumsText(sampleChecksums);
    expect(
      parsedMap['Aula-Scrapt-Android.apk'],
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    );

    final picked = UpdaterService.selectAndroidAsset(
      [
        {
          'name': 'Aula-Scrapt-Android.apk',
          'browser_download_url': 'https://example.com/arm64.apk',
          'size': 20 * 1024 * 1024,
        },
        {
          'name': 'Aula-Scrapt-Android-v7a.apk',
          'browser_download_url': 'https://example.com/v7a.apk',
          'size': 18 * 1024 * 1024,
        },
      ],
      ['armeabi-v7a'],
      checksums: parsedMap,
    );
    expect(picked?.name, 'Aula-Scrapt-Android-v7a.apk');
    expect(
      picked?.sha256,
      'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
    );
  });

  testWidgets('CoursesScreen v1.3.0 deadlines tab, notifications bell & settings sheet work cleanly',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'settings_download_root': '/storage/emulated/0/Documents/Obsidian',
    });
    final settings = _TestSettingsService();
    await tester.runAsync(() => settings.init());
    await tester.runAsync(() => settings.addNotification(
          title: 'Archivo de prueba',
          body: 'Guia_01.pdf disponible',
          kind: 'new_file',
        ));
    final moodle = _FakeMoodleService(settings);

    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(AulaScraptApp(
      moodleService: moodle,
      settingsService: settings,
    ));
    await tester.pumpAndSettle();

    // Cambiar a pestaña Entregas (asegurar visibilidad en viewport horizontal 360dp)
    await tester.ensureVisible(find.text('Entregas'));
    await tester.tap(find.text('Entregas'));
    await tester.pumpAndSettle();
    expect(find.text('Entrega Proyecto 1'), findsAtLeastNWidgets(1));

    // Volver arriba para revelar el SliverAppBar y abrir el centro de notificaciones
    await tester.drag(find.byType(CustomScrollView).first, const Offset(0, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.notifications_outlined).first);
    await tester.pumpAndSettle();
    expect(find.text('Centro de avisos'), findsOneWidget);
    expect(find.text('Archivo de prueba'), findsOneWidget);
  });
}
