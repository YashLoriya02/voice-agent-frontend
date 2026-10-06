import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_stream_player/audio_stream_player.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';

import '../models/tool_execution_result.dart';
import '../tools/tool_executor.dart';
import '../models/message_readout.dart';
import '../tools/message_commands.dart';
import '../tools/notification_agent_result.dart';
import 'message_notification_service.dart';
import '../tools/device_tool_definitions.dart';

enum DeepgramVoiceAgentState {
  disconnected,
  connecting,
  configuring,
  ready,
  listening,
  thinking,
  executing,
  speaking,
  error,
}

class DeepgramVoiceAgentTranscript {
  final String role;
  final String content;

  const DeepgramVoiceAgentTranscript({
    required this.role,
    required this.content,
  });

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';

  @override
  String toString() => '$role: $content';
}

typedef DeepgramAgentStateCallback = void Function(
  DeepgramVoiceAgentState state,
);
typedef DeepgramAgentTranscriptCallback = void Function(
  DeepgramVoiceAgentTranscript transcript,
);
typedef DeepgramAgentStatusCallback = void Function(String message);
typedef DeepgramAgentErrorCallback = void Function(
  String code,
  String description,
);
typedef DeepgramAgentLatencyCallback = void Function(
  Map<String, dynamic> latency,
);
typedef DeepgramAgentFunctionCallback = void Function(
  String functionName,
  Map<String, dynamic> arguments,
);
typedef DeepgramAgentAudioStartedCallback = void Function();
typedef DeepgramAgentAudioDoneCallback = void Function(bool receivedAudio);

/// Persistent Deepgram Voice Agent connection.
///
/// Responsibilities:
/// - obtains a short-lived token from your backend
/// - keeps one Voice Agent WebSocket alive across turns
/// - streams PCM16 mono microphone audio at 16 kHz
/// - plays Deepgram's raw PCM16 mono response at 24 kHz as chunks arrive
/// - exposes state/transcript callbacks
/// - handles client-side phone functions through ToolExecutor
/// - supports ForceEndTurn and local audio interruption/barge-in
class DeepgramVoiceAgentService {
  DeepgramVoiceAgentService({
    required this.backendUrl,
    this.greeting,
    this.systemPrompt = _defaultSystemPrompt,
    this.onStateChanged,
    this.onTranscript,
    this.onStatus,
    this.onError,
    this.onLatencyReport,
    this.onFunctionCall,
    this.onAgentAudioStarted,
    this.onAgentAudioDone,
    this.onSessionEndRequested,
    this.onLocalReadout,
    this.onLocalReadoutFinished,
  });

  final String backendUrl;
  final String? greeting;
  final String systemPrompt;

  final DeepgramAgentStateCallback? onStateChanged;
  final DeepgramAgentTranscriptCallback? onTranscript;
  final DeepgramAgentStatusCallback? onStatus;
  final DeepgramAgentErrorCallback? onError;
  final DeepgramAgentLatencyCallback? onLatencyReport;
  final DeepgramAgentFunctionCallback? onFunctionCall;
  final DeepgramAgentAudioStartedCallback? onAgentAudioStarted;
  final DeepgramAgentAudioDoneCallback? onAgentAudioDone;
  final Future<void> Function()? onSessionEndRequested;
  final void Function(MessageReadout)? onLocalReadout;
  final void Function()? onLocalReadoutFinished;
  String _lastUserCommand = '';

  static const int inputSampleRate = 16000;
  static const int outputSampleRate = 24000;
  static const int _maxPreconnectAudioBytes = 96000; // ~3 sec PCM16 @ 16kHz

  static const String _agentUrl = 'wss://api.in.deepgram.com/v1/agent/converse';

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _microphoneSubscription;
  final List<int> _preconnectAudio = <int>[];
  bool _microphoneRunning = false;
  bool _microphoneMuted = false;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _keepAliveTimer;
  Completer<void>? _settingsAppliedCompleter;
  bool _settingsApplied = false;
  bool _connecting = false;
  bool _disconnecting = false;
  bool _disposed = false;
  int _connectionGeneration = 0;
  String? _requestId;

  AudioStreamPlayer? _player;
  bool _playerStarted = false;
  bool _dropCurrentAgentAudio = false;
  int _playbackEpoch = 0;
  Future<void> _audioChain = Future<void>.value();
  int _agentAudioBytesThisTurn = 0;

  final Set<String> _cancelledFunctionIds = <String>{};
  final Set<String> _activeFunctionIds = <String>{};

  DeepgramVoiceAgentState _state = DeepgramVoiceAgentState.disconnected;

