import 'package:flutter/material.dart';

import 'ios_core.dart';
import 'student_lesson_page.dart';
import 'tutor_tab.dart';

/// Root scaffold for the student app. Two bottom-nav tabs:
///   * Active class - the live lesson surface (was the whole app before)
///   * Tutor        - subject-grouped practice driven by completed lessons
///
/// Wraps both screens in an IndexedStack so the lesson page keeps its scroll /
/// input state when the student dips into the Tutor tab mid-session.
class StudentShell extends StatefulWidget {
  final IosCore core;
  const StudentShell({super.key, required this.core});

  @override
  State<StudentShell> createState() => _StudentShellState();
}

class _StudentShellState extends State<StudentShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          StudentLessonPage(core: widget.core),
          TutorTab(core: widget.core),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.school_outlined),
            selectedIcon: Icon(Icons.school_rounded),
            label: 'Active class',
          ),
          NavigationDestination(
            icon: Icon(Icons.psychology_alt_outlined),
            selectedIcon: Icon(Icons.psychology_alt),
            label: 'Tutor',
          ),
        ],
      ),
    );
  }
}
