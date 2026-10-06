import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audio_stream_player/audio_stream_player.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Low-latency streaming TTS for the custom Groq provider.
///
/// The backend returns raw PCM16 mono audio at 24 kHz. Audio is fed to the
/// native player as each network chunk arrives, so playback no longer waits
/// for the complete MP3 file to be generated and downloaded.
class AgentTtsService {
  static const int _sampleRate = 24000;

  static const String backendUrl = String.fromEnvironment(
    'VOICE_AGENT_API_URL',
    defaultValue: 'https://voice-ai-agent-server.vercel.app',
  );

  AudioStreamPlayer? _player;
  http.Client? _activeClient;
  Completer<void>? _playbackCompleter;

  int _playbackGeneration = 0;
  bool _speaking = false;
  bool _disposed = false;

  bool get isSpeaking => _speaking;

  /// Starts playback and returns as soon as the PCM player is ready.
  /// Network audio continues to be consumed in the background.
  Future<void> startSpeaking(String text) async {
    final clean = text.trim();
    if (clean.isEmpty || _disposed) return;

    await stop();

    if (_disposed) return;

    final generation = ++_playbackGeneration;
    final client = http.Client();
    final completion = Completer<void>();

    _activeClient = client;
    _playbackCompleter = completion;
    _speaking = true;

    try {
      final request =
          http.Request('POST', Uri.parse('$backendUrl/deepgram/tts'))
            ..headers['Content-Type'] = 'application/json'
            ..body = jsonEncode(<String, String>{'text': clean});

      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 10));

      if (generation != _playbackGeneration || _disposed) return;

      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        throw Exception('TTS HTTP ${response.statusCode}: $errorBody');
      }

      final encoding = response.headers['x-audio-encoding']?.toLowerCase();
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';

      if (encoding != 'linear16' && !contentType.contains('audio/l16')) {
        client.close();
        throw Exception(
          'The backend returned non-streaming TTS audio. Deploy the updated '
          'backend before this Flutter build.',
        );
      }

      final player = await AudioStreamPlayer.create(
        sampleRate: _sampleRate,
        channels: 1,
        format: PcmFormat.s16le,
      );

      if (generation != _playbackGeneration || _disposed) {
        await player.dispose();
        return;
      }

      _player = player;

      // The package supports play-before-feed and begins output as soon as
      // the first PCM chunk arrives.
      await player.play();

      debugPrint('Streaming TTS playback started');

      unawaited(
        _consumeAudio(response.stream, player, client, completion, generation),
      );
    } catch (error) {
      if (generation == _playbackGeneration) {
        await _finishPlayback(
          generation: generation,
          client: client,
          completion: completion,
        );

        rethrow;
      }
    }
  }

  Future<void> _consumeAudio(
    Stream<List<int>> stream,
    AudioStreamPlayer player,
    http.Client client,
    Completer<void> completion,
    int generation,
  ) async {
    try {
      await for (final chunk in stream) {
        if (generation != _playbackGeneration || _disposed) return;
        if (chunk.isEmpty) continue;

        await player.feed(Uint8List.fromList(chunk));
      }

      if (generation == _playbackGeneration && !_disposed) {
        await player.endOfStream();
      }
    } catch (error) {
      if (generation == _playbackGeneration && !_disposed) {
        debugPrint('Streaming TTS error: $error');
      }
    } finally {
      await _finishPlayback(
        generation: generation,
        client: client,
        player: player,
        completion: completion,
      );
    }
  }

  /// Speaks the complete response and resolves after its last sample plays.
  Future<void> speakAndWait(String text) async {
    await startSpeaking(text);

    await waitUntilFinished();
  }

  /// Resolves when the current streamed utterance drains or is cancelled.
  Future<void> waitUntilFinished() async {
    final completion = _playbackCompleter;
    if (completion == null) return;

    try {
      await completion.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      debugPrint('Streaming TTS completion timeout');
      await stop();
    }
  }

  Future<void> stop() async {
    _playbackGeneration++;
    _speaking = false;

    final client = _activeClient;
    final player = _player;
    final completion = _playbackCompleter;

    _activeClient = null;
    _player = null;
    _playbackCompleter = null;

    client?.close();

    try {
      await player?.stop();
    } catch (_) {}

    try {
      await player?.dispose();
    } catch (_) {}

    if (completion != null && !completion.isCompleted) {
      completion.complete();
    }
  }

  Future<void> _finishPlayback({
    required int generation,
    required http.Client client,
    required Completer<void> completion,
    AudioStreamPlayer? player,
  }) async {
    client.close();

    if (generation == _playbackGeneration) {
      _speaking = false;

      if (identical(_activeClient, client)) {
        _activeClient = null;
      }

      if (player != null && identical(_player, player)) {
        _player = null;
      }

      if (identical(_playbackCompleter, completion)) {
        _playbackCompleter = null;
      }
    }

    if (player != null) {
      try {
        await player.dispose();
      } catch (_) {}
    }

    if (!completion.isCompleted) {
      completion.complete();
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
  }
}
