import 'dart:async';
import 'dart:convert';

import 'package:audio_stream_player/audio_stream_player.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'speech_text.dart';

/// Low-latency streaming TTS for the custom Groq provider.
///
/// The backend returns raw PCM16 mono audio at 24 kHz. Audio is fed to the
/// native player as each network chunk arrives, so playback no longer waits
/// for the complete MP3 file to be generated and downloaded.
class AgentTtsService {
  AgentTtsService({http.Client Function()? clientFactory})
    : _clientFactory = clientFactory ?? http.Client.new;
  final http.Client Function() _clientFactory;
  static const int _sampleRate = 24000;

  static const String backendUrl = String.fromEnvironment(
    'VOICE_AGENT_API_URL',
    defaultValue: 'https://voice-ai-agent-server.vercel.app',
  );

  AudioStreamPlayer? _player;
  http.Client? _activeClient;
  Completer<void>? _playbackCompleter;
  Duration _completionTimeout = const Duration(seconds: 45);

  int _playbackGeneration = 0;
  bool _speaking = false;
  bool _disposed = false;

  bool get isSpeaking => _speaking;

  /// Starts playback and returns as soon as the PCM player is ready.
  /// Network audio continues to be consumed in the background.
  Future<void> startSpeaking(String text) async {
    if (_disposed) return;
    final clean = SpeechText.clean(text);
    // Reserve the generation before awaiting the old player's disposal. A
    // slower previous start must never resume after a newer reply takes over.
    final stopping = stop();
    final generation = _playbackGeneration;
    await stopping;
    if (_disposed || generation != _playbackGeneration || clean.isEmpty) return;

    final parts = SpeechText.chunks(clean);
    final client = _clientFactory();
    final completion = Completer<void>();
    // Background streaming can fail before the caller starts waiting.
    unawaited(completion.future.catchError((Object _) {}));

    _activeClient = client;
    _playbackCompleter = completion;
    _speaking = true;
    _completionTimeout = SpeechText.completionTimeout(clean);

    try {
      final response = await _requestAudio(client, parts.first);

      if (generation != _playbackGeneration || _disposed) return;

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
        _consumeAudio(
          response,
          parts.skip(1),
          player,
          client,
          completion,
          generation,
        ),
      );
    } catch (error) {
      if (generation == _playbackGeneration) {
        await _finishPlayback(
          generation: generation,
          client: client,
          completion: completion,
          player: _player,
        );

        rethrow;
      }
    }
  }

  Future<http.StreamedResponse> _requestAudio(
    http.Client client,
    String text,
  ) async {
    final request = http.Request('POST', Uri.parse('$backendUrl/deepgram/tts'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(<String, String>{'text': text});
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      // Do not log reply content returned in a provider error body.
      throw Exception('TTS HTTP ${response.statusCode}');
    }
    final encoding = response.headers['x-audio-encoding']?.toLowerCase();
    final type = response.headers['content-type']?.toLowerCase() ?? '';
    if (encoding != 'linear16' && !type.contains('audio/l16')) {
      throw Exception('The backend did not return streaming PCM audio.');
    }
    return response;
  }

  Future<void> _consumeAudio(
    http.StreamedResponse response,
    Iterable<String> remaining,
    AudioStreamPlayer player,
    http.Client client,
    Completer<void> completion,
    int generation,
  ) async {
    Object? playbackError;
    try {
      var current = response;
      final nextParts = remaining.iterator;
      while (true) {
        await for (final chunk in current.stream.timeout(
          const Duration(seconds: 30),
        )) {
          if (generation != _playbackGeneration || _disposed) return;
          if (chunk.isNotEmpty) await player.feed(Uint8List.fromList(chunk));
        }
        if (generation != _playbackGeneration ||
            _disposed ||
            !nextParts.moveNext()) {
          break;
        }
        current = await _requestAudio(client, nextParts.current);
      }

      if (generation == _playbackGeneration && !_disposed) {
        await player.endOfStream();
      }
    } catch (error) {
      if (generation == _playbackGeneration && !_disposed) {
        playbackError = error;
        debugPrint('Streaming TTS error: $error');
      }
    } finally {
      await _finishPlayback(
        generation: generation,
        client: client,
        player: player,
        completion: completion,
        error: playbackError,
      );
    }
  }

  /// Speaks the complete response and resolves after its last sample plays.
  Future<void> speakAndWait(String text) async {
    final starting = startSpeaking(text);
    final generation = _playbackGeneration;
    await starting;
    if (generation != _playbackGeneration) return;
    await waitUntilFinished();
  }

  /// Resolves when the current streamed utterance drains or is cancelled.
  Future<void> waitUntilFinished() async {
    final completion = _playbackCompleter;
    if (completion == null) return;
    final generation = _playbackGeneration;
    final timeout = _completionTimeout;

    try {
      await completion.future.timeout(timeout);
    } on TimeoutException {
      debugPrint('Streaming TTS completion timeout');
      if (generation == _playbackGeneration) await stop();
      rethrow;
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
    Object? error,
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

      // Keep the completed future available to speakAndWait even when a very
      // short stream finishes before startSpeaking returns.
    }

    if (player != null) {
      try {
        await player.dispose();
      } catch (_) {}
    }

    if (!completion.isCompleted) {
      if (error == null) {
        completion.complete();
      } else {
        completion.completeError(error);
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await stop();
  }
}
