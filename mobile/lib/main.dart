import 'package:flutter/material.dart';
import 'services/moodle_service.dart';
import 'screens/login_screen.dart';
import 'screens/courses_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final moodleService = MoodleService();
  await moodleService.loadSession();

  runApp(AulaScraptApp(moodleService: moodleService));
}

class AulaScraptApp extends StatelessWidget {
  final MoodleService moodleService;

  const AulaScraptApp({super.key, required this.moodleService});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aula-Scrapt',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFF238636),
          surface: Color(0xFF161B22),
          error: Color(0xFFF85149),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF161B22),
          elevation: 0,
        ),
        useMaterial3: true,
      ),
      home: moodleService.isAuthenticated
          ? CoursesScreen(moodleService: moodleService)
          : LoginScreen(moodleService: moodleService),
    );
  }
}