  final StreamController<DeepgramVoiceAgentState> _stateController =
      StreamController<DeepgramVoiceAgentState>.broadcast();
  final StreamController<DeepgramVoiceAgentTranscript> _transcriptController =
      StreamController<DeepgramVoiceAgentTranscript>.broadcast();
  final StreamController<String> _statusController =
      StreamController<String>.broadcast();

  DeepgramVoiceAgentState get state => _state;
  bool get isConnected => _socket != null && _settingsApplied;
  bool get isListening => _microphoneRunning;
  bool get isMicrophoneMuted => _microphoneMuted;
  bool get isSpeaking => _state == DeepgramVoiceAgentState.speaking;
  String? get requestId => _requestId;

  Stream<DeepgramVoiceAgentState> get stateStream => _stateController.stream;
  Stream<DeepgramVoiceAgentTranscript> get transcriptStream =>
      _transcriptController.stream;
  Stream<String> get statusStream => _statusController.stream;

  /// Connects once and keeps the session alive.
  ///
  /// When [startMicrophone] is true we begin capturing immediately and buffer
  /// the first audio locally while token + WebSocket + Settings are prepared.
  /// This prevents the first word from being clipped on a slow connection.
  Future<void> connect({bool startMicrophone = true}) async {
    _ensureNotDisposed();

    if (isConnected) {
      if (startMicrophone && !_microphoneRunning) {
        await startListening();
      }
      return;
    }

    if (_connecting) {
      final pending = _settingsAppliedCompleter;
      if (pending != null) {
        await pending.future;
      }
      if (startMicrophone && !_microphoneRunning) {
        await startListening();
      }
      return;
    }

    _connecting = true;
    _disconnecting = false;
    final connectionGeneration = ++_connectionGeneration;
    _settingsApplied = false;
    _requestId = null;
    _cancelledFunctionIds.clear();
    _activeFunctionIds.clear();
    _settingsAppliedCompleter = Completer<void>();

    _setState(DeepgramVoiceAgentState.connecting);
    _emitStatus('Connecting to Deepgram Voice Agent...');

    try {
      await _ensurePlayer();

      if (connectionGeneration != _connectionGeneration) return;

      if (startMicrophone && !_microphoneRunning) {
        await _startMicrophoneCapture(bufferUntilReady: true);
      }

      if (connectionGeneration != _connectionGeneration) return;

      final token = await _getTemporaryToken();
      _ensureNotDisposed();

      if (connectionGeneration != _connectionGeneration) return;

      final socket = await WebSocket.connect(
        _agentUrl,
        headers: <String, dynamic>{'Authorization': 'Bearer $token'},
      );

      if (_disposed || connectionGeneration != _connectionGeneration) {
        await socket.close();
        return;
      }

      _socket = socket;
      _socketSubscription = socket.listen(
        _handleSocketMessage,
        onError: _handleSocketError,
        onDone: _handleSocketClosed,
        cancelOnError: false,
      );

      await _settingsAppliedCompleter!.future.timeout(
        const Duration(seconds: 15),
      );

      if (connectionGeneration != _connectionGeneration) return;

      _startKeepAliveTimer();
      _flushPreconnectAudio();

      if (_microphoneRunning) {
        _setState(DeepgramVoiceAgentState.listening);
      } else {
        _setState(DeepgramVoiceAgentState.ready);
      }
    } catch (error) {
      if (connectionGeneration != _connectionGeneration) {
        return;
      }

      if (_state != DeepgramVoiceAgentState.error) {
        _emitError('CONNECTION_FAILED', error.toString());
        _setState(DeepgramVoiceAgentState.error);
      }
      await _cleanupConnection(preserveErrorState: true);
      rethrow;
    } finally {
      if (connectionGeneration == _connectionGeneration) {
        _connecting = false;
      }
    }
  }

