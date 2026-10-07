import '../models/tool_execution_result.dart';

/// Private message readouts and sender names stay on the phone. The remote
/// voice agent receives a completion/clarification status with no previews.
Map<String, dynamic>? notificationResultForAgent(ToolExecutionResult result) {
  if (!result.containsMessageData) return null;
  final needsInput = result.status == ToolExecutionStatus.needsInput;
  return {
    'success': !needsInput && result.status == ToolExecutionStatus.completed,
    'status': needsInput ? 'needs_input' : 'completed',
    'spoken_locally': result.spokenLocally,
    'message': needsInput
        ? result.messageReadout?.channel == 'maps'
              ? 'A Maps route clarification was spoken on the phone. Wait for the user to choose a displayed route number.'
              : 'A clarification was spoken on the phone. Wait for the user to specify the full sender or conversation name.'
        : 'The private readout was completed on the phone. Do not repeat it.',
  };
}
