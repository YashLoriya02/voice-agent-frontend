import '../models/message_readout.dart';
import '../models/tool_execution_result.dart';
import 'device_action_service.dart';

class GmailService {
  static MessageReadout? _lastReadout;
  static Future<Map<String, dynamic>> status() =>
      DeviceActionService.deviceControl('gmailStatus', const {});
  static Future<Map<String, dynamic>> connect() =>
      DeviceActionService.deviceControl('connectGmail', const {});
  static Future<Map<String, dynamic>> disconnect() async {
    _lastReadout = null;
    return DeviceActionService.deviceControl('disconnectGmail', const {});
  }

  static Future<ToolExecutionResult> execute(
    Map<String, dynamic> args, {
    required bool readAloud,
    Future<void> Function(MessageReadout)? onLocalReadout,
  }) async {
    final limit = args['limit'] ?? 5;
    final unreadOnly = args['unread_only'] ?? true;
    if (limit is! int || limit < 1 || limit > 10 || unreadOnly is! bool) {
      return ToolExecutionResult.error('Choose a mail limit from 1 to 10.');
    }
    MessageReadout readout;
    if (args['repeat_last'] == true) {
      if (_lastReadout == null) {
        return ToolExecutionResult.error(
          'There is no previous mail readout in this session. Ask me to read Gmail first.',
        );
      }
      readout = _lastReadout!;
    } else {
      final response = await DeviceActionService.deviceControl(
        'getGmailMessages',
        {
          'limit': limit,
          'unreadOnly': unreadOnly,
          'countOnly': !readAloud,
          'sender': args['sender']?.toString() ?? '',
        },
      );
      if (response['success'] != true) {
        return ToolExecutionResult.error(
          response['message']?.toString() ?? 'Gmail is unavailable.',
        );
      }
      final rows = (response['messages'] as List? ?? [])
          .map(
            (row) => NotificationMessage.fromMap(
              Map<String, dynamic>.from(row as Map),
            ),
          )
          .toList();
      readout = MessageReadout(
        channel: 'gmail',
        intro: !readAloud
            ? 'You have ${response['unreadCount']} unread emails in your Gmail inbox.'
            : rows.isEmpty
            ? 'No ${unreadOnly ? 'unread ' : ''}emails match in your Gmail inbox.'
            : 'Reading ${rows.length} ${unreadOnly ? 'unread ' : ''}Gmail ${rows.length == 1 ? 'email' : 'emails'}: sender, subject and preview.',
        messages: rows,
        footer: readAloud && rows.isNotEmpty
            ? '${response['hasMore'] == true ? 'More matching emails are available. Ask for up to ten, or specify a sender. ' : ''}Reading aloud does not mark mail as read in Gmail.'
            : '',
      );
      if (readAloud && rows.isNotEmpty) _lastReadout = readout;
    }
    final batches = <String>[
      readout.intro,
      ...readout.messages.map((row) => row.speechText),
      if (readout.footer.isNotEmpty) readout.footer,
    ];
    for (final text in batches) {
      await onLocalReadout?.call(readout);
      final result = await DeviceActionService.deviceControl('speakGmail', {
        'text': text,
      });
      if (result['success'] != true) {
        return ToolExecutionResult.error(
          result['message']?.toString() ?? 'On-device mail speech failed.',
        );
      }
    }
    return ToolExecutionResult(
      status: ToolExecutionStatus.completed,
      message: readout.displayText,
      spokenLocally: true,
      containsMessageData: true,
      messageReadout: readout,
    );
  }
}