  void _sendSettings() {
    if (_socket == null) return;

    _setState(DeepgramVoiceAgentState.configuring);

    final settings = <String, dynamic>{
      'type': 'Settings',
      'flags': <String, dynamic>{'history': true},
      'audio': <String, dynamic>{
        'input': <String, dynamic>{
          'encoding': 'linear16',
          'sample_rate': inputSampleRate,
        },
        'output': <String, dynamic>{
          'encoding': 'linear16',
          'sample_rate': outputSampleRate,
          'container': 'none',
        },
      },
      'agent': <String, dynamic>{
        'listen': <String, dynamic>{
          'provider': <String, dynamic>{
            'type': 'deepgram',
            'model': 'flux-general-en',
            'version': 'v2',
            'keyterms': <String>[
              'YouTube',
              'Spotify',
              'WhatsApp',
              'Chrome',
              'Google Maps',
              'alarm',
              'timer',
            ],
            'eot_threshold': 0.72,
            'eager_eot_threshold': 0.50,
            'eot_timeout_ms': 1200,
          },
        },
        'think': <String, dynamic>{
          'provider': <String, dynamic>{
            'type': 'anthropic',
            'model': 'claude-sonnet-4-6',
            'temperature': 0.3,
          },
          'prompt': systemPrompt,
          'functions': _functionDefinitions,
        },
        'speak': <String, dynamic>{
          'provider': <String, dynamic>{
            'type': 'deepgram',
            'version': 'v2',
            // Use a currently supported Flux v2 voice. An unknown voice can
            // still produce ConversationText while yielding no binary audio.
            'model': 'flux-kit-en',
            'speed': 1.05,
          },
        },
        if (greeting != null && greeting!.trim().isNotEmpty)
          'greeting': greeting!.trim(),
      },
    };

    if (kDebugMode) {
      debugPrint(
        'DEEPGRAM SETTINGS:\n'
        '${const JsonEncoder.withIndent('  ').convert(settings)}',
      );
    }

    _sendJson(settings);
    _emitStatus('Voice Agent settings sent');
  }

