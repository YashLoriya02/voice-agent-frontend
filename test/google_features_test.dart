import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/voice_agent/models/tool_execution_result.dart';
import 'package:frontend/voice_agent/services/gmail_service.dart';
import 'package:frontend/voice_agent/services/maps_service.dart';
import 'package:frontend/voice_agent/services/voice_agent_api_service.dart';
import 'package:frontend/voice_agent/tools/notification_agent_result.dart';
import 'package:frontend/voice_agent/tools/tool_executor.dart';
import 'package:frontend/voice_agent/tools/private_readout_guard.dart';
import 'package:frontend/voice_agent/widgets/message_readout_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.infiheal.voice_agent/actions');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  var available = true;
  var speechWorks = true;
  setUp(() async {
    calls.clear();
    available = true;
    speechWorks = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getGmailMessages') {
        return available
            ? {
                'success': true,
                'unreadCount': 9,
                'hasMore': true,
                'messages': call.arguments['countOnly'] == true
                    ? []
                    : [
                        {
                          'id': 'mail1',
                          'sender': 'Private Sender <private@example.com>',
                          'subject': 'Private subject',
                          'body': 'Private preview content.',
                          'appName': 'Gmail',
                        },
                      ],
              }
            : {'success': false, 'message': 'Connect Gmail first.'};
      }
      if (call.method == 'speakGmail') {
        return {
          'success': speechWorks,
          'message': speechWorks
              ? 'Read locally.'
              : 'Download an offline voice.',
        };
      }
      return {'success': true};
    });
    await GmailService.disconnect();
    calls.clear();
  });
  tearDown(() {
    MapsService.cancel();
    messenger.setMockMethodCallHandler(channel, null);
  });
  test('Last sender email reaches native Gmail with limit one and includes already-read mail', () async {
    final command = await VoiceAgentApiService.executeCommand(
      'Read last email from JetGPT.',
    );
    final result = await ToolExecutor.execute(
      tool: command.tool!,
      arguments: command.arguments,
    );
    expect(result.status, ToolExecutionStatus.completed);
    expect(calls.first.method, 'getGmailMessages');
    expect(calls.first.arguments, {
      'limit': 1,
      'unreadOnly': false,
      'countOnly': false,
      'sender': 'JetGPT',
    });
  });
  test('Navigation launches immediately without accessibility readout or custom GPS request', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {
        'success': true,
        'status': 'opened',
        'message': 'Opening Google Maps navigation.',
      };
    });
    final command = await VoiceAgentApiService.executeCommand(
      'Navigate to Pune from my current location',
    );
    var readouts = 0;
    final result = await ToolExecutor.execute(
      tool: command.tool!,
      arguments: command.arguments,
      onLocalReadout: (_) async {
        readouts++;
      },
    );
    expect(calls.single.method, 'getInstalledMapsRoute');
    expect(calls.single.arguments, {
      'destination': 'Pune',
      'readCurrent': false,
      'startNavigation': true,
    });
    expect(readouts, 0);
    expect(result.speakResult, isTrue);
    expect(result.status, ToolExecutionStatus.completed);
  });
  test('Gmail routes unread filter, sender and limit to native; private readout never enters agent result', () async {
    final result = await ToolExecutor.execute(
      tool: 'read_gmail',
      arguments: {'limit': 2, 'sender': 'private@example.com'},
    );
    expect(result.status, ToolExecutionStatus.completed);
    expect(calls.first.arguments, {
      'limit': 2,
      'unreadOnly': true,
      'countOnly': false,
      'sender': 'private@example.com',
    });
    expect(result.messageReadout!.messages.single.subject, 'Private subject');
    expect(
      calls
          .where((c) => c.method == 'speakGmail')
          .map((c) => c.arguments['text'])
          .join(' '),
      contains('Private subject'),
    );
    final remote = jsonEncode(notificationResultForAgent(result));
    for (final value in [
      'Private Sender',
      'Private subject',
      'Private preview',
      'private@example.com',
      '9',
    ]) {
      expect(remote, isNot(contains(value)));
    }
    expect(result.speakResult, isFalse);
  });
  test('Gmail check speaks actual inbox count locally without reading message bodies', () async {
    final result = await ToolExecutor.execute(
      tool: 'check_gmail',
      arguments: {},
    );
    expect(result.message, contains('9 unread emails'));
    expect(calls.first.arguments['countOnly'], isTrue);
    expect(result.messageReadout!.messages, isEmpty);
    expect(
      jsonEncode(notificationResultForAgent(result)),
      isNot(contains('9')),
    );
  });

  test(
    'Private cards remain ineligible for cloud TTS after local speech finishes',
    () async {
      final result = await ToolExecutor.execute(
        tool: 'read_gmail',
        arguments: {},
      );
      expect(cloudFallbackText(result.message, result.messageReadout), isEmpty);
      expect(
        cloudFallbackText('Ordinary remote reply', null),
        'Ordinary remote reply',
      );
    },
  );
  test('Repeat mail uses the previous local rows, not a second inbox fetch; disconnect clears replay', () async {
    await ToolExecutor.execute(tool: 'read_gmail', arguments: {});
    calls.clear();
    final repeat = await ToolExecutor.execute(
      tool: 'read_gmail',
      arguments: {'repeat_last': true},
    );
    expect(repeat.message, contains('Private preview'));
    expect(calls.any((c) => c.method == 'getGmailMessages'), isFalse);
    await GmailService.disconnect();
    expect(
      (await ToolExecutor.execute(
        tool: 'read_gmail',
        arguments: {'repeat_last': true},
      )).status,
      ToolExecutionStatus.error,
    );
  });
  test('Missing Gmail connection and failed offline speech report actionable errors', () async {
    available = false;
    expect(
      (await ToolExecutor.execute(tool: 'read_gmail', arguments: {})).message,
      'Connect Gmail first.',
    );
    expect(calls.any((c) => c.method == 'speakGmail'), isFalse);
    available = true;
    speechWorks = false;
    expect(
      (await ToolExecutor.execute(tool: 'read_gmail', arguments: {})).message,
      'Download an offline voice.',
    );
  });
  testWidgets(
    'Gmail cards show sender, subject and preview in separate fields',
    (tester) async {
      final result = await ToolExecutor.execute(
        tool: 'read_gmail',
        arguments: {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageReadoutView(readout: result.messageReadout!),
          ),
        ),
      );
      expect(find.text('Private subject'), findsOneWidget);
      expect(find.text('Private preview content.'), findsOneWidget);
      expect(result.messageReadout!.replayArguments, {'repeat_last': true});
    },
  );
  test('Installed Maps reads native displayed metrics and speaks offline without location/API requests', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getInstalledMapsRoute') {
        return {
          'success': true,
          'route': {
            'distanceMeters': 12500.0,
            'durationSeconds': 1020,
            'distanceText': '12.5 km',
            'durationText': '17 min',
          },
        };
      }
      return {'success': true};
    });
    var updates = 0;
    final result = await ToolExecutor.execute(
      tool: 'get_driving_route',
      arguments: {'destination': 'Mumbai airport'},
      onLocalReadout: (_) async {
        updates++;
      },
    );
    expect(calls.first.method, 'getInstalledMapsRoute');
    expect(calls.first.arguments, {
      'destination': 'Mumbai airport',
      'readCurrent': false,
    });
    expect(calls.last.method, 'speakInstalledMapsRoute');
    expect(calls.any((c) => c.method == 'getRouteLocation'), isFalse);
    expect(result.message, contains('12.5 km'));
    expect(result.message, contains('17 min'));
    expect(result.spokenLocally, isTrue);
    expect(updates, 2);
    expect(
      jsonEncode(notificationResultForAgent(result)),
      isNot(contains('12.5')),
    );
    expect(result.messageReadout!.replayArguments, {'read_current': true});
  });
  test('Without accessibility it opens Maps and explains setup without inventing an estimate', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {
        'success': true,
        'status': 'opened',
        'message': 'Google Maps directions are open. Enable Maps reader.',
      };
    });
    final result = await MapsService.execute({'destination': 'Airport'});
    expect(result.status, ToolExecutionStatus.completed);
    expect(result.message, contains('Enable Maps reader'));
    expect(result.speakResult, isTrue);
    expect(calls, hasLength(1));
  });
  test('Several displayed routes require a choice and then read the current Maps screen', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getInstalledMapsRoute' &&
          call.arguments['choice'] == null) {
        return {
          'success': true,
          'status': 'needs_input',
          'routes': [
            {'distanceText': '12 km', 'durationText': '15 min'},
            {'distanceText': '14 km', 'durationText': '16 min'},
          ],
        };
      }
      if (call.method == 'getInstalledMapsRoute') {
        return {
          'success': true,
          'route': {
            'distanceMeters': 14000,
            'durationSeconds': 960,
            'distanceText': '14 km',
            'durationText': '16 min',
          },
        };
      }
      return {'success': true};
    });
    final options = await MapsService.execute({'destination': 'Airport'});
    expect(options.status, ToolExecutionStatus.needsInput);
    expect(options.message, contains('2. 14 km'));
    expect(options.spokenLocally, isTrue);
    expect(
      jsonEncode(notificationResultForAgent(options)),
      isNot(contains('14 km')),
    );
    final selected = await MapsService.execute({'choice': 2});
    expect(selected.status, ToolExecutionStatus.completed);
    final query = calls
        .where((call) => call.method == 'getInstalledMapsRoute')
        .last;
    expect(query.arguments['readCurrent'], isTrue);
    expect(query.arguments['choice'], 2);
  });
  test('Missing destination never opens Maps; corrupt summary never starts readout', () async {
    final missing = await MapsService.execute({});
    expect(missing.status, ToolExecutionStatus.needsInput);
    expect(calls, isEmpty);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {
        'success': true,
        'route': {
          'distanceMeters': -1,
          'durationSeconds': 20,
          'distanceText': 'wrong',
          'durationText': 'wrong',
        },
      };
    });
    expect(
      (await MapsService.execute({'read_current': true})).status,
      ToolExecutionStatus.error,
    );
    expect(calls, hasLength(1));
  });
  test('Interrupted or inaccessible Maps returns the native error without speaking fabricated numbers', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {'success': false, 'message': 'Unlock your phone.'};
    });
    final result = await MapsService.execute({'destination': 'Airport'});
    expect(result.status, ToolExecutionStatus.error);
    expect(result.message, 'Unlock your phone.');
    expect(calls, hasLength(1));
  });
}
