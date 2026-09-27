import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum WakeWordState {
  uninitialized,
  initializing,
  ready,
  listening,
  detected,
  unavailable,
  error,
}

typedef WakeWordDetectedCallback = Future<void> Function();
typedef WakeWordStateCallback = void Function(
  WakeWordState state,
  String? message,
);

/// Account-free "Hey Agent" detection backed by native Vosk on Android.
///
/// Vosk owns the microphone only while the app is idle. Native code shuts down
/// its AudioRecord before sending the detection callback, so Groq or Deepgram
/// can safely acquire the microphone for the actual conversation.
class WakeWordService {
  WakeWordService({
    required this.onDetected,
    this.onStateChanged,
  });

  static const MethodChannel _channel = MethodChannel(
    'com.infiheal.voice_agent/wake_word',
  );

  final WakeWordDetectedCallback onDetected;
  final WakeWordStateCallback? onStateChanged;

  WakeWordState _state = WakeWordState.uninitialized;
  Future<void> _operationChain = Future<void>.value();
  bool _handlerInstalled = false;
  bool _initialized = false;
  bool _desiredListening = false;
  bool _detectionInProgress = false;
  bool _disposed = false;

  WakeWordState get state => _state;
  bool get isListening => _state == WakeWordState.listening;
  bool get isConfigured => _initialized;

  Future<bool> initialize() async {
    if (_disposed) return false;
    if (_initialized) return true;

    if (!Platform.isAndroid) {
      _setState(
        WakeWordState.unavailable,
        'Hey Agent is currently available on Android only.',
      );
      return false;
    }

    _installHandler();
    _setState(WakeWordState.initializing, 'Loading offline Hey Agent...');

    try {
      await _channel.invokeMethod<void>('initialize');
      return true;
    } on PlatformException catch (error) {
      _log('Initialization failed: ${error.code}: ${error.message}');
      _setState(WakeWordState.error, 'Hey Agent setup failed.');
      return false;
    } catch (error) {
      _log('Initialization failed: $error');
      _setState(WakeWordState.error, 'Hey Agent setup failed.');
      return false;
    }
  }

  Future<void> start() async {
    if (_disposed) return;
    _desiredListening = true;
    await _enqueue(_startNow);
  }

  Future<void> _startNow() async {
    if (_disposed || !_desiredListening || isListening) return;

    final ready = _initialized || await initialize();
    if (!ready || _disposed || !_desiredListening) return;

    try {
      _log('Requesting native Vosk listener start.');
      await _channel.invokeMethod<void>('start');
    } on PlatformException catch (error) {
      _log('Start failed: ${error.code}: ${error.message}');
      _setState(WakeWordState.error, 'Could not start Hey Agent.');
    }
  }

  Future<void> stop() async {
    if (_disposed) return;
    _desiredListening = false;
    await _enqueue(_stopNow);
  }

  Future<void> _stopNow() async {
    if (!Platform.isAndroid || !_handlerInstalled) return;

    try {
      _log('Requesting native Vosk listener stop.');
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (error) {
      _log('Stop failed: ${error.code}: ${error.message}');
    }

    _detectionInProgress = false;
    if (!_disposed && _initialized) {
      _setState(WakeWordState.ready, 'Say “Hey Agent”');
    }
  }

  void _installHandler() {
    if (_handlerInstalled) return;
    _channel.setMethodCallHandler(_handleNativeCall);
    _handlerInstalled = true;
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (_disposed) return null;

    final arguments = call.arguments is Map
        ? Map<Object?, Object?>.from(call.arguments as Map)
        : const <Object?, Object?>{};

    switch (call.method) {
      case 'state':
        final stateName = arguments['state']?.toString();
        final message = arguments['message']?.toString();
        final nativeState = _stateFromNative(stateName);

        if (nativeState == WakeWordState.ready) {
          _initialized = true;
        }
        _setState(nativeState, message);
        break;

      case 'partial':
        final text = arguments['text']?.toString().trim() ?? '';
        if (text.isNotEmpty) {
          _log('Partial recognition: "$text"');
        }
        break;

      case 'detected':
        if (_detectionInProgress) return null;
        _detectionInProgress = true;
        _desiredListening = false;

        final text = arguments['text']?.toString().trim() ?? 'hey agent';
        _log('Detected: "$text"; native microphone is released.');
        _setState(WakeWordState.detected, 'Hey Agent detected');

        try {
          await onDetected();
        } catch (error, stackTrace) {
          _log('Detection callback failed: $error');
          debugPrintStack(stackTrace: stackTrace);
          if (!_disposed) {
            _setState(WakeWordState.error, 'Could not start the agent.');
          }
        } finally {
          _detectionInProgress = false;
        }
        break;

      default:
        _log('Ignoring unknown native callback: ${call.method}');
    }

    return null;
  }

  WakeWordState _stateFromNative(String? value) {
    return switch (value) {
      'initializing' => WakeWordState.initializing,
      'ready' => WakeWordState.ready,
      'listening' => WakeWordState.listening,
      'detected' => WakeWordState.detected,
      'unavailable' => WakeWordState.unavailable,
      'error' => WakeWordState.error,
      _ => WakeWordState.uninitialized,
    };
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    _operationChain = _operationChain.then((_) => operation()).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      _log('Lifecycle operation failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    });
    return _operationChain;
  }

  void _setState(WakeWordState state, String? message) {
    if (_disposed) return;
    _log('State ${_state.name} -> ${state.name}: ${message ?? ""}');
    _state = state;
    onStateChanged?.call(state, message);
  }

  void _log(String message) {
    debugPrint('[WakeWord/Vosk] $message');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _desiredListening = false;

    try {
      await _operationChain;
      if (Platform.isAndroid && _handlerInstalled) {
        await _channel.invokeMethod<void>('dispose');
      }
    } catch (error) {
      _log('Dispose failed: $error');
    }

    _disposed = true;
    _channel.setMethodCallHandler(null);
    _handlerInstalled = false;
  }
}
