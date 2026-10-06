const List<Map<String, dynamic>> deviceToolDefinitions = [
  {
    'name': 'read_messages',
    'description': 'Read captured WhatsApp or SMS/RCS notification previews aloud ON THE PHONE. Defaults to previews not yet spoken. Set unread_only=false for repeat, saved, already-read, or all messages. Set read_all=true to read all matching saved previews in speech batches. These are captured previews, not the complete source inbox. Contents never appear in the remote response.',
    'parameters': messageQueryParameters,
    'defer_until_eot': true,
  },
  {
    'name': 'check_messages',
    'description': 'Report new WhatsApp or SMS/RCS notification preview counts and senders ON THE PHONE with on-device speech, without reading bodies or marking them spoken. The function response contains only completion status. Defaults to all channels and previews not yet spoken.',
    'parameters': messageQueryParameters,
    'defer_until_eot': true,
  },
  {
    'name': 'sleep_agent',
    'description': 'End this assistant session and close its app or bottom sheet when the user says Sleep, Exit, or asks to dismiss the assistant. Do not use for sleep advice or alarms.',
    'parameters': {
      'type': 'object',
      'properties': {},
      'required': <String>[],
      'additionalProperties': false,
    },
    'defer_until_eot': true,
  },
  {
    'name': 'set_torch',
    'description': 'Turn the phone torch or flashlight on or off.',
    'parameters': {
      'type': 'object',
      'properties': {
        'enabled': {'type': 'boolean'},
      },
      'required': ['enabled'],
      'additionalProperties': false,
    },
    'defer_until_eot': true,
  },
  {
    'name': 'control_volume',
    'description': 'Set, raise, lower, mute, or unmute phone volume. Default to media. percent is required for set; increase/decrease changes one system step.',
    'parameters': {
      'type': 'object',
      'properties': {
        'operation': {
          'type': 'string',
          'enum': ['set', 'increase', 'decrease', 'mute', 'unmute'],
        },
        'stream': {
          'type': 'string',
          'enum': ['media', 'ring', 'alarm'],
        },
        'percent': {'type': 'integer', 'minimum': 0, 'maximum': 100},
      },
      'required': ['operation'],
      'additionalProperties': false,
    },
    'defer_until_eot': true,
  },
  {
    'name': 'set_brightness',
    'description': 'Set screen brightness to a percentage from 0 (minimum) to 100. Requires modify system settings access and switches to manual brightness.',
    'parameters': {
      'type': 'object',
      'properties': {
        'percent': {'type': 'integer', 'minimum': 0, 'maximum': 100},
      },
      'required': ['percent'],
      'additionalProperties': false,
    },
    'defer_until_eot': true,
  },
  {
    'name': 'get_battery',
    'description': 'Read the actual battery percentage and charging state from this phone. Never guess the battery level.',
    'parameters': {
      'type': 'object',
      'properties': {},
      'required': <String>[],
      'additionalProperties': false,
    },
    'defer_until_eot': true,
  },
];

const Map<String, dynamic> messageQueryParameters = {
  'type': 'object',
  'properties': {
    'channel': {
      'type': 'string',
      'enum': ['all', 'whatsapp', 'messages'],
    },
    'sender': {
      'type': 'string',
      'description': 'Sender or conversation name requested by the user.',
    },
    'limit': {
      'type': 'integer',
      'minimum': 1,
      'maximum': 10,
      'description': 'Maximum previews to read, default 5.',
    },
    'unread_only': {
      'type': 'boolean',
      'description': 'True by default: previews not yet spoken by the assistant. False to repeat available previews.',
    },
    'read_all': {
      'type': 'boolean',
      'description': 'Read every matching captured preview in batches, ignoring limit. Default false. Use true for all/repeat requests.',
    },
  },
  'required': <String>[],
  'additionalProperties': false,
};
