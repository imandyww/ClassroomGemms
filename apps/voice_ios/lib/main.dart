import 'package:flutter/material.dart';

import 'ios_core.dart';
import 'student_shell.dart';

void main() {
  runApp(const StudentApp());
}

class StudentApp extends StatefulWidget {
  const StudentApp({super.key});

  @override
  State<StudentApp> createState() => _StudentAppState();
}

class _StudentAppState extends State<StudentApp> {
  final core = IosCore();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => core.bootstrap());
  }

  @override
  void dispose() {
    core.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      colorSchemeSeed: const Color(0xFF0F766E),
      useMaterial3: true,
    );
    return MaterialApp(
      title: 'Classroom Student',
      theme: base.copyWith(
        scaffoldBackgroundColor: const Color(0xFFFBF9F4),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFBF9F4),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: base.cardTheme.copyWith(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      home: ListenableBuilder(
        listenable: core,
        builder: (_, _) => StudentShell(core: core),
      ),
    );
  }
}
