import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/voice_agent/models/installed_app.dart';
import 'package:frontend/voice_agent/models/tool_execution_result.dart';
import 'package:frontend/voice_agent/tools/session_commands.dart';
import 'package:frontend/voice_agent/tools/tool_executor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.infiheal.voice_agent/actions');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  var nativeResult = <String, dynamic>{
    'success': true,
    'message': 'Your battery is at 73 percent and charging.',
  };
  var apps = <Map<String, String>>[];

  setUp(() {
    calls.clear();
    apps = [
      {'name': 'Signal', 'packageName': 'org.thoughtcrime.securesms'},
      {'name': 'WhatsApp', 'packageName': 'com.whatsapp'},
      {'name': 'WhatsApp Business', 'packageName': 'com.whatsapp.w4b'},
    ];
    nativeResult = {
      'success': true,
      'message': 'Your battery is at 73 percent and charging.',
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getLaunchableApps') return apps;
      if (call.method == 'openApp' || call.method == 'openAppTarget') {
        return null;
      }
      return nativeResult;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('launches a previously unmapped installed app by its label', () async {
    final result = await ToolExecutor.execute(
      tool: 'open_app',
      arguments: {'app_name': 'Signal app'},
    );
    expect(result.status, ToolExecutionStatus.completed);
    expect(calls.last.method, 'openApp');
    expect(calls.last.arguments, {'packageName': 'org.thoughtcrime.securesms'});
  });

  test(
    'exact label opens WhatsApp Business rather than the ordinary app',
    () async {
      await ToolExecutor.execute(
        tool: 'open_app',
        arguments: {'app_name': 'WhatsApp Business'},
      );
      expect(calls.last.arguments, {'packageName': 'com.whatsapp.w4b'});
    },
  );

  test(
    'ambiguous partial name requests input without opening either app',
    () async {
      final result = await ToolExecutor.execute(
        tool: 'open_app',
        arguments: {'app_name': 'Whats'},
      );
      expect(result.status, ToolExecutionStatus.needsInput);
      expect(calls.map((call) => call.method), ['getLaunchableApps']);
      expect(result.message, contains('WhatsApp Business'));
    },
  );

  test(
    'duplicate labels can be resolved by an explicit package name',
    () async {
      apps = [
        {'name': 'Notes', 'packageName': 'one.notes'},
        {'name': 'Notes', 'packageName': 'two.notes'},
      ];
      final ambiguous = await ToolExecutor.execute(
        tool: 'open_app',
        arguments: {'app_name': 'Notes'},
      );
      expect(ambiguous.status, ToolExecutionStatus.needsInput);
      expect(ambiguous.message, contains('two.notes'));
      await ToolExecutor.execute(
        tool: 'open_app',
        arguments: {'app_name': 'two.notes'},
      );
      expect(calls.last.arguments, {'packageName': 'two.notes'});
    },
  );

  test('Unicode labels match without collapsing unrelated names', () {
    const apps = [
      InstalledApp(name: 'नोट्स', packageName: 'notes.hi'),
      InstalledApp(name: 'कैमरा', packageName: 'camera.hi'),
    ];
    expect(matchInstalledApps('नोट्स', apps).single.packageName, 'notes.hi');
    expect(matchInstalledApps('Unknown', apps), isEmpty);
  });

  test('speech spelling errors launch the actual installed packages', () async {
    apps = [
      {'name': 'Zepto', 'packageName': 'test.zepto'},
      {'name': 'Upstox: Stocks & Demat Account', 'packageName': 'test.upstox'},
      {'name': 'Healo', 'packageName': 'test.healo'},
      {'name': 'DigiLocker', 'packageName': 'test.digilocker'},
    ];
    for (final entry in {
      'septo': 'test.zepto',
      'Upstocks': 'test.upstox',
      'helo': 'test.healo',
      'DGLocker': 'test.digilocker',
      'D G Locker app': 'test.digilocker',
      'Zetpo': 'test.zepto',
    }.entries) {
      final announced = <String>[];
      final result = await ToolExecutor.execute(
        tool: 'open_app',
        arguments: {'app_name': entry.key},
        onBeforeAction: (message) async => announced.add(message),
      );
      expect(result.status, ToolExecutionStatus.completed, reason: entry.key);
      expect(calls.last.arguments, {'packageName': entry.value});
      expect(announced.single, result.message);
      expect(result.message, isNot(contains(entry.key)), reason: entry.key);
    }
  });

  test('similar speech matches ask which app without launching', () async {
    apps = [
      {'name': 'Healo', 'packageName': 'test.healo'},
      {'name': 'Halo', 'packageName': 'test.halo'},
    ];
    final result = await ToolExecutor.execute(
      tool: 'open_app',
      arguments: {'app_name': 'helo'},
    );
    expect(result.status, ToolExecutionStatus.needsInput);
    expect(result.message, contains('Healo'));
    expect(result.message, contains('Halo'));
    expect(calls.map((call) => call.method), ['getLaunchableApps']);
  });

  test('exact spellings win over corrected names', () {
    const apps = [
      InstalledApp(name: 'Helo', packageName: 'test.helo'),
      InstalledApp(name: 'Healo', packageName: 'test.healo'),
    ];
    expect(matchInstalledApps('helo', apps).single.packageName, 'test.helo');
  });

  test('unknown and very short names never launch the nearest app', () async {
    apps = [
      {'name': 'Zepto', 'packageName': 'test.zepto'},
    ];
    for (final query in ['xyz', 'Banana', 'Universe']) {
      calls.clear();
      final result = await ToolExecutor.execute(
        tool: 'open_app',
        arguments: {'app_name': query},
      );
      expect(result.status, ToolExecutionStatus.error, reason: query);
      expect(calls.map((call) => call.method), ['getLaunchableApps']);
    }
  });

  test('device results are spoken and use actual native state', () async {
    final result = await ToolExecutor.execute(
      tool: 'get_battery',
      arguments: {},
    );
    expect(result.message, 'Your battery is at 73 percent and charging.');
    expect(result.speakResult, isTrue);
  });

  test('missing access is an error, never a claimed success', () async {
    nativeResult = {
      'success': false,
      'message': 'Allow modify system settings, then try again.',
    };
    final result = await ToolExecutor.execute(
      tool: 'set_brightness',
      arguments: {'percent': 50},
    );
    expect(result.status, ToolExecutionStatus.error);
    expect(result.message, contains('Allow modify system settings'));
  });

  test(
    'torch rejects missing or non-boolean intent before calling native code',
    () async {
      final result = await ToolExecutor.execute(
        tool: 'set_torch',
        arguments: {'enabled': 'true'},
      );
      expect(result.status, ToolExecutionStatus.error);
      expect(calls, isEmpty);
    },
  );

  test(
    'standalone dismissal commands do not swallow sleep advice or alarms',
    () {
      for (final command in [
        'Sleep',
        'Exit!',
        'Please go to sleep',
        'Close the assistant please',
      ]) {
        expect(isSessionExitCommand(command), isTrue, reason: command);
      }
      for (final command in [
        'How can I sleep better?',
        'Set an alarm so I can sleep',
        'Open Sleep Cycle',
        'Do not exit',
      ]) {
        expect(isSessionExitCommand(command), isFalse, reason: command);
      }
    },
  );
}
