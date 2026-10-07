import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/voice_agent/screens/agent_settings_screen.dart';
import 'package:frontend/voice_agent/theme/agent_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.infiheal.voice_agent/actions');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  var mapsReady = false, gmailConnected = false;
  String? selectedProvider;
  bool? selectedWake;
  Completer<Map<String, dynamic>>? consent;
  final calls = <String>[];

  setUp(() {
    mapsReady = false;
    gmailConnected = false;
    selectedProvider = null;
    selectedWake = null;
    consent = null;
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'messageNotificationStatus':
          return {'enabled': true, 'connected': true};
        case 'gmailStatus':
          return {
            'connected': gmailConnected,
            'email': 'your.account@gmail.com',
          };
        case 'installedMapsStatus':
          return {'installed': true, 'connected': mapsReady};
        case 'connectGmail':
          return consent?.future ??
              {'success': false, 'message': 'Google consent was cancelled.'};
        default:
          return {'success': true};
      }
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Widget settings({GlobalKey? previewKey, double scale = 1}) => MaterialApp(
    theme: AgentTheme.dark,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: RepaintBoundary(
      key: previewKey,
      child: AgentSettingsScreen(
        provider: 'customGroq',
        wakeEnabled: true,
        isDefaultAssistant: true,
        onProviderChanged: (value) async {
          selectedProvider = value;
        },
        onWakeChanged: (value) async {
          selectedWake = value;
        },
        onMakeDefault: () async => true,
        onPreview: () async {},
      ),
    ),
  );

  testWidgets(
    'Voice selection and wake switch invoke saved-setting actions without a popup',
    (tester) async {
      await tester.pumpWidget(settings());
      await tester.pump();
      await tester.tap(find.text('Deepgram'));
      await tester.pump();
      expect(selectedProvider, 'deepgramVoiceAgent');
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(selectedWake, false);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Gmail prevents duplicate connection taps and displays failure inline',
    (tester) async {
      consent = Completer<Map<String, dynamic>>();
      await tester.pumpWidget(settings());
      await tester.pump();
      await tester.ensureVisible(find.text('Connect Gmail'));
      await tester.tap(find.text('Connect Gmail'));
      await tester.pump();
      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Connect Gmail'),
      );
      expect(button.onPressed, isNull);
      expect(calls.where((call) => call == 'connectGmail'), hasLength(1));
      consent!.complete({
        'success': false,
        'message': 'Google consent was cancelled.',
      });
      await tester.pump();
      await tester.pump();
      expect(find.text('Google consent was cancelled.'), findsOneWidget);
      expect(
        tester.getRect(find.text('Google consent was cancelled.')).top,
        lessThan(140),
      );
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('Returning from Android settings refreshes Maps reader status', (
    tester,
  ) async {
    await tester.pumpWidget(settings());
    await tester.pump();
    expect(find.text('Enable reader for spoken estimates'), findsOneWidget);
    await tester.ensureVisible(find.text('Enable Maps reader'));
    await tester.tap(find.text('Enable Maps reader'));
    await tester.pump();
    expect(calls, contains('openMapsReaderSettings'));
    mapsReady = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('Maps reader is ready'), findsOneWidget);
  });

  testWidgets('Read action returns its phone tool to the agent page', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: AgentTheme.dark,
        navigatorKey: navigator,
        home: const Scaffold(body: Text('Agent')),
      ),
    );
    final result = navigator.currentState!.push<SettingsReadRequest>(
      MaterialPageRoute(
        builder: (_) => AgentSettingsScreen(
          provider: 'customGroq',
          wakeEnabled: false,
          isDefaultAssistant: true,
          onProviderChanged: (_) async {},
          onWakeChanged: (_) async {},
          onMakeDefault: () async => true,
          onPreview: () async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(find.text('Read unread mail'));
    await tester.tap(find.text('Read unread mail'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect((await result)?.tool, 'read_gmail');
    expect(find.text('Agent'), findsOneWidget);
  });

  testWidgets(
    'Small screens and enlarged text keep every settings action reachable',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(settings(scale: 1.5));
      await tester.pump();
      await tester.tap(find.widgetWithText(ActionChip, 'Maps'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.text('Read current route')).top,
        lessThan(740),
      );
      await tester.ensureVisible(find.text('Connect Gmail'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Render settings previews for visual review', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const export = bool.fromEnvironment('EXPORT_UI_PREVIEWS');
    const fontPath = String.fromEnvironment('UI_FONT_PATH');
    if (export && fontPath.isNotEmpty) {
      await tester.runAsync(() async {
        final bytes = await File(fontPath).readAsBytes();
        final loader = FontLoader('Roboto')
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
        final icons = await File(
          '${File(fontPath).parent.path}/materialicons-regular.otf',
        ).readAsBytes();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(icons)))).load();
      });
    }
    mapsReady = true;
    gmailConnected = true;
    final key = GlobalKey();
    await tester.pumpWidget(settings(previewKey: key));
    await tester.pump();
    Future<void> capture(String name) async {
      if (!export) return;
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/ui-previews/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('settings-voice');
    await tester.tap(find.widgetWithText(ActionChip, 'Maps'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await capture('settings-connections');
    expect(tester.takeException(), isNull);
  });
}
