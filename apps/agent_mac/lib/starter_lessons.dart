import 'package:agent_protocol/agent_protocol.dart';

class StarterLessonTemplate {
  final String id;
  final String title;
  final String subject;
  final String topic;
  final String gradeLevel;
  final List<StarterLessonStep> steps;

  const StarterLessonTemplate({
    required this.id,
    required this.title,
    required this.subject,
    required this.topic,
    required this.gradeLevel,
    required this.steps,
  });

  Lesson toLesson() => Lesson.create(
    title: title,
    subject: subject,
    topic: topic,
    gradeLevel: gradeLevel,
    steps: [for (var i = 0; i < steps.length; i++) steps[i].toLessonStep(i)],
  );
}

class StarterLessonStep {
  final String prompt;
  final String? teacherNotes;
  final ExpectedFormat expectedFormat;
  final List<String> options;

  const StarterLessonStep({
    required this.prompt,
    this.teacherNotes,
    this.expectedFormat = ExpectedFormat.free,
    this.options = const [],
  });

  LessonStep toLessonStep(int index) => LessonStep.create(
    index: index,
    prompt: prompt,
    teacherNotes: teacherNotes,
    expectedFormat: expectedFormat,
    options: expectedFormat == ExpectedFormat.multipleChoice
        ? options
        : const <String>[],
  );
}

const starterLessonTemplates = <StarterLessonTemplate>[
  StarterLessonTemplate(
    id: 'math-ratios-recipe',
    title: 'Ratios in a Recipe',
    subject: 'Mathematics',
    topic: 'Ratios and proportional reasoning',
    gradeLevel: '6th grade',
    steps: [
      StarterLessonStep(
        prompt:
            'A recipe uses 2 cups oats for 3 cups fruit. Which mix keeps the same ratio?',
        teacherNotes: 'Listen for equivalent-ratio reasoning.',
        expectedFormat: ExpectedFormat.multipleChoice,
        options: [
          '4 cups oats and 6 cups fruit',
          '3 cups oats and 4 cups fruit',
          '6 cups oats and 8 cups fruit',
        ],
      ),
      StarterLessonStep(
        prompt:
            'If the class has 9 cups of fruit, how many cups of oats keep the recipe proportional?',
        teacherNotes: 'Expected answer: 6 cups of oats.',
        expectedFormat: ExpectedFormat.short,
      ),
      StarterLessonStep(
        prompt:
            'Explain one strategy you used to check whether two ratios are equivalent.',
      ),
    ],
  ),
  StarterLessonTemplate(
    id: 'science-ecosystem-energy',
    title: 'Energy Flow in Ecosystems',
    subject: 'Science',
    topic: 'Food webs and energy transfer',
    gradeLevel: '6th grade',
    steps: [
      StarterLessonStep(
        prompt: 'Which organism is a producer in most food webs?',
        expectedFormat: ExpectedFormat.multipleChoice,
        options: ['Grass', 'Rabbit', 'Fox', 'Mushroom'],
      ),
      StarterLessonStep(
        prompt:
            'In one sentence, describe how energy moves from the Sun to a fox.',
        expectedFormat: ExpectedFormat.short,
      ),
      StarterLessonStep(
        prompt:
            'If the rabbit population drops sharply, what might happen to grass and fox populations? Why?',
      ),
    ],
  ),
  StarterLessonTemplate(
    id: 'ela-claim-evidence-reasoning',
    title: 'Claim, Evidence, Reasoning',
    subject: 'English Language Arts',
    topic: 'Using evidence from a text',
    gradeLevel: '7th grade',
    steps: [
      StarterLessonStep(
        prompt:
            'After reading today\'s passage, write one claim about whether the character made a careful decision.',
        expectedFormat: ExpectedFormat.short,
      ),
      StarterLessonStep(
        prompt: 'Which detail is usually the strongest evidence for a claim?',
        expectedFormat: ExpectedFormat.multipleChoice,
        options: [
          'A direct quote that supports the claim',
          'A sentence that only sounds interesting',
          'A detail from outside the text',
        ],
      ),
      StarterLessonStep(
        prompt:
            'Connect your evidence to your claim with reasoning. Start with "This shows..."',
      ),
    ],
  ),
  StarterLessonTemplate(
    id: 'social-studies-primary-source',
    title: 'Primary Source Detective',
    subject: 'Social Studies',
    topic: 'Sourcing and context',
    gradeLevel: '8th grade',
    steps: [
      StarterLessonStep(
        prompt:
            'What is the first question to ask when reading a primary source?',
        expectedFormat: ExpectedFormat.multipleChoice,
        options: [
          'Who created it and when?',
          'How long is it?',
          'Does it use big words?',
        ],
      ),
      StarterLessonStep(
        prompt:
            'Name one clue that helps identify the author\'s point of view.',
        expectedFormat: ExpectedFormat.short,
      ),
      StarterLessonStep(
        prompt:
            'What extra context would help you trust or question this source?',
      ),
    ],
  ),
  StarterLessonTemplate(
    id: 'cs-algorithms-debugging',
    title: 'Algorithms and Debugging',
    subject: 'Computer Science',
    topic: 'Precise instructions and test cases',
    gradeLevel: 'Middle school',
    steps: [
      StarterLessonStep(
        prompt: 'Which statement best describes an algorithm?',
        expectedFormat: ExpectedFormat.multipleChoice,
        options: [
          'A step-by-step process for solving a problem',
          'A random guess that might work',
          'Only the final answer to a problem',
        ],
      ),
      StarterLessonStep(
        prompt: 'What does a bug in an algorithm mean?',
        expectedFormat: ExpectedFormat.short,
      ),
      StarterLessonStep(
        prompt:
            'Write one test case you would use to check an algorithm for sorting three numbers.',
      ),
    ],
  ),
  StarterLessonTemplate(
    id: 'world-language-daily-routines',
    title: 'Daily Routines',
    subject: 'World Language',
    topic: 'Describing routines with time words',
    gradeLevel: 'Novice',
    steps: [
      StarterLessonStep(
        prompt:
            'Which sentence starter is best for telling what you do in the morning?',
        expectedFormat: ExpectedFormat.multipleChoice,
        options: [
          'In the morning, I...',
          'Yesterday, they...',
          'Next year, we...',
        ],
      ),
      StarterLessonStep(
        prompt: 'Write one sentence about a daily routine using a time word.',
        expectedFormat: ExpectedFormat.short,
      ),
      StarterLessonStep(
        prompt:
            'Ask a classmate one question about their routine, then write a possible answer.',
      ),
    ],
  ),
];

List<String> get starterLessonSubjects {
  final subjects = starterLessonTemplates
      .map((template) => template.subject)
      .toSet()
      .toList();
  subjects.sort();
  return subjects;
}
