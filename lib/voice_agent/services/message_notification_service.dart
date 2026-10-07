import '../models/message_readout.dart';
import '../models/tool_execution_result.dart';
import 'device_action_service.dart';
import 'maps_service.dart';

class MessageNotificationService {
  static Future<Map<String, dynamic>> status() =>
      DeviceActionService.deviceControl('messageNotificationStatus', const {});
  static Future<void> openSettings() async {
    await DeviceActionService.deviceControl(
      'openMessageNotificationSettings',
      const {},
    );
  }

  static Future<void> stopReadout() async {
    MapsService.cancel();
    try {
      await DeviceActionService.deviceControl('stopGmailReadout', const {});
    } catch (_) {}
    await DeviceActionService.deviceControl('stopMessageReadout', const {});
  }

  static Future<ToolExecutionResult> execute(
    Map<String, dynamic> args, {
    required bool readAloud,
    Future<void> Function(MessageReadout)? onLocalReadout,
  }) async {
    final channel = args['channel'] ?? 'all';
    final unreadOnly = args['unread_only'] ?? true;
    final readAll = args['read_all'] ?? false;
    final limit = args['limit'] ?? 5;
    if (!['all', 'whatsapp', 'messages'].contains(channel) ||
        unreadOnly is! bool ||
        readAll is! bool ||
        limit is! int ||
        limit < 1 ||
        limit > 10) {
      return ToolExecutionResult.error(
        'Choose WhatsApp, Messages, or all messages, and a limit from 1 to 10.',
      );
    }
    final response = await DeviceActionService.deviceControl(
      'getMessageNotifications',
      {'includeHistory': !unreadOnly},
    );
    if (response['success'] != true) {
      return ToolExecutionResult.error(
        response['message']?.toString() ??
            'Message notification access is unavailable.',
      );
    }
    final unspoken = (response['unspokenIds'] as List? ?? [])
        .map((id) => id.toString())
        .toSet();
    var messages = (response['messages'] as List? ?? [])
        .map((row) => Map<String, dynamic>.from(row as Map))
        .where(
          (row) =>
              (channel == 'all' || row['channel'] == channel) &&
              (!unreadOnly || unspoken.contains(row['id'])),
        )
        .toList();
    final sender = String.fromCharCodes(
      (args['sender']?.toString().trim() ?? '').runes.take(120),
    );
    Future<ToolExecutionResult> simple(
      String text, {
      bool needsInput = false,
    }) => _speak(
      MessageReadout(intro: text, channel: channel, sender: sender),
      [_SpeechBatch(text, const [])],
      onLocalReadout,
      needsInput: needsInput,
    );
    if (sender.isNotEmpty) {
      final query = _normalize(sender);
      if (query.isEmpty) {
        return ToolExecutionResult.error(
          'Tell me the sender or conversation name.',
        );
      }
      final exact = messages
          .where(
            (row) =>
                _normalize(row['sender'].toString()) == query ||
                _normalize(row['conversation']?.toString() ?? '') == query,
          )
          .toList();
      if (exact.isNotEmpty) {
        messages = exact;
      } else {
        final partial = messages
            .where(
              (row) =>
                  _normalize(row['sender'].toString()).contains(query) ||
                  _normalize(row['conversation']?.toString() ?? '')
                      .contains(query),
            )
            .toList();
        final names = partial
            .map(
              (row) => _normalize(row['sender'].toString()).contains(query)
                  ? row['sender'].toString()
                  : row['conversation'].toString(),
            )
            .toSet();
        if (names.length > 1) {
          return simple(
            'I found messages for ${names.take(5).join(', ')}${names.length > 5 ? ' and others' : ''}. Which sender or conversation do you mean?',
            needsInput: true,
          );
        }
        messages = partial;
      }
    }
    final source = channel == 'whatsapp'
        ? 'WhatsApp'
        : channel == 'messages'
        ? 'Messages'
        : 'message';
    final filter = sender.isEmpty ? '' : ' for $sender';
    if (messages.isEmpty) {
      return simple(
        'I have no ${unreadOnly ? 'new ' : 'saved '}$source notification previews$filter available.',
      );
    }
    messages.sort(
      (a, b) => (b['timestamp'] as num).compareTo(a['timestamp'] as num),
    );
    if (!readAloud) {
      final names = messages.map((row) => row['sender'].toString()).toSet();
      return simple(
        'You have ${messages.length} ${unreadOnly ? 'new ' : 'saved '}$source notification ${messages.length == 1 ? 'preview' : 'previews'}$filter from ${names.take(5).join(', ')}${names.length > 5 ? ' and others' : ''}.',
      );
    }
    final candidates = messages
        .take(readAll ? messages.length : limit)
        .map(NotificationMessage.fromMap)
        .where((row) => row.body.trim().isNotEmpty)
        .toList();
    final selected = <NotificationMessage>[];
    final chunks = <List<NotificationMessage>>[];
    var chunk = <NotificationMessage>[];
    var characters = 0;
    for (final row in candidates) {
      if (chunk.length >= 10 || characters + row.speechText.length > 1450) {
        chunks.add(chunk);
        if (!readAll) break;
        chunk = [];
        characters = 0;
      }
      selected.add(row);
      chunk.add(row);
      characters += row.speechText.length;
    }
    if (chunk.isNotEmpty &&
        (chunks.isEmpty || !identical(chunks.last, chunk))) {
      chunks.add(chunk);
    }
    final remaining = messages.length - selected.length;
    final intro =
        'Reading ${selected.length} ${unreadOnly ? 'new' : 'saved'} message notification ${selected.length == 1 ? 'preview' : 'previews'}$filter.';
    final footer = remaining > 0
        ? '$remaining more available. Ask me to read more messages.'
        : '';
    final readout = MessageReadout(
      intro: intro,
      messages: selected,
      footer: footer,
      channel: channel,
      sender: sender,
    );
    final batches = <_SpeechBatch>[
      for (var i = 0; i < chunks.length; i++)
        _SpeechBatch(
          '${i == 0 ? '$intro ' : ''}${chunks[i].map((row) => row.speechText).join(' ')}${i == chunks.length - 1 && footer.isNotEmpty ? ' $footer' : ''}',
          chunks[i].map((row) => row.id).toList(),
        ),
    ];
    return _speak(readout, batches, onLocalReadout);
  }

  static Future<ToolExecutionResult> _speak(
    MessageReadout readout,
    List<_SpeechBatch> batches,
    Future<void> Function(MessageReadout)? onLocalReadout, {
    bool needsInput = false,
  }) async {
    for (final batch in batches) {
      await onLocalReadout?.call(readout);
      final result = await DeviceActionService.deviceControl(
        'speakMessageNotifications',
        {'text': batch.text, 'ids': batch.ids},
      );
      if (result['success'] != true) {
        return ToolExecutionResult.error(
          result['message']?.toString() ?? 'On-device message speech failed.',
        );
      }
    }
    return ToolExecutionResult(
      status: needsInput
          ? ToolExecutionStatus.needsInput
          : ToolExecutionStatus.completed,
      message: readout.displayText,
      spokenLocally: true,
      containsMessageData: true,
      messageReadout: readout,
    );
  }

  static String _normalize(String value) => value.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]', unicode: true),
    '',
  );
}

class _SpeechBatch {
  const _SpeechBatch(this.text, this.ids);
  final String text;
  final List<String> ids;
}
