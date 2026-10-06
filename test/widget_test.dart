import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const recordChannel = MethodChannel('com.llfbandit.record/messages');
  const actionsChannel = MethodChannel('com.infiheal.voice_agent/actions');
  var settingsOpened = false;
  setUp(() {
    settingsOpened = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(actionsChannel, (call) async {
          if (call.method == 'messageNotificationStatus') {
            return {'enabled': false, 'connected': false};
          }
          if (call.method == 'openMessageNotificationSettings') {
            settingsOpened = true;
          }
          return {'success': true};
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recordChannel, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(actionsChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(recordChannel, null);
  });

  testWidgets('normal launch shows the voice agent interface', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();
    expect(find.text('AI AGENT'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('native assistant host leaves the Flutter surface invisible', (
    tester,
  ) async {
    await tester.pumpWidget(const MyApp(backgroundAssistant: true));
    await tester.pump();
    expect(find.byType(Scaffold), findsNothing);
    expect(find.text('AI AGENT'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('message access setup works on a phone-sized screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MyApp());
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Message access'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Message access'), findsOneWidget);
    expect(find.textContaining('on-device voice'), findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await tester.pump();
    expect(settingsOpened, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  testWidgets(
    'saved-message menu and replay button read already-spoken history locally',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var localReads = 0;
      var historyRequested = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(actionsChannel, (call) async {
            if (call.method == 'messageNotificationStatus')
              return {'enabled': true, 'connected': true};
            if (call.method == 'getMessageNotifications') {
              historyRequested = call.arguments['includeHistory'] == true;
              return {
                'success': true,
                'unspokenIds': <String>[],
                'messages': [
                  {
                    'id': 'a',
                    'channel': 'whatsapp',
                    'appName': 'WhatsApp',
                    'sender': 'User1',
                    'conversation': '',
                    'body': 'Hello!\nHow are you?',
                    'timestamp': 2,
                  },
                  {
                    'id': 'b',
                    'channel': 'messages',
                    'appName': 'Messages',
                    'sender': 'User2',
                    'conversation': '',
                    'body': 'A new message',
                    'timestamp': 1,
                  },
                ],
              };
            }
            if (call.method == 'speakMessageNotifications') localReads++;
            return {'success': true};
          });
      final previewKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(key: previewKey, child: const MyApp()),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Message access'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Read all saved'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(historyRequested, isTrue);
      expect(localReads, 1);
      expect(find.text('User1'), findsOneWidget);
      expect(find.text('User2'), findsOneWidget);
      expect(find.text('Read all again'), findsOneWidget);
      await tester.ensureVisible(find.text('Read all again'));
      await tester.tap(find.text('Read all again'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(localReads, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
