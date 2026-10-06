/// Explicit replay/all requests override a model's default unread filter.
/// Only apply this to read_messages, never to unrelated device actions.
Map<String, dynamic> resolveMessageReadArguments(
  String command,
  Map<String, dynamic> arguments,
) {
  final text = command
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final result = Map<String, dynamic>.from(arguments);
  final all =
      RegExp(r'\b(all|every)\b').hasMatch(text) &&
      RegExp(r'\bmessages?\b').hasMatch(text);
  final repeat =
      RegExp(r'\b(repeat|replay|reread)\b').hasMatch(text) ||
      (RegExp(r'\bmessages?\b').hasMatch(text) &&
          RegExp(r'\b(again|already read|previously read|saved|old)\b')
              .hasMatch(text));
  final explicitNew = RegExp(r'\b(new|unread|unseen)\b').hasMatch(text);
  if (all || repeat) {
    result['read_all'] = true;
    result['unread_only'] = explicitNew;
  }
  return result;
}
