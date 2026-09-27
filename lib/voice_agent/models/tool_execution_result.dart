import 'contact_match.dart';

enum ToolExecutionStatus { completed, needsContactSelection, error }

class ToolExecutionResult {
  final ToolExecutionStatus status;

  final String message;

  final List<ContactMatch> contacts;

  ToolExecutionResult({
    required this.status,
    required this.message,
    this.contacts = const [],
  });

  factory ToolExecutionResult.completed(String message) {
    return ToolExecutionResult(
      status: ToolExecutionStatus.completed,
      message: message,
    );
  }

  factory ToolExecutionResult.error(String message) {
    return ToolExecutionResult(
      status: ToolExecutionStatus.error,
      message: message,
    );
  }

  factory ToolExecutionResult.needsContactSelection(
    String message,
    List<ContactMatch> contacts,
  ) {
    return ToolExecutionResult(
      status: ToolExecutionStatus.needsContactSelection,
      message: message,
      contacts: contacts,
    );
  }
}
