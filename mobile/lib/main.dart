import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/courses_screen.dart';
import 'screens/login_screen.dart';
import 'services/moodle_service.dart';
import 'services/settings_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  final settingsService = SettingsService();
  await settingsService.init();

  final moodleService = MoodleService(settingsService);
  await moodleService.loadSession();

  runApp(AulaScraptApp(
    moodleService: moodleService,
    settingsService: settingsService,
  ));
}

class AulaScraptApp extends StatelessWidget {
  final MoodleService moodleService;
  final SettingsService settingsService;

  const AulaScraptApp({
    super.key,
    required this.moodleService,
    required this.settingsService,
  });

  static const Color _brandSeed = Color(0xFF38BDF8);

  ThemeData _buildExpressiveTheme(Brightness brightness) {
    final useDynamic =
        settingsService.useDynamicColor && settingsService.systemSeedColor != null;
    final seed = useDynamic ? settingsService.systemSeedColor! : _brandSeed;

    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant:
          useDynamic ? DynamicSchemeVariant.tonalSpot : DynamicSchemeVariant.vibrant,
    );

    final isDark = brightness == Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: ZoomPageTransitionsBuilder(),
          TargetPlatform.linux: ZoomPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        elevation: 0,
        scrolledUnderElevation: 2,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(56, 44),
          shape: const StadiumBorder(),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: isDark ? 0.55 : 0.7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 1.8),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          minimumSize: const Size(48, 44),
          shape: const StadiumBorder(),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        linearMinHeight: 6,
        trackGap: 4,
        stopIndicatorRadius: 2,
        strokeCap: StrokeCap.round,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settingsService.themeNotifier,
      builder: (context, _) {
        return MaterialApp(
          title: 'Aula-Scrapt USM',
          debugShowCheckedModeBanner: false,
          themeMode: settingsService.themeMode,
          theme: _buildExpressiveTheme(Brightness.light),
          darkTheme: _buildExpressiveTheme(Brightness.dark),
          builder: (context, child) {
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final overlay = SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
              systemNavigationBarDividerColor: Colors.transparent,
              systemNavigationBarContrastEnforced: false,
              systemStatusBarContrastEnforced: false,
              statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
              statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
              systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
            );
            return AnnotatedRegion<SystemUiOverlayStyle>(
              value: overlay,
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: moodleService.isAuthenticated
              ? CoursesScreen(
                  moodleService: moodleService,
                  settingsService: settingsService,
                )
              : LoginScreen(
                  moodleService: moodleService,
                  settingsService: settingsService,
                ),
        );
      },
    );
  }
}
