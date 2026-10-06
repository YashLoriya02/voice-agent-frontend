import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/voice_agent/models/tool_execution_result.dart';
import 'package:frontend/voice_agent/tools/notification_agent_result.dart';
import 'package:frontend/voice_agent/tools/tool_executor.dart';
import 'package:frontend/voice_agent/tools/message_commands.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.infiheal.voice_agent/actions');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late List<Map<String, dynamic>> messages;
  late Set<String> unspoken;
  var access = true;
  var speechWorks = true;
  int? failAfterBatch;
  var speechBatches = 0;

  Map<String, dynamic> preview(
    String id,
    String source,
    String sender,
    String body,
    int time, {
    String conversation = '',
  }) => {
    'id': id,
    'channel': source,
    'sender': sender,
    'body': body,
    'timestamp': time,
    'conversation': conversation,
    'appName': source == 'whatsapp' ? 'WhatsApp' : 'Messages',
  };

  setUp(() {
    calls.clear();
    access = true;
    speechWorks = true;
    failAfterBatch = null;
    speechBatches = 0;
    messages = [
      preview('one', 'whatsapp', 'Yash', 'Meet at five.', 1),
      preview('two', 'messages', 'Papa', 'Bring milk.', 2),
      preview(
        'three',
        'whatsapp',
        'Yash',
        'See you there.',
        3,
        conversation: 'Friends',
      ),
    ];
    unspoken = messages.map((m) => m['id'] as String).toSet();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getMessageNotifications') {
        return access
            ? {
                'success': true,
                'messages': messages,
                'unspokenIds': unspoken.toList(),
              }
            : {
                'success': false,
                'message': 'Enable notification access, then ask again.',
              };
      }
      if (call.method == 'speakMessageNotifications') {
        speechBatches++;
        if (failAfterBatch != null && speechBatches > failAfterBatch!) {
          speechWorks = false;
        }
        if (speechWorks) {
          unspoken.removeAll((call.arguments['ids'] as List).cast<String>());
        }
        return {
          'success': speechWorks,
          'message': speechWorks
              ? 'Completed locally.'
              : 'On-device speech failed.',
        };
      }
      return {'success': true};
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'read filters source and sender, reads newest first, and uses local speech',
    () async {
      final result = await ToolExecutor.execute(
        tool: 'read_messages',
        arguments: {'channel': 'whatsapp', 'sender': 'Yash', 'limit': 1},
      );
      expect(result.status, ToolExecutionStatus.completed);
      expect(result.spokenLocally, isTrue);
      expect(result.speakResult, isFalse);
      expect(result.message, contains('Yash in Friends: See you there.'));
      expect(result.message, isNot(contains('Bring milk')));
      expect(calls.last.method, 'speakMessageNotifications');
      expect(calls.last.arguments['ids'], ['three']);
      expect(unspoken, {'one', 'two'});
    },
  );

  test(
    'check reports counts and senders but does not read or acknowledge bodies',
    () async {
      final result = await ToolExecutor.execute(
        tool: 'check_messages',
        arguments: {},
      );
      expect(result.message, contains('3 new message notification previews'));
      expect(result.message, contains('Yash'));
      expect(result.message, isNot(contains('Meet at five')));
      expect(calls.last.arguments['ids'], isEmpty);
      expect(unspoken.length, 3);
      expect(result.containsMessageData, isTrue);
    },
  );

  test(
    'read more excludes spoken previews; explicit repeat includes them',
    () async {
      await ToolExecutor.execute(
        tool: 'read_messages',
        arguments: {'channel': 'whatsapp'},
      );
      final next = await ToolExecutor.execute(
        tool: 'read_messages',
        arguments: {'channel': 'whatsapp'},
      );
      expect(next.message, contains('no new WhatsApp notification previews'));
      final repeated = await ToolExecutor.execute(
        tool: 'read_messages',
        arguments: {'channel': 'whatsapp', 'unread_only': false},
      );
      expect(repeated.message, contains('Meet at five.'));
    },
  );

  test(
    'missing access does not report an empty inbox or start speech',
    () async {
      access = false;
      final result = await ToolExecutor.execute(
        tool: 'read_messages',
        arguments: {},
      );
      expect(result.status, ToolExecutionStatus.error);
      expect(result.message, contains('Enable notification access'));
      expect(calls.map((c) => c.method), ['getMessageNotifications']);
    },
  );

  test('failed local speech leaves previews new', () async {
    speechWorks = false;
    final result = await ToolExecutor.execute(
      tool: 'read_messages',
      arguments: {},
    );
    expect(result.status, ToolExecutionStatus.error);
    expect(unspoken.length, 3);
  });

  test(
    'ambiguous sender is clarified locally without marking previews spoken',
    () async {
      messages = [
        preview('a', 'whatsapp', 'Yash Loriya', 'Private A', 1),
        preview('b', 'whatsapp', 'Yash Shah', 'Private B', 2),
      ];
      unspoken = {'a', 'b'};
      final result = await ToolExecutor.execute(
        tool: 'read_messages',
        arguments: {'sender': 'Yash'},
      );
      expect(result.status, ToolExecutionStatus.needsInput);
      expect(result.spokenLocally, isTrue);
      expect(calls.last.arguments['ids'], isEmpty);
      final remote = jsonEncode(notificationResultForAgent(result));
      expect(remote, isNot(contains('Yash')));
      expect(remote, contains('needs_input'));
    },
  );

  test(
    'notification contents and sender names never enter remote tool results',
    () async {
      final result = await ToolExecutor.execute(
        tool: 'read_messages',
        arguments: {},
      );
      final remote = jsonEncode(notificationResultForAgent(result));
      expect(remote, contains('spoken_locally'));
      for (final sensitive in [
        'Yash',
        'Papa',
        'Meet at five',
        'Bring milk',
        'Friends',
      ]) {
        expect(remote, isNot(contains(sensitive)));
      }
    },
  );

  test('invalid limits are rejected before reading native data', () async {
    final result = await ToolExecutor.execute(
      tool: 'read_messages',
      arguments: {'limit': 30},
    );
    expect(result.status, ToolExecutionStatus.error);
    expect(calls, isEmpty);
  });

  test(
    'long batches are bounded and only included previews are acknowledged',
    () async {
      messages = List.generate(
        10,
        (i) => preview('$i', 'whatsapp', 'Yash', '🙂' * 300, i),
      );
      unspoken = messages.map((m) => m['id'] as String).toSet();
      final result = await ToolExecutor.execute(
        tool: 'read_messages',
        arguments: {'limit': 10},
      );
      expect(
        (calls.last.arguments['text'] as String).length,
        lessThanOrEqualTo(2000),
      );
      expect(calls.last.arguments['text'], contains('Preview shortened'));
      expect(result.messageReadout!.messages.first.body.runes.length, 300);
      expect(result.message, contains('more available'));
      expect(unspoken, isNotEmpty);
      expect((calls.last.arguments['ids'] as List).length, lessThan(10));
    },
  );

  test(
    'all saved messages replay across batches even with no new messages',
    () async {
      messages = List.generate(
        23,
        (i) => preview('$i', 'whatsapp', 'User$i', 'Already read $i.', i),
      );
      unspoken.clear();
      final result = await ToolExecutor.execute(
        tool: 'read_messages',
        arguments: resolveMessageReadArguments(
          'Read all my WhatsApp messages',
          {'channel': 'whatsapp'},
        ),
      );
      expect(result.status, ToolExecutionStatus.completed);
      expect(result.messageReadout!.messages.length, 23);
      expect(calls.first.arguments, {'includeHistory': true});
      final batches = calls
          .where((c) => c.method == 'speakMessageNotifications')
          .toList();
      expect(batches.length, greaterThan(1));
      expect(
        batches.expand((c) => (c.arguments['ids'] as List)).toSet().length,
        23,
      );
      for (final batch in batches) {
        expect(
          (batch.arguments['text'] as String).length,
          lessThanOrEqualTo(2000),
        );
        expect((batch.arguments['ids'] as List).length, lessThanOrEqualTo(10));
      }
    },
  );

  test(
    'failed later batch stops replay and acknowledges only completed batches',
    () async {
      messages = List.generate(
        23,
        (i) => preview('$i', 'whatsapp', 'User$i', 'Text $i.', i),
      );
      unspoken = messages.map((m) => m['id'] as String).toSet();
      failAfterBatch = 1;
      final result = await ToolExecutor.execute(
        tool: 'read_messages',
        arguments: {'read_all': true},
      );
      expect(result.status, ToolExecutionStatus.error);
      expect(speechBatches, 2);
      expect(unspoken.length, 13);
    },
  );

  test(
    'no-new response retains replay scope and history remains readable',
    () async {
      unspoken.clear();
      final empty = await ToolExecutor.execute(
        tool: 'read_messages',
        arguments: {'channel': 'whatsapp'},
      );
      expect(empty.messageReadout!.messages, isEmpty);
      final replay = await ToolExecutor.execute(
        tool: 'read_messages',
        arguments: empty.messageReadout!.replayArguments,
      );
      expect(replay.messageReadout!.messages.length, 2);
      expect(replay.messageReadout!.channel, 'whatsapp');
    },
  );

  test(
    'explicit replay and all-new commands override model defaults correctly',
    () {
      for (final command in [
        'Repeat those messages',
        'Read all messages',
        'Read messages already read by you',
      ]) {
        final args = resolveMessageReadArguments(command, {
          'channel': 'whatsapp',
          'unread_only': true,
        });
        expect(args['unread_only'], isFalse, reason: command);
        expect(args['read_all'], isTrue);
        expect(args['channel'], 'whatsapp');
      }
      expect(
        resolveMessageReadArguments(
          'Read all unread messages',
          {},
        )['unread_only'],
        isTrue,
      );
      expect(resolveMessageReadArguments('Read my messages', {}), isEmpty);
    },
  );
}
