import '../models/agent_response.dart';

/// Route explicit mail/Maps commands before conversational model/history.
/// Other commands continue through the existing assistant unchanged.
AgentResponse? routeGmailMapsCommand(String command) {
  final text = command.trim().replaceFirst(RegExp(r'[.!?]+$'), '').trim();
  if (text.contains('\n')) return null;
  final lower = text.toLowerCase();
  AgentResponse tool(String name, Map<String, dynamic> args) => AgentResponse(
    success: true,
    type: 'tool_call',
    tool: name,
    arguments: args,
  );
  RegExp pattern(String value) => RegExp(value, caseSensitive: false);
  final mail = pattern(
    r'^(?:please\s+)?(?:read|show(?:\s+me)?|tell(?:\s+me)?|check|repeat|replay|reread|do\s+i\s+have|are\s+there|any|how\s+many)\s+(?:(?:my|the|me|one|two|three|four|five|six|seven|eight|nine|ten|\d+|last|latest|newest|most\s+recent|recent|unread|unseen|new|already[ -]read|previously\s+read|read|old|all|every|previous|those|these)\s+)*(?:e-?mails?|gmail(?:\s+(?:e-?mails?|messages?))?|inbox)(?:\s+from\s+(.+?)|\s+again)?$',
  ).firstMatch(text);
  if (mail != null) {
    final sender = mail.group(1)?.trim();
    if (sender == null &&
        pattern(
          r'^(?:please\s+)?(?:check|do\s+i\s+have|are\s+there|any|how\s+many)\b',
        ).hasMatch(lower)) {
      return tool('check_gmail', {});
    }
    if (pattern(r'\b(repeat|replay|reread)\b|\bagain$').hasMatch(lower) &&
        sender == null) {
      return tool('read_gmail', {'repeat_last': true});
    }
    const numbers = {
      'one': 1,
      'two': 2,
      'three': 3,
      'four': 4,
      'five': 5,
      'six': 6,
      'seven': 7,
      'eight': 8,
      'nine': 9,
      'ten': 10,
    };
    // Inspect only the request, never numbers/qualifiers inside a sender name.
    final request = lower.split(RegExp(r'\s+from\s+')).first;
    final number = pattern(
      r'\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten)\b',
    ).firstMatch(request)?.group(1);
    final latest = pattern(r'\b(last|latest|newest|most\s+recent)\b')
        .hasMatch(request);
    final unread = pattern(r'\b(unread|unseen|new)\b').hasMatch(request);
    final includeRead =
        latest ||
        pattern(r'\b(already[ -]read|previously\s+read|old|all|every)\b')
            .hasMatch(request);
    return tool('read_gmail', {
      'limit': number == null
          ? (latest ? 1 : 5)
          : int.tryParse(number) ?? numbers[number]!,
      'unread_only': unread || !includeRead,
      'sender': ?sender,
    });
  }
  if (pattern(
    r'^(?:please\s+)?read\s+(?:the\s+)?(?:current|displayed)\s+(?:google\s+)?maps\s+route$',
  ).hasMatch(text)) {
    return tool('get_driving_route', {'read_current': true});
  }
  final choice = pattern(
    r'^(?:(?:read|choose|select)\s+)?(?:the\s+)?(first|second|third|[123])\s+route$',
  ).firstMatch(text);
  if (choice != null) {
    const choices = {'first': 1, 'second': 2, 'third': 3};
    final value = choice.group(1)!.toLowerCase();
    return tool('get_driving_route', {
      'read_current': true,
      'choice': int.tryParse(value) ?? choices[value]!,
    });
  }
  final navigation = pattern(
    r'^(?:please\s+)?(?:navigate(?:\s+me)?\s+to|start\s+(?:driving\s+)?navigation\s+to|take\s+me\s+to|drive\s+to|open\s+(?:google\s+)?maps\s+and\s+navigate\s+to)\s+(.+)$',
  ).firstMatch(text);
  final directions = pattern(
    r'^(?:please\s+)?(?:get|give(?:\s+me)?|show(?:\s+me)?|open)\s+(?:driving\s+)?directions\s+to\s+(.+)$',
  ).firstMatch(text);
  final distance = pattern(r'^how\s+(?:far|much|distant)\s+(?:is|are)\s+(.+)$')
      .firstMatch(text);
  if (pattern(r'^how\s+much\b').hasMatch(text) &&
      !pattern(
        r'\bfrom\s+(?:(?:my|the)\s+)?(?:current\s+)?(?:location|here)\b|\bby\s+(?:car|road)\b',
      ).hasMatch(text)) {
    return null;
  }
  final duration = pattern(
    r'^how\s+long\s+(?:(?:will|would|does)\s+it\s+take\s+(?:me\s+)?to\s+|to\s+)(?:drive|get|travel)\s+to\s+(.+)$',
  ).firstMatch(text);
  final match = navigation ?? directions ?? distance ?? duration;
  if (match == null) return null;
  var destination = match.group(1)!.trim();
  destination = destination.replaceFirst(
    pattern(
      r'\s+from\s+(?:(?:my|the)\s+)?(?:current\s+)?(?:location|here)(?:\s+by\s+car)?$',
    ),
    '',
  );
  destination = destination
      .replaceFirst(pattern(r'\s+(?:by\s+car|driving|by\s+road)$'), '')
      .trim();
  // An explicit different origin is outside this current-location grammar.
  if (destination.isEmpty || pattern(r'\s+from\s+').hasMatch(destination)) {
    return null;
  }
  return tool('get_driving_route', {
    'destination': destination,
    if (navigation != null) 'start_navigation': true,
  });
}
