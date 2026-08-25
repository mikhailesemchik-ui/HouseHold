import 'package:flutter/material.dart';
import 'package:household_os/app/routing/app_router.dart';
import 'package:household_os/app/theme/app_theme.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Household OS',
      theme: appTheme,
      routerConfig: appRouter,
    );
  }
}
