import 'package:flutter/material.dart';

import 'ios_core.dart';
import 'student_lesson_page.dart';

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
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Classroom Student',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      home: ListenableBuilder(
        listenable: core,
        builder: (_, _) => StudentLessonPage(core: core),
      ),
    );
  }
}
