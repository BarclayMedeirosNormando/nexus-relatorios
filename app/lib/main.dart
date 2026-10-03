import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/apps_script_client.dart';
import 'services/school_service.dart';
import 'services/technician_service.dart';
import 'services/employee_service.dart';

final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('pt_BR', null);
  await SchoolService().loadSchools();
  await TechnicianService().loadTechnicians();
  EmployeeService().initialize(); // busca do Sheets em background, fallback no estático

  final prefs = await SharedPreferences.getInstance();
  final isDark = prefs.getBool('is_dark_mode') ?? false;
  themeNotifier.value = isDark ? ThemeMode.dark : ThemeMode.light;

  // PWA: mantém o usuário conectado entre as aberturas do app (também offline).
  final keepSession =
      kIsWeb && (prefs.getString('logged_user') ?? '').isNotEmpty;
  final savedToken = prefs.getString('session_token');
  if (keepSession && savedToken != null && savedToken.isNotEmpty) {
    AppsScriptClient.sessionToken = savedToken;
  }

  var authExpiredHandled = false;
  AppsScriptClient.onAuthExpired = () async {
    if (authExpiredHandled) return;
    authExpiredHandled = true;
    final p = await SharedPreferences.getInstance();
    await p.remove('logged_user');
    await p.remove('logged_user_permission');
    await p.remove('logged_user_id');
    await p.remove('session_token');
    AppsScriptClient.sessionToken = null;
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
    authExpiredHandled = false;
  };

  runApp(AppSecretaria(startLoggedIn: keepSession));
}

class AppSecretaria extends StatelessWidget {
  final bool startLoggedIn;
  const AppSecretaria({super.key, this.startLoggedIn = false});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, ThemeMode currentMode, _) {
        return MaterialApp(
          title: 'NEXUS RELATÓRIOS',
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          themeMode: currentMode,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFC62828), // Um tom de vermelho remetendo à bandeira
              brightness: Brightness.light,
            ),
            appBarTheme: const AppBarTheme(
              centerTitle: true,
              backgroundColor: Color(0xFFC62828),
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFC62828),
                foregroundColor: Colors.white,
              ),
            ),
            floatingActionButtonTheme: const FloatingActionButtonThemeData(
              backgroundColor: Color(0xFFC62828),
              foregroundColor: Colors.white,
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFC62828),
              brightness: Brightness.dark,
            ),
            appBarTheme: const AppBarTheme(
              centerTitle: true,
              backgroundColor: Color(0xFFC62828),
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            elevatedButtonTheme: ElevatedButtonThemeData(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFC62828),
                foregroundColor: Colors.white,
              ),
            ),
            floatingActionButtonTheme: const FloatingActionButtonThemeData(
              backgroundColor: Color(0xFFC62828),
              foregroundColor: Colors.white,
            ),
          ),
          home: startLoggedIn ? const HomeScreen() : const LoginScreen(),
        );
      },
    );
  }
}
