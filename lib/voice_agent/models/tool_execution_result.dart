import 'contact_match.dart';
import 'message_readout.dart';

enum ToolExecutionStatus { completed, needsContactSelection, needsInput, error }

class ToolExecutionResult {
  final ToolExecutionStatus status;

  final String message;

  final bool speakResult;
  final bool spokenLocally;
  final bool containsMessageData;
  final MessageReadout? messageReadout;

  final List<ContactMatch> contacts;

  final String? pendingContactTool;

  final Map<String, dynamic> pendingContactArguments;

  ToolExecutionResult({
    required this.status,
    required this.message,
    this.speakResult = false,
    this.spokenLocally = false,
    this.containsMessageData = false,
    this.messageReadout,
    this.contacts = const [],
    this.pendingContactTool,
    this.pendingContactArguments = const <String, dynamic>{},
  });

  factory ToolExecutionResult.completed(
    String message, {
    bool speakResult = false,
    bool spokenLocally = false,
    bool containsMessageData = false,
  }) {
    return ToolExecutionResult(
      status: ToolExecutionStatus.completed,
      message: message,
      speakResult: speakResult,
      spokenLocally: spokenLocally,
      containsMessageData: containsMessageData,
    );
  }

  factory ToolExecutionResult.needsInput(String message) => ToolExecutionResult(
    status: ToolExecutionStatus.needsInput,
    message: message,
  );

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
    Map<String, dynamic> pendingContactArguments = const <String, dynamic>{},
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
