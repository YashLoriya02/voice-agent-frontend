import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frontend/voice_agent/services/agent_tts_service.dart';
import 'package:frontend/voice_agent/services/speech_text.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('audio_stream_player/methods');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final playerIds = <int>[];
  Completer<void>? blockedStop;
  var endOfStreamCalls = 0;

  Future<void> drain(int id) async {
    // Deliver the native player's real completion event, rather than treating
    // synthesis EOF as if the speaker had already played all buffered samples.
    await messenger.handlePlatformMessage(
      'audio_stream_player/events/$id',
      const StandardMethodCodec().encodeSuccessEnvelope({'event': 'drained'}),
      (_) {},
    );
  }

  Future<void> flush() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  http.Response audio() => http.Response.bytes(
    [0, 0, 0, 0],
    200,
    headers: {'x-audio-encoding': 'linear16'},
  );

  setUp(() {
    playerIds.clear();
    blockedStop = null;
    endOfStreamCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final id = call.arguments['playerId'] as int;
      if (call.method == 'create') {
        playerIds.add(id);
        messenger.setMockMethodCallHandler(
          MethodChannel('audio_stream_player/events/$id'),
          (_) async => null,
        );
      }
      if (call.method == 'endOfStream') endOfStreamCalls++;
      if (call.method == 'stop' && blockedStop != null) {
        await blockedStop!.future;
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    for (final id in playerIds) {
      messenger.setMockMethodCallHandler(
        MethodChannel('audio_stream_player/events/$id'),
        null,
      );
    }
  });

  test(
    'long formatted replies use bounded requests and wait beyond 30 seconds for playback',
    () async {
      final requests = <String>[];
      final text = '**${List.generate(500, (i) => 'word$i').join(' ')}** 🍽️';
      final tts = AgentTtsService(
        clientFactory: () => MockClient((request) async {
          requests.add(jsonDecode(request.body)['text'] as String);
          return audio();
        }),
      );
      await tts.startSpeaking(text);
      await flush();
      expect(requests.length, greaterThan(1));
      expect(requests.every((text) => text.length <= 1750), isTrue);
      expect(requests.join(' '), SpeechText.clean(text));
      expect(playerIds.length, 1);
      expect(endOfStreamCalls, 1);
      var complete = false;
      final finished = tts.waitUntilFinished().then((_) => complete = true);
      expect(SpeechText.completionTimeout(SpeechText.clean(text)).inSeconds, greaterThan(35));
      await flush();
      expect(tts.isSpeaking, isTrue);
      expect(complete, isFalse);
      await drain(playerIds.single);
      await flush();
      await finished;
      expect(complete, isTrue);
      expect(tts.isSpeaking, isFalse);
      await tts.dispose();
    },
  );

  test(
    'the newest device confirmation wins over an older delayed speech start',
    () async {
      final requests = <String>[];
      final tts = AgentTtsService(
        clientFactory: () => MockClient((request) async {
          requests.add(jsonDecode(request.body)['text'] as String);
          return audio();
        }),
      );
      await tts.startSpeaking('Previous answer.');
      await flush();
      blockedStop = Completer<void>();
      final older = tts.startSpeaking('Old brightness result.');
      await flush();
      await tts.startSpeaking('Media volume set to 50 percent.');
      await flush();
      blockedStop!.complete();
      blockedStop = null;
      await older;
      await flush();
      expect(requests, ['Previous answer.', 'Media volume set to 50 percent.']);
      expect(tts.isSpeaking, isTrue);
      await drain(playerIds.last);
      await flush();
      await tts.dispose();
    },
  );

  test(
    'a failed later synthesis chunk is reported instead of silently finishing',
    () async {
      var requests = 0;
      final tts = AgentTtsService(
        clientFactory: () => MockClient((_) async {
          requests++;
          return requests == 1 ? audio() : http.Response('failed', 503);
        }),
      );
      await tts.startSpeaking(List.filled(700, 'word').join(' '));
      await flush();
      expect(requests, 2);
      await expectLater(tts.waitUntilFinished(), throwsException);
      expect(tts.isSpeaking, isFalse);
      expect(endOfStreamCalls, 0);
      await tts.dispose();
    },
  );
}
