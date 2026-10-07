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
  WakeWordService({required this.onDetected, this.onStateChanged});

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
  bool _assistantRoleHeld = false;
  bool _persistedWakeEnabled = true;
  bool _lastActivationFromSystemAssistant = false;

  WakeWordState get state => _state;
  bool get isListening => _state == WakeWordState.listening;
  bool get isConfigured => _initialized;
  bool get isSystemAssistant => _assistantRoleHeld;
  bool get persistedWakeEnabled => _persistedWakeEnabled;
  bool get lastActivationFromSystemAssistant =>
      _lastActivationFromSystemAssistant;

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
      await refreshAssistantStatus();

      final pendingActivation =
          await _channel.invokeMethod<bool>('consumePendingActivation') ??
          false;
      if (pendingActivation) {
        scheduleMicrotask(() => _dispatchDetection(fromSystemAssistant: true));
      }
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

  Future<void> setEnabled(bool enabled) async {
    if (_disposed || !Platform.isAndroid) return;
    _desiredListening = enabled;
    try {
      await _channel.invokeMethod<void>('setEnabled', {'enabled': enabled});
    } on PlatformException catch (error) {
      _log('Unable to persist wake setting: ${error.code}: ${error.message}');
    }
  }

  Future<bool> refreshAssistantStatus() async {
    if (_disposed || !Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMapMethod<Object?, Object?>(
        'assistantStatus',
      );
      _assistantRoleHeld = result?['selected'] == true;
      _persistedWakeEnabled = result?['wakeEnabled'] != false;
      return _assistantRoleHeld;
    } on PlatformException catch (error) {
      _log('Assistant status failed: ${error.code}: ${error.message}');
      _assistantRoleHeld = false;
      return false;
    }
  }

  Future<void> updateAssistantUi(String phase, String caption) async {
    if (_disposed || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('updateAssistantUi', {
        'phase': phase,
        'caption': caption,
      });
    } on PlatformException catch (_) {
      // Visual state must not interrupt the active voice command.
    }
  }

  Future<bool> requestAssistantRole() async {
    if (_disposed || !Platform.isAndroid) return false;
    try {
      final selected =
          await _channel.invokeMethod<bool>('requestAssistantRole') ?? false;
      _assistantRoleHeld = selected;
      return selected;
    } on PlatformException catch (error) {
      _log('Assistant role request failed: ${error.code}: ${error.message}');
      return false;
    }
  }

  /// Opens the same native bottom nudge used by the Android system assistant.
  /// The caller only exposes this action in Flutter debug builds.
  Future<bool> previewAssistantUi() async {
    if (_disposed || !Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('previewAssistantUi') ?? false;
    } on PlatformException catch (error) {
      _log('Assistant preview failed: ${error.code}: ${error.message}');
      return false;
    }
  }

  Future<String> preferredProvider() async {
    if (_disposed || !Platform.isAndroid) return 'customGroq';
    try {
      return await _channel.invokeMethod<String>('getPreferredProvider') ??
          'customGroq';
    } on PlatformException catch (error) {
      _log('Preferred provider read failed: ${error.code}: ${error.message}');
      return 'customGroq';
    }
  }

  Future<void> setPreferredProvider(String provider) async {
    if (_disposed || !Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setPreferredProvider', {
        'provider': provider,
      });
    } on PlatformException catch (error) {
      _log('Preferred provider save failed: ${error.code}: ${error.message}');
    }
  }

  Future<void> handoffToBackground({required bool canListen}) async {
    if (_disposed || !Platform.isAndroid || !_assistantRoleHeld) return;
    try {
      await _channel.invokeMethod<void>('backgroundHandoff', {
        'canListen': canListen,
      });
    } on PlatformException catch (error) {
      _log('Background handoff failed: ${error.code}: ${error.message}');
    }
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
        final text = arguments['text']?.toString().trim() ?? 'hey agent';
        _log('Detected: "$text"; native microphone is released.');
        await _dispatchDetection(fromSystemAssistant: false);
        break;

      case 'activation':
        _log('System assistant greeting finished; activating Flutter agent.');
        await _dispatchDetection(fromSystemAssistant: true);
        break;

      default:
        _log('Ignoring unknown native callback: ${call.method}');
    }

    return null;
  }

  Future<void> _dispatchDetection({required bool fromSystemAssistant}) async {
    if (_disposed || _detectionInProgress) return;
    _detectionInProgress = true;
    _desiredListening = false;
    _lastActivationFromSystemAssistant = fromSystemAssistant;
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
