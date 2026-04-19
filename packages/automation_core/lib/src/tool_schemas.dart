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
    ];