  static const List<Map<String, dynamic>> _functionDefinitions =
      <Map<String, dynamic>>[
        ...deviceToolDefinitions,
        <String, dynamic>{
          'name': 'call_contact',
          'description': 'Call, ring, phone, or dial a contact saved on the user\'s Android phone.',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'name': <String, dynamic>{
                'type': 'string',
                'description': 'The contact name to call.',
              },
            },
            'required': <String>['name'],
          },
          'defer_until_eot': true,
        },
        <String, dynamic>{
          'name': 'set_alarm',
          'description': 'Set an alarm on the user\'s Android phone.',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'hour': <String, dynamic>{
                'type': 'integer',
                'description': 'Hour in 24-hour time, from 0 to 23.',
              },
              'minute': <String, dynamic>{
                'type': 'integer',
                'description': 'Minute from 0 to 59.',
              },
              'label': <String, dynamic>{
                'type': 'string',
                'description': 'Optional alarm label.',
              },
            },
            'required': <String>['hour', 'minute'],
          },
          'defer_until_eot': true,
        },
        <String, dynamic>{
          'name': 'send_message',
          'description': 'Prepare a WhatsApp or Android Messages message for a saved phone contact. The user reviews and taps Send. If the user did not specify WhatsApp or Messages, ask them before calling this function.',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'name': <String, dynamic>{
                'type': 'string',
                'description': 'The saved contact name.',
              },
              'message': <String, dynamic>{
                'type': 'string',
                'description': 'Exact message text requested by the user.',
              },
              'channel': <String, dynamic>{
                'type': 'string',
                'enum': <String>['whatsapp', 'messages'],
              },
            },
            'required': <String>['name', 'message', 'channel'],
          },
          'defer_until_eot': true,
        },
        <String, dynamic>{
          'name': 'set_timer',
          'description':
              'Start a countdown timer on the user\'s Android phone.',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'seconds': <String, dynamic>{
                'type': 'integer',
                'description': 'Total timer duration in seconds.',
              },
              'label': <String, dynamic>{
                'type': 'string',
                'description': 'Optional timer label.',
              },
            },
            'required': <String>['seconds'],
          },
          'defer_until_eot': true,
        },
        <String, dynamic>{
          'name': 'open_app',
          'description':
              'Open an installed application on the user\'s Android phone.',
          'parameters': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'app_name': <String, dynamic>{
                'type': 'string',
                'description': 'Human-readable app name, for example AI Agent, YouTube, Spotify, Chrome, Maps, or WhatsApp.',
              },
            },
            'required': <String>['app_name'],
          },
          'defer_until_eot': true,
        },
      ];

  Future<void> startListening() async {
    _ensureNotDisposed();

    if (_microphoneRunning) return;
    if (!isConnected) {
      throw StateError('Deepgram Voice Agent is not connected.');
    }

    await _startMicrophoneCapture(bufferUntilReady: false);
    _setState(DeepgramVoiceAgentState.listening);
  }

  Future<void> _startMicrophoneCapture({required bool bufferUntilReady}) async {
    if (_microphoneRunning) return;

    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      throw Exception('Microphone permission denied.');
    }

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: inputSampleRate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
        streamBufferSize: 2560,
      ),
    );

    _microphoneRunning = true;
    _emitStatus(
      bufferUntilReady ? 'Microphone buffering...' : 'Microphone active',
    );

    _microphoneSubscription = stream.listen(
      _handleMicrophoneAudio,
      onError: (Object error) {
        _emitError('MICROPHONE_ERROR', error.toString());
      },
      cancelOnError: false,
    );
  }

  void _handleMicrophoneAudio(Uint8List audio) {
    if (!_microphoneRunning || audio.isEmpty) return;

    // Keep the recorder warm, but never upload the assistant's own speaker
    // output as a new user turn. This intentionally makes playback
    // half-duplex; reliable barge-in requires platform AEC/headphones.
    if (_microphoneMuted) return;

    if (!_settingsApplied || _socket == null) {
      _preconnectAudio.addAll(audio);
      if (_preconnectAudio.length > _maxPreconnectAudioBytes) {
        final excess = _preconnectAudio.length - _maxPreconnectAudioBytes;
        _preconnectAudio.removeRange(0, excess);
      }
      return;
    }

    try {
      _socket!.add(audio);
    } catch (error) {
      debugPrint('Deepgram mic send failed: $error');
    }
  }

  void _flushPreconnectAudio() {
    if (_microphoneMuted) {
      _preconnectAudio.clear();
      return;
    }

    if (!_settingsApplied || _socket == null || _preconnectAudio.isEmpty) {
      return;
    }

    // Send in ~80 ms PCM chunks (16kHz * 2 bytes * .08 = 2560 bytes).
    const chunkBytes = 2560;
    var offset = 0;
    while (offset < _preconnectAudio.length) {
      final end = (offset + chunkBytes < _preconnectAudio.length)
          ? offset + chunkBytes
          : _preconnectAudio.length;
      _socket!.add(Uint8List.fromList(_preconnectAudio.sublist(offset, end)));
      offset = end;
    }
    _preconnectAudio.clear();
  }

  Future<void> stopListening() async {
    if (!_microphoneRunning) return;

    _microphoneRunning = false;
    try {
      await _microphoneSubscription?.cancel();
    } catch (_) {}
    _microphoneSubscription = null;

    try {
      await _recorder.stop();
    } catch (_) {}

    _preconnectAudio.clear();

    if (isConnected && _state != DeepgramVoiceAgentState.error) {
      _setState(DeepgramVoiceAgentState.ready);
    }
    _emitStatus('Microphone stopped');
  }

  Future<void> _ensurePlayer() async {
    if (_player != null) return;

    _player = await AudioStreamPlayer.create(
      sampleRate: outputSampleRate,
      channels: 1,
      format: PcmFormat.s16le,
    );

    debugPrint('PCM player ready ($outputSampleRate Hz)');
  }

  void setMicrophoneMuted(bool muted) {
    if (_microphoneMuted == muted) return;

    _microphoneMuted = muted;
    if (muted) {
      _preconnectAudio.clear();
    }

    _emitStatus(
      muted
          ? 'Microphone upload paused during agent speech'
          : 'Microphone upload resumed',
    );
  }

  void _handleAgentAudioChunk(Uint8List bytes) {
    if (bytes.isEmpty) return;

    // Normally AgentStartedSpeaking arrives first. If a fresh PCM frame wins
    // that race while we are THINKING, treat it as the start of the new reply.
    if (_dropCurrentAgentAudio && _state == DeepgramVoiceAgentState.thinking) {
      _playbackEpoch++;
      _dropCurrentAgentAudio = false;
      _playerStarted = false;
      _audioChain = Future<void>.value();
    }

    if (_dropCurrentAgentAudio) return;

    // A PCM frame can arrive before AgentStartedSpeaking. Do this only after
    // stale/interrupted frames have been rejected so they cannot re-mute the
    // user microphone after a barge-in.
    setMicrophoneMuted(true);

    final isFirstAudioChunk = _agentAudioBytesThisTurn == 0;
    _agentAudioBytesThisTurn += bytes.length;
    if (isFirstAudioChunk) {
      onAgentAudioStarted?.call();
      _emitStatus('Streaming agent audio');
    }

    if (_state != DeepgramVoiceAgentState.speaking) {
      _setState(DeepgramVoiceAgentState.speaking);
    }

    final epoch = _playbackEpoch;

    _audioChain = _audioChain
        .then((_) async {
          if (_dropCurrentAgentAudio || epoch != _playbackEpoch) return;

          final player = _player;
          if (player == null) return;

          if (!_playerStarted) {
            await player.play();
            if (_dropCurrentAgentAudio || epoch != _playbackEpoch) return;
            _playerStarted = true;
            debugPrint('STREAMING TTS STARTED');
          }

          await player.feed(bytes);
        })
        .catchError((Object error) {
          debugPrint('PCM PLAYBACK ERROR: $error');
        });
  }

  void _beginAgentUtterance(Map<String, dynamic> data) {
    setMicrophoneMuted(true);

    // A binary PCM frame can arrive just before AgentStartedSpeaking. In that
    // case _handleAgentAudioChunk has already started this utterance. Do not
    // reset the chain here or the first audible chunks can be discarded.
    if (_state != DeepgramVoiceAgentState.speaking || _dropCurrentAgentAudio) {
      _playbackEpoch++;
      _dropCurrentAgentAudio = false;
      _playerStarted = false;
      _audioChain = Future<void>.value();
    }

    _setState(DeepgramVoiceAgentState.speaking);
    _emitStatus('Agent speaking');

    debugPrint(
      'AgentStartedSpeaking total=${data['total_latency']} '
      'tts=${data['tts_latency']} ttt=${data['ttt_latency']}',
    );
  }

  Future<void> _finishAgentAudio() async {
    final epoch = _playbackEpoch;
    final receivedAudio = _agentAudioBytesThisTurn > 0;

    try {
      await _audioChain;
      if (_dropCurrentAgentAudio || epoch != _playbackEpoch) return;
      if (_playerStarted) {
        await _player?.endOfStream();
      }

      // Avoid uploading the short acoustic echo tail left by the speaker.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    } catch (error) {
      debugPrint('PCM drain error: $error');
    } finally {
      if (epoch == _playbackEpoch && !_dropCurrentAgentAudio) {
        _playerStarted = false;
        setMicrophoneMuted(false);
        if (_microphoneRunning) {
          _setState(DeepgramVoiceAgentState.listening);
        } else {
          _setState(DeepgramVoiceAgentState.ready);
        }
        onAgentAudioDone?.call(receivedAudio);
      }
    }
  }

  Future<void> _interruptAgentAudio() async {
    try {
      await MessageNotificationService.stopReadout();
    } catch (_) {}
    _playbackEpoch++;
    _dropCurrentAgentAudio = true;
    _playerStarted = false;
    _audioChain = Future<void>.value();

    try {
      await _player?.stop();
    } catch (error) {
      debugPrint('PCM stop error: $error');
    }
  }

  /// Finishes the current user utterance immediately.
  ///
  /// The microphone intentionally remains active, so after the agent replies
  /// the session returns to listening without another tap.
  Future<void> finishUserTurn() async {
    if (!isConnected) return;

    _sendJson(<String, dynamic>{'type': 'ForceEndTurn'});
    _setState(DeepgramVoiceAgentState.thinking);
    _emitStatus('Finishing user turn');
  }

  /// Stops the currently audible assistant response locally.
  /// The persistent Voice Agent session and microphone stay alive.
  Future<void> stopAgentSpeech() async {
    await _interruptAgentAudio();
    setMicrophoneMuted(false);

    if (_microphoneRunning) {
      _setState(DeepgramVoiceAgentState.listening);
    } else {
      _setState(DeepgramVoiceAgentState.ready);
    }
    _emitStatus('Agent speech stopped');
  }

  void _handleSocketMessage(dynamic message) {
    if (message is Uint8List) {
      _handleAgentAudioChunk(message);
      return;
    }

    if (message is List<int>) {
      _handleAgentAudioChunk(Uint8List.fromList(message));
      return;
    }

    if (message is! String) return;

    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, dynamic>) return;
      data = decoded;
    } catch (error) {
      debugPrint('Invalid Deepgram JSON: $error');
      return;
    }

    final type = data['type']?.toString();

    switch (type) {
      case 'Welcome':
        _requestId = data['request_id']?.toString();
        _emitStatus('Deepgram Voice Agent connected');
        _sendSettings();
        break;

      case 'SettingsApplied':
        _settingsApplied = true;
        _emitStatus('Voice Agent ready');
        if (_settingsAppliedCompleter != null &&
            !_settingsAppliedCompleter!.isCompleted) {
          _settingsAppliedCompleter!.complete();
        }
        _flushPreconnectAudio();
        if (_microphoneRunning) {
          _setState(DeepgramVoiceAgentState.listening);
        } else {
          _setState(DeepgramVoiceAgentState.ready);
        }
        break;

      case 'ConversationText':
        _handleConversationText(data);
        break;

      case 'UserStartedSpeaking':
        unawaited(_handleUserStartedSpeaking());
        break;

      case 'AgentThinking':
        _agentAudioBytesThisTurn = 0;
        _setState(DeepgramVoiceAgentState.thinking);
        _emitStatus('Agent thinking');
        break;

      case 'AgentStartedSpeaking':
        _beginAgentUtterance(data);
        break;

      case 'AgentAudioDone':
        unawaited(_finishAgentAudio());
        break;

      case 'FunctionCallRequest':
        unawaited(_handleFunctionCallRequest(data));
        break;

      case 'FunctionCallCancelled':
        _handleFunctionCallCancelled(data);
        break;

      case 'FunctionCallResponse':
        // Server-side function response; no local work needed.
        break;

      case 'LatencyReport':
        onLatencyReport?.call(data);
        break;

      case 'Warning':
        _emitStatus(
          'Warning: ${data['code'] ?? ''} ${data['description'] ?? ''}'.trim(),
        );
        break;

      case 'Error':
        _handleAgentError(data);
        break;

      case 'History':
      case 'ListenUpdated':
      case 'ThinkUpdated':
      case 'SpeakUpdated':
      case 'PromptUpdated':
        break;

      default:
        debugPrint('Deepgram Voice Agent event: $type');
    }
  }

  void _handleConversationText(Map<String, dynamic> data) {
    final role = data['role']?.toString().trim() ?? '';
    final content = data['content']?.toString().trim() ?? '';
    if (content.isEmpty) return;

    final transcript = DeepgramVoiceAgentTranscript(
      role: role,
      content: content,
    );
    if (transcript.isUser) _lastUserCommand = content;
    if (!_transcriptController.isClosed) {
      _transcriptController.add(transcript);
    }
    onTranscript?.call(transcript);
  }

  Future<void> _handleUserStartedSpeaking() async {
    // Deepgram explicitly expects the client to flush buffered agent audio here.
    _agentAudioBytesThisTurn = 0;
    await _interruptAgentAudio();
    setMicrophoneMuted(false);
    _setState(DeepgramVoiceAgentState.listening);
    _emitStatus('User speaking');
  }

  Future<void> _handleFunctionCallRequest(Map<String, dynamic> message) async {
    final generation = _connectionGeneration;
    final rawFunctions = message['functions'];
    if (rawFunctions is! List) return;

    // Device-changing actions are executed sequentially to avoid races.
    for (final rawFunction in rawFunctions) {
      if (generation != _connectionGeneration || !isConnected) return;
      if (rawFunction is! Map) continue;

      final function = Map<String, dynamic>.from(rawFunction);
      final id = function['id']?.toString() ?? '';
      final name = function['name']?.toString() ?? '';
      final clientSide = function['client_side'] == true;

      if (!clientSide || id.isEmpty || name.isEmpty) continue;
      if (_cancelledFunctionIds.contains(id)) continue;

      final arguments = _parseFunctionArguments(function['arguments']);
      onFunctionCall?.call(name, arguments);
      _activeFunctionIds.add(id);

      _setState(DeepgramVoiceAgentState.executing);
      _emitStatus('Executing $name');

      try {
        if (name == 'sleep_agent') {
          await onSessionEndRequested?.call();
          return;
        }
        final result = await ToolExecutor.execute(
          tool: name,
          arguments: name == 'read_messages'
              ? resolveMessageReadArguments(_lastUserCommand, arguments)
              : arguments,
          onLocalReadout: (message) async {
            if (generation != _connectionGeneration ||
                !isConnected ||
                _cancelledFunctionIds.contains(id)) {
              throw StateError('Message readout cancelled.');
            }
            await _interruptAgentAudio();
            if (generation != _connectionGeneration ||
                !isConnected ||
                _cancelledFunctionIds.contains(id)) {
              throw StateError('Message readout cancelled.');
            }
            setMicrophoneMuted(true);
            _setState(DeepgramVoiceAgentState.speaking);
            onLocalReadout?.call(message);
          },
        );
        if (name == 'read_messages' || name == 'check_messages') {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          setMicrophoneMuted(false);
        }

        if (generation != _connectionGeneration || !isConnected) return;
        if (_cancelledFunctionIds.contains(id)) continue;

        _sendJson(<String, dynamic>{
          'type': 'FunctionCallResponse',
          'id': id,
          'name': name,
          'content': jsonEncode(_functionResultContent(result)),
        });

        _setState(DeepgramVoiceAgentState.thinking);
      } catch (error) {
        if (_cancelledFunctionIds.contains(id)) continue;

        _sendJson(<String, dynamic>{
          'type': 'FunctionCallResponse',
          'id': id,
          'name': name,
          'content': jsonEncode(<String, dynamic>{
            'success': false,
            'status': 'error',
            'message': 'The device action failed.',
          }),
        });
        debugPrint('Function $name failed: $error');
      } finally {
        if (name == 'read_messages' || name == 'check_messages') {
          setMicrophoneMuted(false);
          onLocalReadoutFinished?.call();
        }
        _activeFunctionIds.remove(id);
      }
    }
  }

  Map<String, dynamic> _parseFunctionArguments(dynamic raw) {
    if (raw == null) return <String, dynamic>{};
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);

    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return <String, dynamic>{};
  }

  Map<String, dynamic> _functionResultContent(ToolExecutionResult result) {
    final localReadout = notificationResultForAgent(result);
    if (localReadout != null) return localReadout;
    switch (result.status) {
      case ToolExecutionStatus.completed:
        return <String, dynamic>{
          'success': true,
          'status': 'completed',
          'message': result.message,
        };

      case ToolExecutionStatus.needsContactSelection:
        return <String, dynamic>{
          'success': false,
          'status': 'multiple_matches',
          'message': result.message,
          // Do not send phone numbers to the remote LLM.
          'matches': result.contacts
              .map(
                (contact) => <String, dynamic>{
                  'name': contact.name,
                  if (contact.label != null) 'label': contact.label,
                },
              )
              .toList(),
        };

      case ToolExecutionStatus.error:
        return <String, dynamic>{
          'success': false,
          'status': 'error',
          'message': result.message,
        };

      case ToolExecutionStatus.needsInput:
        return <String, dynamic>{
          'success': false,
          'status': 'needs_input',
          'message': result.message,
        };
    }
  }

  void _handleFunctionCallCancelled(Map<String, dynamic> data) {
    final rawFunctions = data['functions'];
    if (rawFunctions is! List) return;

    for (final raw in rawFunctions) {
      if (raw is! Map) continue;
      final id = raw['id']?.toString();
      if (id == null || id.isEmpty) continue;
      _cancelledFunctionIds.add(id);
      if (_activeFunctionIds.contains(id)) {
        unawaited(MessageNotificationService.stopReadout().catchError((_) {}));
      }
      debugPrint('Function cancelled: $id');
    }

    if (_microphoneRunning) {
      _setState(DeepgramVoiceAgentState.listening);
    }
  }

  Future<void> forceEndTurn() => finishUserTurn();

  Future<void> injectUserMessage(String message) async {
    final clean = message.trim();
    if (!isConnected || clean.isEmpty) return;
    _sendJson(<String, dynamic>{'type': 'InjectUserMessage', 'content': clean});
  }

  Future<void> injectAgentMessage(
    String message, {
    String behavior = 'default',
  }) async {
    final clean = message.trim();
    if (!isConnected || clean.isEmpty) return;
    _sendJson(<String, dynamic>{
      'type': 'InjectAgentMessage',
      'message': clean,
      'behavior': behavior,
    });
  }

  void _startKeepAliveTimer() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (isConnected && (!_microphoneRunning || _microphoneMuted)) {
        _sendJson(<String, dynamic>{'type': 'KeepAlive'});
      }
    });
  }

  Future<String> _getTemporaryToken() async {
    final normalizedBackend = backendUrl.endsWith('/')
        ? backendUrl.substring(0, backendUrl.length - 1)
        : backendUrl;

    final response = await http
        .get(Uri.parse('$normalizedBackend/deepgram/token'))
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception(
        'Deepgram token request failed: ${response.statusCode} ${response.body}',
      );
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw Exception('Invalid Deepgram token response.');
    }

    final token = decoded['accessToken']?.toString().trim();
    if (token == null || token.isEmpty) {
      throw Exception('Deepgram access token missing.');
    }
    return token;
  }

  void _sendJson(Map<String, dynamic> data) {
    final socket = _socket;
    if (socket == null) return;

    try {
      socket.add(jsonEncode(data));
    } catch (error) {
      debugPrint('Deepgram send error: $error');
    }
  }

  void _handleAgentError(Map<String, dynamic> data) {
    final code = data['code']?.toString() ?? 'DEEPGRAM_ERROR';
    final description =
        data['description']?.toString() ?? 'Unknown Deepgram error';

    _emitError(code, description);
    _setState(DeepgramVoiceAgentState.error);

    final pending = _settingsAppliedCompleter;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(Exception('$code: $description'));
    }
  }

  void _handleSocketError(dynamic error) {
    _emitError('WEBSOCKET_ERROR', error.toString());
    _setState(DeepgramVoiceAgentState.error);

    final pending = _settingsAppliedCompleter;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(Exception('WebSocket error: $error'));
    }
  }

  void _handleSocketClosed() {
    _settingsApplied = false;

    final pending = _settingsAppliedCompleter;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(Exception('Deepgram Voice Agent disconnected.'));
    }

    if (_disposed || _disconnecting) return;

    _emitStatus('Deepgram Voice Agent disconnected');
    if (_state != DeepgramVoiceAgentState.error) {
      _setState(DeepgramVoiceAgentState.disconnected);
    }
  }

  void _setState(DeepgramVoiceAgentState state) {
    if (_state == state) return;
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
    onStateChanged?.call(state);
  }

  void _emitStatus(String status) {
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
    onStatus?.call(status);
  }

  void _emitError(String code, String description) {
    debugPrint('Deepgram Voice Agent error [$code]: $description');
    onError?.call(code, description);
  }

  Future<void> disconnect() async {
    if (_disconnecting) return;
    _disconnecting = true;
    _connectionGeneration++;
    _connecting = false;

    final pendingSettings = _settingsAppliedCompleter;
    if (pendingSettings != null && !pendingSettings.isCompleted) {
      pendingSettings.complete();
    }

    try {
      await _cleanupConnection(preserveErrorState: false);
      if (!_disposed) {
        _setState(DeepgramVoiceAgentState.disconnected);
      }
    } finally {
      _disconnecting = false;
    }
  }

  Future<void> _cleanupConnection({required bool preserveErrorState}) async {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;

    // Mark the session non-ready before stopping the recorder so stopListening
    // cannot replace an error state with READY during teardown.
    _settingsApplied = false;

    await stopListening();
    await _interruptAgentAudio();

    try {
      await _socketSubscription?.cancel();
    } catch (_) {}
    _socketSubscription = null;

    final socket = _socket;
    _socket = null;

    try {
      await socket?.close(WebSocketStatus.normalClosure, 'Client disconnected');
    } catch (_) {}

    _settingsApplied = false;
    _requestId = null;
    _agentAudioBytesThisTurn = 0;
    _microphoneMuted = false;
    _preconnectAudio.clear();
    _activeFunctionIds.clear();
    _cancelledFunctionIds.clear();

    if (!preserveErrorState && !_disposed) {
      _setState(DeepgramVoiceAgentState.disconnected);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;

    try {
      await _microphoneSubscription?.cancel();
    } catch (_) {}
    _microphoneSubscription = null;

    try {
      await _recorder.stop();
    } catch (_) {}

    try {
      await _socketSubscription?.cancel();
    } catch (_) {}
    _socketSubscription = null;

    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;

    try {
      await _player?.stop();
    } catch (_) {}
    try {
      await _player?.dispose();
    } catch (_) {}
    _player = null;

    try {
      await _recorder.dispose();
    } catch (_) {}

    await _stateController.close();
    await _transcriptController.close();
    await _statusController.close();
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('DeepgramVoiceAgentService has been disposed.');
    }
  }

  static const String _defaultSystemPrompt = '''
You are a fast, highly capable voice-first AI assistant running on an Android phone.

VOICE STYLE:
- Your replies are spoken aloud, so sound natural and concise.
- Prefer 1-3 short sentences for ordinary questions.
- Do not use markdown, URLs, or long lists in spoken replies.
- Do not narrate internal reasoning or say filler such as "I'm processing".
- Ask one short clarification question when essential information is missing.

DEVICE ACTIONS:
You have client-side functions for calling contacts, preparing messages, setting alarms, starting timers, and opening apps.
Use those functions whenever the user asks for the matching phone action.
Never claim a device action succeeded until the function result says it succeeded.
If a function returns an error, explain it briefly.
If it returns multiple contact matches, ask the user which contact they mean.
For messaging, preserve the exact requested message text. If the user did not specify WhatsApp or Messages, ask which one they want before calling send_message. Never claim the message was sent; say the composer is ready because the user must tap Send.
open_app can discover any installed launchable app by its name. Do not restrict requests to a fixed app list. If it returns needs_input, ask the exact clarification question and retry open_app with the chosen full name or package name.
Use set_torch for the flashlight, control_volume for volume, set_brightness for brightness, and get_battery for real battery status. Never guess device state. If a permission is missing, relay the function result's instructions.
Use sleep_agent to dismiss the assistant on Sleep, Exit, or a request to close this assistant. This does not mean restarting or shutting down the phone.
Use read_messages to read available WhatsApp or SMS/RCS notification previews and check_messages to report new preview counts. Both tools speak locally using Android's on-device voice and return only status; you never receive notification contents. Do not invent or repeat the readout. Default channel is all; use whatsapp or messages when requested, and sender for a named sender or conversation. Default unread_only=true means not yet spoken by this assistant; use false only when asked to repeat. For read more, keep it true. These tools do not expose a complete unread inbox. If spoken_locally=true and status=needs_input, wait for the user's clarification.
For read-more/repeat follow-ups, preserve the channel and sender from the most recent message request unless the user changes them.
For repeat, saved, already-read, or all-message requests, use read_all=true and unread_only=false. For all unread/new messages, use read_all=true and unread_only=true. Saved captured previews can be replayed even after notifications are dismissed, within the local cache retention window.

GENERAL ASSISTANCE:
Answer general knowledge questions, definitions, jokes, casual conversation, explanations, and everyday requests directly.
Keep answers voice-friendly and useful.
''';
}
