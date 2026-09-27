import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:record/record.dart';

class DeepgramService {
  final AudioRecorder _recorder = AudioRecorder();

  WebSocket? _socket;

  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription? _socketSubscription;

  final StreamController<String> _transcriptController =
      StreamController<String>.broadcast();

  final StreamController<String> _finalTranscriptController =
      StreamController<String>.broadcast();

  final StreamController<String> _statusController =
      StreamController<String>.broadcast();

  Stream<String> get transcriptStream => _transcriptController.stream;

  Stream<String> get finalTranscriptStream => _finalTranscriptController.stream;

  Stream<String> get statusStream => _statusController.stream;

  bool _isListening = false;
  bool _isStarting = false;
  bool _turnEnded = false;
  bool _finalTranscriptEmitted = false;

  int _sessionId = 0;

  Future<void> _cleanupFuture = Future<void>.value();

  Completer<void>? _endTurnCompleter;

  bool get isListening => _isListening;

  static const String backendUrl = String.fromEnvironment(
    'VOICE_AGENT_API_URL',
    defaultValue: 'https://voice-ai-agent-server.vercel.app',
  );

  /// 80 ms PCM16 @ 16 kHz mono
  static const int _chunkSize = 2560;

  final List<int> _audioBuffer = [];

  // ============================================================
  // START
  // ============================================================

  Future<void> startListening() async {
    await _cleanupFuture;

    if (_isListening || _isStarting) {
      return;
    }

    _isStarting = true;

    final currentSession = ++_sessionId;

    _turnEnded = false;
    _finalTranscriptEmitted = false;

    _endTurnCompleter = Completer<void>();

    _audioBuffer.clear();

    try {
      final permission = await _recorder.hasPermission();

      if (!permission) {
        throw Exception('Microphone permission denied');
      }

      if (currentSession != _sessionId) {
        return;
      }

      // ==================================================
      // START RECORDING FIRST
      // ==================================================

      final audioStream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,

          sampleRate: 16000,

          numChannels: 1,
        ),
      );

      if (currentSession != _sessionId) {
        try {
          await _recorder.stop();
        } catch (_) {}

        return;
      }

      _isListening = true;

      _statusController.add('Microphone active');

      _audioSubscription = audioStream.listen(
        (data) {
          _handleAudioChunk(data, currentSession);
        },

        onError: (error) {
          _statusController.add('Microphone error: $error');
        },
      );

      // ==================================================
      // CONNECT DEEPGRAM WHILE AUDIO IS ALREADY BUFFERING
      // ==================================================

      final token = await _getTemporaryToken();

      if (currentSession != _sessionId) {
        return;
      }

      final socket = await WebSocket.connect(
        _buildDeepgramUrl(),

        headers: {'Authorization': 'Bearer $token'},
      );

      if (currentSession != _sessionId) {
        await socket.close();

        return;
      }

      _socket = socket;

      _socketSubscription = socket.listen(
        (message) {
          _handleDeepgramMessage(message, currentSession);
        },

        onError: (error) {
          if (currentSession == _sessionId) {
            _statusController.add('Deepgram error: $error');
          }
        },
      );

      // ==================================================
      // NOW SEND EVERYTHING THE USER ALREADY SAID
      // ==================================================

      _flushAudioBuffer(currentSession);

