import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/auth_screen.dart';
import 'screens/dashboard.dart';
import 'services/auth_service.dart';
import 'services/monitor_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final authService = AuthService();
  await authService.init();   // loads stored token + checks /api/auth/status

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: authService),
        // MonitorService is created lazily once the user is authenticated
        ChangeNotifierProxyProvider<AuthService, MonitorService>(
          create: (_) => MonitorService(),
          update: (_, auth, monitor) {
            if (auth.isLoggedIn && monitor != null) {
              // Sync connection config whenever auth state changes
              monitor.configure(
                host: auth.host,
                port: auth.port,
                token: auth.token,
              );
            }
            return monitor ?? MonitorService();
          },
        ),
      ],
      child: const OllamaMonitorApp(),
    ),
  );
}

class OllamaMonitorApp extends StatelessWidget {
  const OllamaMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ollama Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.dark(
          primary: Colors.deepPurpleAccent,
          surface: const Color(0xFF161B22),
        ),
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        cardTheme: const CardThemeData(
          color: Color(0xFF161B22),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            side: BorderSide(color: Colors.white10),
          ),
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white),
          bodySmall: TextStyle(color: Colors.white70),
          labelLarge:
              TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white10,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Colors.white24),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Colors.white24),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide:
                const BorderSide(color: Colors.deepPurpleAccent, width: 1.5),
          ),
          labelStyle: const TextStyle(color: Colors.white54),
          hintStyle: const TextStyle(color: Colors.white30),
        ),
        dividerColor: Colors.white12,
        useMaterial3: true,
      ),
      home: const _AuthGate(),
    );
  }
}

/// Switches between the auth screen and the dashboard based on [AuthService] state.
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: switch (auth.state) {
        AuthState.loading => const _LoadingScreen(),
        AuthState.loggedIn => const DashboardScreen(),
        _ => const AuthScreen(),   // noPassword or loggedOut
      },
    );
  }
}

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0D1117),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Colors.deepPurpleAccent),
            SizedBox(height: 16),
            Text('Connecting…',
                style: TextStyle(color: Colors.white54, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}
