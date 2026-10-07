class NotificationMessage {
  const NotificationMessage({
    required this.id,
    required this.sender,
    required this.body,
    required this.appName,
    this.conversation = '',
    this.subject = '',
  });

  final String id;
  final String sender;
  final String body;
  final String appName;
  final String conversation;
  final String subject;

  factory NotificationMessage.fromMap(Map<String, dynamic> row) =>
      NotificationMessage(
        id: row['id'].toString(),
        sender: row['sender'].toString(),
        body: row['body'].toString(),
        appName: row['appName'].toString(),
        conversation: row['conversation']?.toString() ?? '',
        subject: row['subject']?.toString() ?? '',
      );

  String get senderLabel => conversation.isEmpty || conversation == sender
      ? sender
      : '$sender in $conversation';

  String get speechText {
    final normalized = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    final shortened = normalized.runes.length > 240;
    final preview = shortened
        ? '${String.fromCharCodes(normalized.runes.take(240))}…'
        : normalized;
    return '$appName, $senderLabel: ${subject.isEmpty ? '' : '${String.fromCharCodes(subject.runes.take(250))}. '}$preview${shortened ? ' Preview shortened.' : ''}';
  }
}

class MessageReadout {
  const MessageReadout({
    required this.intro,
    this.messages = const [],
    this.footer = '',
    this.channel = 'all',
    this.sender,
  });

  final String intro;
  final List<NotificationMessage> messages;
  final String footer;
  final String channel;
  final String? sender;

  String get displayText => [
    intro,
    for (var i = 0; i < messages.length; i++)
      '${i + 1}. ${messages[i].senderLabel}: ${messages[i].subject.isEmpty ? '' : '${messages[i].subject}\n'}${messages[i].body}',
    if (footer.isNotEmpty) footer,
  ].join('\n\n');

  Map<String, dynamic> get replayArguments => channel == 'maps'
      ? {'read_current': true}
      : channel == 'gmail'
      ? {'repeat_last': true}
      : {
          'channel': channel,
          if (sender != null && sender!.isNotEmpty) 'sender': sender,
          'unread_only': false,
          'read_all': true,
        };
}
