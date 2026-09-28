import 'contact_match.dart';

enum ToolExecutionStatus { completed, needsContactSelection, error }

class ToolExecutionResult {
  final ToolExecutionStatus status;

  final String message;

  final List<ContactMatch> contacts;

  final String? pendingContactTool;

  final Map<String, dynamic> pendingContactArguments;

  ToolExecutionResult({
    required this.status,
    required this.message,
    this.contacts = const [],
    this.pendingContactTool,
    this.pendingContactArguments = const <String, dynamic>{},
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
    List<ContactMatch> contacts, {
    String? pendingContactTool,
    Map<String, dynamic> pendingContactArguments =
        const <String, dynamic>{},
  }) {
    return ToolExecutionResult(
      status: ToolExecutionStatus.needsContactSelection,
      message: message,
      contacts: contacts,
      pendingContactTool: pendingContactTool,
      pendingContactArguments: pendingContactArguments,
    );
  }
}
