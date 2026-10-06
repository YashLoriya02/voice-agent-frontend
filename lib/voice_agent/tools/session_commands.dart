/// Only standalone dismissal requests should end a conversation.
/// Requests about sleep, such as setting an alarm, must reach the agent.
bool isSessionExitCommand(String text) {
  final normalized = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceFirst(RegExp(r'^please '), '')
      .replaceFirst(RegExp(r' please$'), '');
  return const {
    'sleep',
    'exit',
    'go to sleep',
    'close assistant',
    'close the assistant',
    'close agent',
    'close the agent',
    'close agent app',
    'close the agent app',
    'close this app',
    'close the app',
    'dismiss assistant',
    'dismiss the assistant',
  }.contains(normalized);
}
