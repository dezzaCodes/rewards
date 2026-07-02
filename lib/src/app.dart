import 'package:flutter/material.dart';

import 'bootstrap.dart';
import 'features/dashboard/dashboard_screen.dart';

class App extends StatelessWidget {
  const App({super.key, required this.bootstrap});

  final AppBootstrap bootstrap;

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(0xFF0D6B57);
    const backgroundColor = Color(0xFFF5F1E7);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'App Blueprint',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: backgroundColor,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.light,
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          margin: EdgeInsets.zero,
        ),
      ),
      home: DashboardScreen(bootstrap: bootstrap),
    );
  }
}
