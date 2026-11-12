import 'package:flutter/material.dart';
import 'screens/courses_screen.dart';
import 'screens/login_screen.dart';
import 'services/moodle_service.dart';
import 'services/settings_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aula-Scrapt USM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F0F12),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFF22C55E),
          surface: Color(0xFF17171C),
          error: Color(0xFFEF4444),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF17171C),
          elevation: 0,
        ),
        useMaterial3: true,
      ),
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
  }
}