      _statusController.add('Listening...');
    } catch (e) {
      _cleanupFuture = _cleanupSession(currentSession);

      await _cleanupFuture;

      rethrow;
    } finally {
      _isStarting = false;
    }
  }

  String _buildDeepgramUrl() {
    return 'wss://api.in.deepgram.com'
        '/v2/listen'
        '?model=flux-general-en'
        '&encoding=linear16'
        '&sample_rate=16000'
        // Faster end-of-turn detection.
        '&eot_threshold=0.60'
        '&eot_timeout_ms=900'
        // Nice for alarms/timers.
        '&numerals=true';
  }

  // ============================================================
  // AUDIO
  // ============================================================

  static const int _maxPreconnectBufferBytes = 96000;

  /// ~3 sec PCM16 @ 16kHz mono.

  void _handleAudioChunk(Uint8List data, int sessionId) {
    if (sessionId != _sessionId || !_isListening) {
      return;
    }

    /*
   * ALWAYS buffer the microphone.
   *
   * Even when Deepgram isn't connected yet.
   */
    _audioBuffer.addAll(data);

    /*
   * Prevent runaway buffering if network
   * connection is unusually slow.
   *
   * Keep roughly the last 3 seconds.
   */
    if (_socket == null && _audioBuffer.length > _maxPreconnectBufferBytes) {
      final excess = _audioBuffer.length - _maxPreconnectBufferBytes;

      _audioBuffer.removeRange(0, excess);
    }

    if (_socket != null) {
      _flushAudioBuffer(sessionId);
    }
  }

  void _flushAudioBuffer(int sessionId) {
    if (sessionId != _sessionId || _socket == null) {
      return;
    }

    while (_audioBuffer.length >= _chunkSize) {
      final chunk = Uint8List.fromList(_audioBuffer.sublist(0, _chunkSize));

      _audioBuffer.removeRange(0, _chunkSize);

      try {
        _socket?.add(chunk);
      } catch (_) {
        return;
      }
    }
  }

  // ============================================================
  // DEEPGRAM EVENTS
  // ============================================================

  void _handleDeepgramMessage(dynamic message, int sessionId) {
    if (sessionId != _sessionId || message is! String) {
      return;
    }

    try {
      final data = jsonDecode(message);

      final type = data['type']?.toString();

      if (type == 'Connected') {
        _statusController.add('Connected');

        return;
      }

      if (type == 'Error') {
        _statusController.add(
          'Deepgram error: '
          '${data['description']}',
        );

        return;
      }

      if (type != 'TurnInfo') {
        return;
      }

      final event = data['event']?.toString();

      final transcript = data['transcript']?.toString().trim() ?? '';

      if (transcript.isNotEmpty &&
          (event == 'Update' ||
              event == 'EagerEndOfTurn' ||
              event == 'TurnResumed')) {
        _transcriptController.add(transcript);
      }

      if (event == 'EndOfTurn' && !_turnEnded) {
        _turnEnded = true;

        /*
         * Don't execute directly inside
         * the WebSocket listener.
         */
        unawaited(_completeTurn(transcript, sessionId));
      }
    } catch (e) {
      _statusController.add('Parse error: $e');
    }
  }

  // ============================================================
  // TURN COMPLETE
  // ============================================================

  Future<void> _completeTurn(String transcript, int sessionId) async {
    if (sessionId != _sessionId) {
      return;
    }

    /*
     * Release microphone FIRST.
     *
     * This is also important for TTS:
     * Android should not still think
     * we're recording when the agent
     * starts speaking.
     */
    _isListening = false;

    final audioSubscription = _audioSubscription;

    _audioSubscription = null;

    try {
      await audioSubscription?.cancel();
    } catch (_) {}

    try {
      await _recorder.stop();
    } catch (_) {}

    if (sessionId != _sessionId) {
      return;
    }

    if (transcript.isNotEmpty) {
      _finalTranscriptEmitted = true;

      _transcriptController.add(transcript);

      _finalTranscriptController.add(transcript);
    }

    _statusController.add('Speech complete');

    if (_endTurnCompleter != null && !_endTurnCompleter!.isCompleted) {
      _endTurnCompleter!.complete();
    }

    /*
     * Close THIS session only.
     *
     * New startListening() waits for this
     * future before opening another one.
     */
    _cleanupFuture = _cleanupSocket(sessionId);
  }

  // ============================================================
  // MANUAL STOP
  // ============================================================

  Future<bool> stopListening() async {
    if (!_isListening && _isStarting) {
      await cancelListening();
      return false;
    }

    if (!_isListening) {
      return false;
    }

    final currentSession = _sessionId;

    _statusController.add('Finishing...');

    _isListening = false;

    final audioSubscription = _audioSubscription;

    _audioSubscription = null;

    try {
      await audioSubscription?.cancel();
    } catch (_) {}

    try {
      await _recorder.stop();
    } catch (_) {}

    /*
     * Tell Flux:
     * user intentionally finished.
     */
    try {
      _socket?.add(jsonEncode({'type': 'ForceEndTurn'}));
    } catch (_) {}

    /*
     * Wait briefly for Deepgram to
     * send the final EndOfTurn.
     */
    try {
      await _endTurnCompleter?.future.timeout(
        const Duration(milliseconds: 1200),
      );

      return _finalTranscriptEmitted;
    } catch (_) {
      /*
       * Deepgram didn't return final turn.
       * Ensure session still closes.
       */
      if (currentSession == _sessionId) {
        _cleanupFuture = _cleanupSocket(currentSession);

        await _cleanupFuture;
      }

      return false;
    }
  }

  /// Immediately abandons the current STT turn without producing a command.
  ///
  /// This is used when the user cancels or changes providers. It deliberately
  /// does not send ForceEndTurn, because a late final transcript must not start
  /// a Groq request after the UI has already stopped or switched engines.
  Future<void> cancelListening() async {
    final socket = _socket;
    final socketSubscription = _socketSubscription;
    final audioSubscription = _audioSubscription;

    // Invalidate token/WebSocket callbacks from the old turn first.
    _sessionId++;
    _isListening = false;
    _turnEnded = true;

    _socket = null;
    _socketSubscription = null;
    _audioSubscription = null;
    _audioBuffer.clear();

    final endTurnCompleter = _endTurnCompleter;
    _endTurnCompleter = null;
    if (endTurnCompleter != null && !endTurnCompleter.isCompleted) {
      endTurnCompleter.complete();
    }

    try {
      await audioSubscription?.cancel();
    } catch (_) {}

    try {
      await _recorder.stop();
    } catch (_) {}

    try {
      socket?.add(jsonEncode({'type': 'CloseStream'}));
    } catch (_) {}

    try {
      await socketSubscription?.cancel();
    } catch (_) {}

    try {
      await socket?.close();
    } catch (_) {}

    _statusController.add('Listening cancelled');
  }

  // ============================================================
  // CLEANUP
  // ============================================================

  Future<void> _cleanupSocket(int sessionId) async {
    if (sessionId != _sessionId) {
      return;
    }

    final socket = _socket;

    final socketSubscription = _socketSubscription;

    /*
     * Detach the old objects immediately.
     *
     * This is what prevents old cleanup
     * from touching the NEXT socket.
     */
    _socket = null;
    _socketSubscription = null;

    _audioBuffer.clear();

    try {
      socket?.add(jsonEncode({'type': 'CloseStream'}));
    } catch (_) {}

    try {
      await socketSubscription?.cancel();
    } catch (_) {}

    try {
      await socket?.close();
    } catch (_) {}
  }

  Future<void> _cleanupSession(int sessionId) async {
    _isListening = false;

    final audioSubscription = _audioSubscription;

    _audioSubscription = null;

    try {
      await audioSubscription?.cancel();
    } catch (_) {}

    try {
      await _recorder.stop();
    } catch (_) {}

    await _cleanupSocket(sessionId);
  }

  // ============================================================
  // TOKEN
  // ============================================================

  Future<String> _getTemporaryToken() async {
    final response = await http
        .get(Uri.parse('$backendUrl/deepgram/token'))
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception('Unable to get Deepgram token');
    }

    final data = jsonDecode(response.body);

    final token = data['accessToken']?.toString();

    if (token == null || token.isEmpty) {
      throw Exception('Invalid Deepgram token');
    }

    return token;
  }

  // ============================================================
  // DISPOSE
  // ============================================================

  Future<void> dispose() async {
    /*
     * Invalidates any running callbacks.
     */
    _sessionId++;

    _isListening = false;

    try {
      await _audioSubscription?.cancel();
    } catch (_) {}

    try {
      await _recorder.stop();
    } catch (_) {}

    try {
      await _socketSubscription?.cancel();
    } catch (_) {}

    try {
      await _socket?.close();
    } catch (_) {}

    await _recorder.dispose();

    await _transcriptController.close();

    await _finalTranscriptController.close();

    await _statusController.close();
  }
}
