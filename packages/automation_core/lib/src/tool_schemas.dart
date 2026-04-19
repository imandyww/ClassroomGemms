import 'package:bixat_key_mouse/bixat_key_mouse.dart';

/// Tool JSON schemas, extracted verbatim (with UniversalKey.values inlined) from
/// ref/NextDesk/lib/services/openrouter_service.dart:39-195.
///
/// Kept in OpenAI tool-calling shape so it's easy to translate into
/// `List<CactusTool>` for the Cactus SDK.
List<Map<String, dynamic>> buildToolSchemas() => [
      {
        'type': 'function',
        'function': {
          'name': 'captureScreenshot',
          'description': 'Captures a screenshot of the current screen',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'detectElementPosition',
          'description':
              'Detects the pixel coordinates of a UI element in the current screenshot using AI vision',
          'parameters': {
            'type': 'object',
            'properties': {
              'elementDescription': {
                'type': 'string',
                'description':
                    'Natural language description of the UI element to locate (e.g., "Submit button", "Username text field", "Close icon")',
              },
            },
            'required': ['elementDescription'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'moveMouse',
          'description': 'Moves the mouse cursor to specified coordinates',
          'parameters': {
            'type': 'object',
            'properties': {
              'x': {'type': 'integer', 'description': 'X coordinate on screen'},
              'y': {'type': 'integer', 'description': 'Y coordinate on screen'},
            },
            'required': ['x', 'y'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'clickMouse',
          'description': 'Clicks a mouse button at current position',
          'parameters': {
            'type': 'object',
            'properties': {
              'button': {
                'type': 'string',
                'description': 'Mouse button to click: left, right, or middle',
                'enum': ['left', 'right', 'middle'],
              },
              'action': {
                'type': 'string',
                'description': 'Type of action: click, press, or release',
                'enum': ['click', 'press', 'release'],
              },
            },
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'typeText',
          'description': 'Types text using the keyboard',
          'parameters': {
            'type': 'object',
            'properties': {
              'text': {'type': 'string', 'description': 'Text to type'},
            },
            'required': ['text'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'pressKeys',
          'description': 'Presses a keyboard keys',
          'parameters': {
            'type': 'object',
            'properties': {
              'keys': {
                'type': 'array',
                'description': 'Key to press [cmd, space]',
                'items': {
                  'type': 'string',
                  'enum': UniversalKey.values.map((e) => e.name).toList(),
                },
              },
            },
            'required': ['keys'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'wait',
          'description': 'Waits for a specified number of seconds',
          'parameters': {
            'type': 'object',
            'properties': {
              'seconds': {'type': 'number', 'description': 'Number of seconds to wait'},
            },
            'required': ['seconds'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'getShortcuts',
          'description':
              'Fetches keyboard shortcuts for a specific app or system task using AI. Use this to discover shortcuts instead of using vision/mouse.',
          'parameters': {
            'type': 'object',
            'properties': {
              'query': {
                'type': 'string',
                'description':
                    'Description of the app or task to get shortcuts for (e.g., "Chrome browser", "VS Code", "macOS window management", "text editing")',
              },
            },
            'required': ['query'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'askUser',
          'description': 'Asks the user a question and waits for their response.',
          'parameters': {
            'type': 'object',
            'properties': {
              'question': {'type': 'string', 'description': 'The question to ask the user.'},
            },
            'required': ['question'],
          },
        },
      },
      {
        'type': 'function',
        'function': {
          'name': 'createCalendarEvent',
          'description':
              'Creates an event in the user\'s macOS Calendar app via AppleScript. Use this for any request to schedule, remind, book, or add something to the calendar — including prescription pickups, appointments, meetings, and reminders. Much more reliable than clicking through Calendar.app with mouse/keyboard.',
          'parameters': {
            'type': 'object',
            'properties': {
              'title': {
                'type': 'string',
                'description': 'Short event title (e.g., "Pick up prescription", "Doctor appointment").',
              },
              'date': {
                'type': 'string',
                'description':
                    'ISO date YYYY-MM-DD. You MUST resolve relative words like "today", "tomorrow", "Thursday", "next Monday" into a concrete date yourself using the "Today is ..." line in the system prompt.',
              },
              'startTime': {
                'type': 'string',
                'description':
                    '24-hour start time HH:MM (e.g., "09:00", "14:30"). Optional — defaults to "09:00". Ignored if allDay is true.',
              },
              'durationMinutes': {
                'type': 'integer',
                'description':
                    'Event duration in minutes. Optional — defaults to 30. Ignored if allDay is true.',
              },
              'notes': {
                'type': 'string',
                'description':
                    'Free-form notes/description for the event (e.g., the original voice transcript). Optional.',
              },
              'calendarName': {
                'type': 'string',
                'description':
                    'Name of the calendar to add the event to. Optional — defaults to the first writable calendar.',
              },
              'allDay': {
                'type': 'boolean',
                'description':
                    'If true, creates an all-day event (startTime / durationMinutes are ignored). Optional — defaults to false.',
              },
            },
            'required': ['title', 'date'],
          },
        },
      },
    ];
