import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/agent_response.dart';
import '../models/contact_match.dart';
import '../models/tool_execution_result.dart';
import '../models/message_readout.dart';
import '../widgets/message_readout_view.dart';
import 'agent_settings_screen.dart';
import '../tools/message_commands.dart';
import '../tools/gmail_maps_commands.dart';
import '../tools/private_readout_guard.dart';

import '../services/agent_tts_service.dart';
import '../services/deepgram_service.dart';
import '../services/device_action_service.dart';
import '../services/message_notification_service.dart';
import '../services/voice_agent_api_service.dart';
import '../services/wake_word_service.dart';

import '../tools/tool_executor.dart';
import '../tools/session_commands.dart';
import '../services/deepgram_voice_agent_service.dart';

enum AgentProvider { customGroq, deepgramVoiceAgent }

enum _ProviderVoiceActionType { current, switchProvider }

class _ProviderVoiceAction {
  const _ProviderVoiceAction.current()
    : type = _ProviderVoiceActionType.current,
      target = null;

  const _ProviderVoiceAction.switchProvider([this.target])
    : type = _ProviderVoiceActionType.switchProvider;

  final _ProviderVoiceActionType type;
  final AgentProvider? target;
}

enum VoiceUiState {
  idle,
  listening,
  thinking,
  speaking,
  executing,
  success,
  needsInput,
  error,
}

class VoiceAgentScreen extends StatefulWidget {
  const VoiceAgentScreen({super.key, this.backgroundAssistant = false});

  /// Runs the normal voice engine without drawing the full Flutter screen.
  /// Android's native VoiceInteractionSession remains the only visible UI.
  final bool backgroundAssistant;

  @override
  State<VoiceAgentScreen> createState() => _VoiceAgentScreenState();
}

class _VoiceAgentScreenState extends State<VoiceAgentScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final DeepgramService _deepgram = DeepgramService();

  final AgentTtsService _tts = AgentTtsService();

  AgentProvider _provider = AgentProvider.customGroq;

  late final DeepgramVoiceAgentService _deepgramVoiceAgent;

  late final WakeWordService _wakeWord;

  StreamSubscription<String>? _transcriptSub;

  StreamSubscription<String>? _finalSub;

  late AnimationController _animation;

  VoiceUiState _state = VoiceUiState.idle;

  String _transcript = '';

  String? _agentMessage;

  bool _processing = false;

  bool _switchingProvider = false;
  bool _settingsOpen = false;
  String? _lastNativeUi;

  bool _voiceControlInProgress = false;
  bool _closingSession = false;
  bool _localReadoutInProgress = false;
  MessageReadout? _messageReadout;

  int _customCommandGeneration = 0;

  int _speechGeneration = 0;

  Timer? _deepgramSpeechFallbackTimer;

  int _deepgramResponseGeneration = 0;

  bool _deepgramNativeAudioStarted = false;

  int? _deepgramFallbackSpeakingGeneration;

  String _deepgramFallbackSpokenText = '';

  bool _deepgramFallbackPending = false;

  bool _wakeWordEnabled = true;

  bool _requestingAssistantRole = false;

  WakeWordState _wakeWordState = WakeWordState.uninitialized;

  String? _wakeWordMessage;

  List<ContactMatch> _contacts = [];

  String? _pendingContactTool;

  Map<String, dynamic> _pendingContactArguments = <String, dynamic>{};

  String? _pendingOriginalCommand;

  String? _pendingQuestion;

  final List<Map<String, String>> _conversationHistory = [];

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _deepgramVoiceAgent = DeepgramVoiceAgentService(
      backendUrl: VoiceAgentApiService.baseUrl,

      // No automatic greeting in app mode; user starts the conversation.
      greeting: null,

      onSessionEndRequested: _closeAssistantSession,
      onLocalReadout: (message) {
        if (!mounted || _closingSession) return;
        _localReadoutInProgress = true;
        _deepgramSpeechFallbackTimer?.cancel();
        setState(() {
          _messageReadout = message;
          _agentMessage = message.displayText;
          _state = VoiceUiState.speaking;
        });
      },
      onLocalReadoutFinished: () {
        _localReadoutInProgress = false;
      },

      onStateChanged: _handleDeepgramAgentState,

      onTranscript: _handleDeepgramAgentTranscript,

      onStatus: (status) {
        debugPrint('Deepgram Agent: $status');
      },

      onError: (code, description) {
        debugPrint(
          'Deepgram Agent Error '
          '$code: $description',
        );

        if (!mounted ||
            _provider != AgentProvider.deepgramVoiceAgent ||
            _switchingProvider) {
          return;
        }

        setState(() {
          _state = VoiceUiState.error;

          _agentMessage = description;
        });
      },

      onFunctionCall: (name, arguments) {
        debugPrint(
          'Deepgram function: '
          '$name $arguments',
        );
      },

      onLatencyReport: (report) {
        debugPrint('Deepgram latency: $report');
      },

      onAgentAudioStarted: _handleDeepgramNativeAudioStarted,

      onAgentAudioDone: _handleDeepgramNativeAudioDone,
    );

    _wakeWord = WakeWordService(
      onDetected: _handleWakeWordDetected,
      onStateChanged: (state, message) {
        debugPrint(
          '[WakeWord/UI] state=${state.name}, message=${message ?? "<none>"}',
        );
        if (!mounted) return;
        setState(() {
          _wakeWordState = state;
          _wakeWordMessage = message;
        });
      },
    );

    _animation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    if (!widget.backgroundAssistant) {
      _animation.repeat();
    }

    _transcriptSub = _deepgram.transcriptStream.listen((value) {
      if (!mounted || _provider != AgentProvider.customGroq) return;

      setState(() {
        _transcript = value;
      });
    });

    _finalSub = _deepgram.finalTranscriptStream.listen((value) {
      if (!mounted || _provider != AgentProvider.customGroq) return;

      setState(() {
        _transcript = value;
      });

      _processCommand(value);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initializeWakeWordExperience());
    });
  }

  Future<void> _initializeWakeWordExperience() async {
    await _wakeWord.refreshAssistantStatus();
    final preferredProvider = await _wakeWord.preferredProvider();
    if (!mounted) return;
    setState(() {
      _wakeWordEnabled = _wakeWord.persistedWakeEnabled;
      _provider = preferredProvider == AgentProvider.deepgramVoiceAgent.name
          ? AgentProvider.deepgramVoiceAgent
          : AgentProvider.customGroq;
    });
    await _startWakeWordIfIdle();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_initializeWakeWordExperience());
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      if (_wakeWord.isSystemAssistant) {
        unawaited(
          _wakeWord.handoffToBackground(
            canListen:
                _wakeWordEnabled &&
                !_voiceEngineBusy &&
                _wakeWordState != WakeWordState.detected,
          ),
        );
      } else {
        unawaited(_wakeWord.stop());
      }
    }
  }

  void _handleDeepgramAgentState(DeepgramVoiceAgentState state) {
    if (!mounted ||
        _closingSession ||
        _provider != AgentProvider.deepgramVoiceAgent ||
        _voiceControlInProgress) {
      return;
    }

    if (state == DeepgramVoiceAgentState.thinking) {
      _deepgramResponseGeneration++;
      _deepgramNativeAudioStarted = false;
      _deepgramFallbackSpokenText = '';
      _deepgramFallbackPending = false;
      _deepgramSpeechFallbackTimer?.cancel();
      unawaited(_tts.stop());
    }

    setState(() {
      switch (state) {
        case DeepgramVoiceAgentState.disconnected:
          // Do not immediately hide a real Settings/WebSocket error.
          if (_state != VoiceUiState.error) {
            _state = VoiceUiState.idle;
          }
          break;

        case DeepgramVoiceAgentState.connecting:
        case DeepgramVoiceAgentState.configuring:
          _state = VoiceUiState.thinking;
          break;

        case DeepgramVoiceAgentState.ready:
          _state = VoiceUiState.idle;
          break;

        case DeepgramVoiceAgentState.listening:
          _state = VoiceUiState.listening;
          break;

        case DeepgramVoiceAgentState.thinking:
          _state = VoiceUiState.thinking;
          break;

        case DeepgramVoiceAgentState.executing:
          _state = VoiceUiState.executing;
          break;

        case DeepgramVoiceAgentState.speaking:
          _state = VoiceUiState.speaking;
          break;

        case DeepgramVoiceAgentState.error:
          _state = VoiceUiState.error;
          break;
      }
    });

    if (state == DeepgramVoiceAgentState.disconnected ||
        state == DeepgramVoiceAgentState.error) {
      unawaited(_startWakeWordIfIdle());
    }
  }

  void _handleDeepgramAgentTranscript(DeepgramVoiceAgentTranscript transcript) {
    if (!mounted ||
        _closingSession ||
        _provider != AgentProvider.deepgramVoiceAgent ||
        _voiceControlInProgress) {
      return;
    }

    // Preserve the private cards through the provider's generic completion.
    // Never append their text into a response eligible for cloud TTS fallback.
    if (transcript.isAssistant && _messageReadout != null) {
      return;
    }

    if (transcript.isUser) {
      if (isSessionExitCommand(transcript.content)) {
        unawaited(_closeAssistantSession());
        return;
      }
      if (_isOpenAgentAppCommand(transcript.content)) {
        setState(() {
          _transcript = transcript.content;
          _agentMessage = null;
        });
        unawaited(_openVisibleAgentApp());
        return;
      }

      final voiceAction = _parseProviderVoiceAction(transcript.content);
      if (voiceAction != null) {
        setState(() {
          _transcript = transcript.content;
          _agentMessage = null;
        });
        unawaited(_executeProviderVoiceAction(transcript.content, voiceAction));
        return;
      }
      final googleCommand = routeGmailMapsCommand(transcript.content);
      if (googleCommand != null) {
        unawaited(
          _readSavedMessages(
            googleCommand.arguments,
            tool: googleCommand.tool!,
            commandText: transcript.content,
          ),
        );
        return;
      }
    }

    setState(() {
      if (transcript.isUser) {
        _deepgramResponseGeneration++;
        _deepgramNativeAudioStarted = false;
        _deepgramFallbackSpokenText = '';
        _deepgramFallbackPending = false;
        _deepgramSpeechFallbackTimer?.cancel();

        _transcript = transcript.content;

        // A user transcript starts a new response group. Deepgram may emit the
        // assistant reply as several ConversationText messages, all of which
        // are appended below.
        _agentMessage = null;
        _messageReadout = null;
      }

      if (transcript.isAssistant) {
        _agentMessage = _appendDeepgramResponse(
          _agentMessage,
          transcript.content,
        );
      }
    });

    if (transcript.isAssistant) {
      _scheduleDeepgramSpeechFallback();
    }
  }

  void _handleDeepgramNativeAudioStarted() {
    _deepgramNativeAudioStarted = true;
    _deepgramFallbackPending = false;
    _deepgramSpeechFallbackTimer?.cancel();

    // If the safety fallback had just started, native streamed audio wins.
    unawaited(_tts.stop());
  }

  void _handleDeepgramNativeAudioDone(bool receivedAudio) {
    if (!receivedAudio) {
      _scheduleDeepgramSpeechFallback(runSoon: true);
    }
  }

  void _scheduleDeepgramSpeechFallback({bool runSoon = false}) {
    if (_messageReadout != null ||
        _localReadoutInProgress ||
        _provider != AgentProvider.deepgramVoiceAgent ||
        _deepgramNativeAudioStarted) {
      return;
    }

    final generation = _deepgramResponseGeneration;
    if (_deepgramFallbackSpeakingGeneration == generation) {
      _deepgramFallbackPending = true;
      return;
    }

    _deepgramSpeechFallbackTimer?.cancel();
    _deepgramSpeechFallbackTimer = Timer(
      Duration(milliseconds: runSoon ? 120 : 1200),
      () => unawaited(_speakDeepgramFallback(generation)),
    );
  }

  Future<void> _speakDeepgramFallback(int generation) async {
    final completeMessage = cloudFallbackText(_agentMessage, _messageReadout);
    if (!mounted ||
        completeMessage.isEmpty ||
        _localReadoutInProgress ||
        _provider != AgentProvider.deepgramVoiceAgent ||
        generation != _deepgramResponseGeneration ||
        _deepgramNativeAudioStarted) {
      return;
    }

    var message = completeMessage;
    if (_deepgramFallbackSpokenText.isNotEmpty &&
        completeMessage.startsWith(_deepgramFallbackSpokenText)) {
      message = completeMessage
          .substring(_deepgramFallbackSpokenText.length)
          .trim();
    }
    if (message.isEmpty) return;

    debugPrint('No Deepgram PCM received; using streamed TTS fallback.');
    _deepgramFallbackSpeakingGeneration = generation;
    _deepgramFallbackPending = false;
    _deepgramVoiceAgent.setMicrophoneMuted(true);
    setState(() {
      _state = VoiceUiState.speaking;
    });

    try {
      await _tts.speakAndWait(message);
    } catch (error) {
      debugPrint('Deepgram speech fallback failed: $error');
    } finally {
      // The fallback also plays through the phone speaker, so hold the
      // microphone upload until playback and its brief echo tail are over.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      _deepgramVoiceAgent.setMicrophoneMuted(false);

      if (_deepgramFallbackSpeakingGeneration == generation) {
        _deepgramFallbackSpeakingGeneration = null;
      }
    }

    if (!mounted ||
        generation != _deepgramResponseGeneration ||
        _deepgramNativeAudioStarted ||
        _provider != AgentProvider.deepgramVoiceAgent) {
      return;
    }

    _deepgramFallbackSpokenText = completeMessage;

    setState(() {
      _state = _deepgramVoiceAgent.isListening
          ? VoiceUiState.listening
          : VoiceUiState.idle;
    });

    if (_deepgramFallbackPending ||
        (_agentMessage?.trim() ?? '') != completeMessage) {
      _scheduleDeepgramSpeechFallback(runSoon: true);
    }
  }

  String _appendDeepgramResponse(String? current, String incoming) {
    final next = incoming.trim();
    final existing = current?.trim() ?? '';

    if (next.isEmpty) return existing;
    if (existing.isEmpty) return next;

    // Handle providers that occasionally send a cumulative replacement rather
    // than a brand-new sentence.
    if (next == existing || existing.endsWith(next)) return existing;
    if (next.startsWith(existing)) return next;

    return '$existing\n\n$next';
  }

  bool get _voiceEngineBusy {
    return _settingsOpen ||
        _switchingProvider ||
        _voiceControlInProgress ||
        _processing ||
        _deepgramVoiceAgent.isConnected ||
        _state == VoiceUiState.listening ||
        _state == VoiceUiState.thinking ||
        _state == VoiceUiState.speaking ||
        _state == VoiceUiState.executing;
  }

  Future<void> _startWakeWordIfIdle() async {
    if (_closingSession) return;
    debugPrint(
      '[WakeWord/UI] start check: mounted=$mounted, '
      'enabled=$_wakeWordEnabled, busy=$_voiceEngineBusy, '
      'lifecycle=${WidgetsBinding.instance.lifecycleState}',
    );

    if (!mounted || !_wakeWordEnabled || _voiceEngineBusy) {
      debugPrint('[WakeWord/UI] start skipped by screen state.');
      return;
    }

    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      debugPrint('[WakeWord/UI] start skipped: app is not resumed.');
      return;
    }

    debugPrint('[WakeWord/UI] calling WakeWordService.start().');
    await _wakeWord.start();
  }

  Future<void> _handleWakeWordDetected() async {
    debugPrint('[WakeWord/UI] detection callback received.');
    if (!mounted || !_wakeWordEnabled || _voiceEngineBusy) return;

    HapticFeedback.heavyImpact();

    // The native system-assistant overlay has already spoken this greeting.
    // In app-only fallback mode Flutter speaks it before acquiring the STT mic.
    if (!_wakeWord.lastActivationFromSystemAssistant) {
      const greeting = 'Hey, how can I help you?';
      setState(() {
        _state = VoiceUiState.speaking;
        _agentMessage = greeting;
      });

      try {
        await _tts.speakAndWait(greeting);
      } catch (error) {
        debugPrint('Wake greeting TTS failed: $error');
      }

      if (!mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }

    setState(() {
      _agentMessage = 'I\'m listening.';
      _state = VoiceUiState.idle;
    });

    await _handleVoiceButton();
  }

  Future<void> _toggleWakeWord(bool enabled) async {
    setState(() {
      _wakeWordEnabled = enabled;
    });

    await _wakeWord.setEnabled(enabled);

    if (!enabled) {
      await _wakeWord.stop();
      return;
    }

    await _startWakeWordIfIdle();
  }

  Future<void> _requestSystemAssistantRole() async {
    if (_requestingAssistantRole) return;
    HapticFeedback.mediumImpact();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Opening Android assistant selection…'),
        duration: Duration(seconds: 2),
      ),
    );
    setState(() {
      _requestingAssistantRole = true;
      _wakeWordMessage = 'Choose AI Voice Agent as your assistant';
    });

    final selected = await _wakeWord.requestAssistantRole();
    if (!mounted) return;

    setState(() {
      _requestingAssistantRole = false;
      _wakeWordMessage = selected
          ? 'Works with the app closed'
          : 'Select AI Voice Agent in Android assistant settings';
    });

    if (selected) {
      await _wakeWord.setEnabled(_wakeWordEnabled);
      await _startWakeWordIfIdle();
    }
  }

  Future<void> _previewAssistantUi() async {
    HapticFeedback.selectionClick();
    final opened = await _wakeWord.previewAssistantUi();
    if (!mounted || opened) return;

    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Assistant preview is Android-only.')),
    );
  }

  Future<void> _switchProvider(
    AgentProvider provider, {
    bool restartWakeWord = true,
  }) async {
    if (_provider == provider || _switchingProvider) {
      return;
    }

    final previousProvider = _provider;

    setState(() {
      _switchingProvider = true;

      // Change provider first so late callbacks from the old engine are
      // ignored while its microphone/socket/audio are being torn down.
      _provider = provider;

      _state = VoiceUiState.idle;

      _transcript = '';

      _agentMessage = null;

      _contacts = [];

      _pendingContactTool = null;

      _pendingContactArguments = <String, dynamic>{};
    });

    try {
      if (previousProvider == AgentProvider.customGroq) {
        await _cancelCustomActivity(resetUi: false);
      } else {
        await _deepgramVoiceAgent.disconnect();
      }
    } catch (error) {
      debugPrint('Provider cleanup error: $error');
    } finally {
      if (mounted) {
        setState(() {
          _switchingProvider = false;
        });
      }
    }

    await _wakeWord.setPreferredProvider(provider.name);

    if (restartWakeWord) {
      await _startWakeWordIfIdle();
    }

    HapticFeedback.selectionClick();
  }

  Future<void> _cancelCustomActivity({bool resetUi = true}) async {
    _localReadoutInProgress = false;
    _customCommandGeneration++;
    _speechGeneration++;
    _processing = false;
    try {
      await MessageNotificationService.stopReadout();
    } catch (_) {}

    VoiceAgentApiService.cancelActiveRequest();

    try {
      await _deepgram.cancelListening();
    } catch (_) {}

    try {
      await _tts.stop();
    } catch (_) {}

    if (resetUi && mounted && _provider == AgentProvider.customGroq) {
      setState(() {
        _state = VoiceUiState.idle;
      });
    }
  }

  void _rememberConversation(String user, String assistant) {
    _conversationHistory.add({'role': 'user', 'content': user});

    _conversationHistory.add({'role': 'assistant', 'content': assistant});

    /*
   * Keep only recent context.
   *
   * 8 messages = roughly 4 turns.
   */
    if (_conversationHistory.length > 8) {
      _conversationHistory.removeRange(0, _conversationHistory.length - 8);
    }
  }

  // ============================================================
  // MICROPHONE
  // ============================================================

  Widget _providerSelector() {
    return Container(
      margin: const EdgeInsets.fromLTRB(22, 18, 22, 0),

      padding: const EdgeInsets.all(4),

      decoration: BoxDecoration(
        color: const Color(0xFF07111F),

        borderRadius: BorderRadius.circular(16),

        border: Border.all(color: const Color(0xFF17345F)),
      ),

      child: Row(
        children: [
          Expanded(
            child: _providerButton(
              title: 'CUSTOM',

              subtitle: 'GROQ',

              provider: AgentProvider.customGroq,

              icon: Icons.tune_rounded,
            ),
          ),

          Expanded(
            child: _providerButton(
              title: 'DEEPGRAM',

              subtitle: 'VOICE AGENT',

              provider: AgentProvider.deepgramVoiceAgent,

              icon: Icons.blur_on_rounded,
            ),
          ),
        ],
      ),
    );
  }

  Widget _providerButton({
    required String title,
    required String subtitle,
    required AgentProvider provider,
    required IconData icon,
  }) {
    final selected = _provider == provider;

    return GestureDetector(
      onTap: () {
        if (_switchingProvider) return;

        unawaited(_switchProvider(provider));
      },

      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),

        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 10),

        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),

          gradient: selected
              ? const LinearGradient(
                  colors: [Color(0xFF17489B), Color(0xFF0A74C6)],
                )
              : null,
        ),

        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,

          children: [
            Icon(
              icon,

              size: 17,

              color: selected ? Colors.white : const Color(0xFF637B9F),
            ),

            const SizedBox(width: 8),

            Column(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                Text(
                  title,

                  style: TextStyle(
                    fontSize: 10,

                    letterSpacing: 1.2,

                    fontWeight: FontWeight.w800,

                    color: selected ? Colors.white : const Color(0xFF8290A6),
                  ),
                ),

                Text(
                  subtitle,

                  style: TextStyle(
                    fontSize: 8,

                    letterSpacing: 1,

                    color: selected
                        ? const Color(0xFF9DD8FF)
                        : const Color(0xFF536279),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _wakeWordControl() {
    final listening = _wakeWordState == WakeWordState.listening;
    final setupRequired =
        _wakeWordState == WakeWordState.unavailable ||
        _wakeWordState == WakeWordState.error;

    final title = !_wakeWordEnabled
        ? 'HEY AGENT OFF'
        : _wakeWord.isSystemAssistant
        ? 'HEY AGENT • SYSTEM READY'
        : setupRequired
        ? 'HEY AGENT • SETUP REQUIRED'
        : listening
        ? 'HEY AGENT • LISTENING'
        : _wakeWordState == WakeWordState.detected
        ? 'HEY AGENT • DETECTED'
        : 'HEY AGENT • PAUSED';

    final accent = setupRequired
        ? const Color(0xFFFFAD42)
        : listening
        ? const Color(0xFF53E6B1)
        : const Color(0xFF65A9FF);

    return Container(
      margin: const EdgeInsets.fromLTRB(22, 10, 22, 0),
      padding: const EdgeInsets.fromLTRB(14, 9, 8, 9),
      decoration: BoxDecoration(
        color: const Color(0xFF07111F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF17345F)),
      ),
      child: Row(
        children: [
          Icon(
            listening ? Icons.hearing_rounded : Icons.hearing_disabled_rounded,
            color: _wakeWordEnabled ? accent : const Color(0xFF536279),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: _wakeWordEnabled ? accent : const Color(0xFF70819B),
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
                if (_wakeWordEnabled && _wakeWordMessage != null) ...[
                  const SizedBox(height: 3),
                  Text(
                    _wakeWordMessage!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF63708A),
                      fontSize: 9,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (!_wakeWord.isSystemAssistant)
            TextButton(
              onPressed: _requestingAssistantRole
                  ? null
                  : () => unawaited(_requestSystemAssistantRole()),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF65A9FF),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 34),
              ),
              child: Text(
                _requestingAssistantRole ? 'WAIT' : 'MAKE DEFAULT',
                style: const TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .7,
                ),
              ),
            ),
          Switch.adaptive(
            value: _wakeWordEnabled,
            activeThumbColor: const Color(0xFF53E6B1),
            onChanged: (value) => unawaited(_toggleWakeWord(value)),
          ),
        ],
      ),
    );
  }

  bool get _deepgramAgentCanStop {
    if (_provider != AgentProvider.deepgramVoiceAgent) {
      return false;
    }

    return _deepgramVoiceAgent.isConnected ||
        _state == VoiceUiState.thinking ||
        _state == VoiceUiState.listening ||
        _state == VoiceUiState.speaking ||
        _state == VoiceUiState.executing;
  }

  Future<void> _handleVoiceButton() async {
    if (_localReadoutInProgress) {
      await _cancelCustomActivity();
      return;
    }
    if (_switchingProvider) return;

    // Vosk and the selected provider cannot own the recorder together.
    await _wakeWord.stop();

    if (_provider == AgentProvider.customGroq) {
      await _toggleCustomGroqMic();
      await _startWakeWordIfIdle();
      return;
    }

    try {
      // STOP is a true session stop. Flux detects end-of-turn automatically,
      // so the button does not need to keep the microphone alive merely to
      // force a user turn. This also makes provider switching deterministic.
      if (_deepgramAgentCanStop) {
        _deepgramSpeechFallbackTimer?.cancel();
        _deepgramResponseGeneration++;
        await _tts.stop();
        await _deepgramVoiceAgent.disconnect();

        if (mounted && _provider == AgentProvider.deepgramVoiceAgent) {
          setState(() {
            _state = VoiceUiState.idle;
          });
        }

        HapticFeedback.lightImpact();
        await _startWakeWordIfIdle();
        return;
      }

      if (mounted) {
        setState(() {
          _transcript = '';
          _agentMessage = null;
          _contacts = [];
        });
      }

      HapticFeedback.mediumImpact();

      if (!_deepgramVoiceAgent.isConnected) {
        await _deepgramVoiceAgent.connect(startMicrophone: true);
      } else {
        await _deepgramVoiceAgent.startListening();
      }
    } catch (error) {
      debugPrint('Deepgram Agent control error: $error');

      if (!mounted) return;
      setState(() {
        _state = VoiceUiState.error;
        _agentMessage = 'Unable to start the Deepgram Voice Agent.';
      });
      await _startWakeWordIfIdle();
    }
  }

  Future<void> _toggleCustomGroqMic() async {
    if (_state == VoiceUiState.executing) {
      return;
    }

    if (_state == VoiceUiState.listening) {
      setState(() {
        _state = VoiceUiState.thinking;
      });

      final hasFinalTranscript = await _deepgram.stopListening();

      if (mounted &&
          !hasFinalTranscript &&
          !_processing &&
          _provider == AgentProvider.customGroq) {
        setState(() {
          _state = VoiceUiState.idle;
        });
      }

      return;
    }

    if (_processing ||
        _state == VoiceUiState.thinking ||
        _state == VoiceUiState.speaking) {
      await _cancelCustomActivity();
      HapticFeedback.lightImpact();
      return;
    }

    /*
     * Ensure the agent itself isn't
     * still speaking before we turn
     * microphone back on.
     */
    await _tts.stop();

    HapticFeedback.mediumImpact();

    setState(() {
      _state = VoiceUiState.listening;

      _transcript = '';

      _agentMessage = null;

      _contacts = [];
    });

    try {
      await _deepgram.startListening();
    } catch (e) {
      debugPrint('Microphone error: $e');

      await _showAndSpeak(
        'I couldn\'t access the microphone.',
        VoiceUiState.error,
      );
    }
  }

  // ============================================================
  // PROCESS FINAL TRANSCRIPT
  // ============================================================

  Future<void> _processCommand(String raw) async {
    final command = raw.trim();

    if (command.isEmpty || _processing) {
      return;
    }

    if (isSessionExitCommand(command)) {
      await _closeAssistantSession();
      return;
    }

    if (_isOpenAgentAppCommand(command)) {
      await _openVisibleAgentApp();
      return;
    }

    final voiceAction = _parseProviderVoiceAction(command);
    if (voiceAction != null) {
      await _executeProviderVoiceAction(command, voiceAction);
      return;
    }

    final commandGeneration = ++_customCommandGeneration;

    _processing = true;

    setState(() {
      _state = VoiceUiState.thinking;
      _messageReadout = null;

      _contacts = [];

      _pendingContactTool = null;

      _pendingContactArguments = <String, dynamic>{};

      /*
       * No spoken intermediate message.
       *
       * UI alone shows processing.
       */
      _agentMessage = null;
    });

    try {
      var input = command;

      /*
       * Multi-turn clarification.
       *
       * Example:
       *
       * "Call someone"
       *
       * Agent:
       * "Who would you like me to call?"
       *
       * User:
       * "Papa"
       */
      if (_pendingOriginalCommand != null && _pendingQuestion != null) {
        input =
            '''
Original request:
"${_pendingOriginalCommand!}"

Assistant asked:
"${_pendingQuestion!}"

User answered:
"$command"

Complete the original request using the answer.
''';
      }

      final AgentResponse response = await VoiceAgentApiService.executeCommand(
        input,
        history: _conversationHistory,
        commandText: command,
      );

      if (!_isCustomCommandActive(commandGeneration)) return;

      if (response.type == 'ask_user') {
        final message = response.message ?? 'What would you like me to do?';

        _pendingOriginalCommand ??= command;

        _pendingQuestion = message;

        _rememberConversation(command, message);

        await _showAndSpeak(message, VoiceUiState.needsInput);

        return;
      }

      if (response.type == 'assistant_response') {
        final message = response.message ?? 'I don\'t have an answer for that.';

        _clearContext();

        _rememberConversation(command, message);

        await _showAndSpeak(message, VoiceUiState.success);

        return;
      }

      // ========================================================
      // UNSUPPORTED
      // ========================================================

      if (response.type == 'unsupported') {
        _clearContext();

        await _showAndSpeak(
          response.message ?? 'That action isn\'t available yet.',
          VoiceUiState.error,
        );

        return;
      }

      // ========================================================
      // INVALID RESPONSE
      // ========================================================

      if (response.type != 'tool_call' || response.tool == null) {
        throw Exception('Invalid agent response');
      }

      // ========================================================
      // EXECUTE TOOL
      // ========================================================

      if (response.tool == 'sleep_agent') {
        await _closeAssistantSession();
        return;
      }

      final result = await ToolExecutor.execute(
        tool: response.tool!,

        arguments: response.tool == 'read_messages'
            ? resolveMessageReadArguments(command, response.arguments)
            : response.arguments,
        onLocalReadout: (message) async {
          if (!_isCustomCommandActive(commandGeneration)) {
            throw const VoiceAgentRequestCancelled();
          }
          _localReadoutInProgress = true;
          setState(() {
            _state = VoiceUiState.speaking;
            _messageReadout = message;
            _agentMessage = message.displayText;
          });
        },

        /*
         * Called AFTER the local data
         * required by the action has
         * been resolved, but BEFORE the
         * actual phone action.
         *
         * Example:
         *
         * contact found
         * ↓
         * "Opening the dialer for Papa"
         * ↓
         * speech starts
         * ↓
         * 450 ms
         * ↓
         * dialer opens
         */
        onBeforeAction: (message) async {
          if (!_isCustomCommandActive(commandGeneration)) {
            throw const VoiceAgentRequestCancelled();
          }

          setState(() {
            _state = VoiceUiState.speaking;

            _agentMessage = message;
          });

          /*
           * DO NOT wait for the entire
           * sentence to finish.
           *
           * startSpeaking() returns after
           * playback starts.
           */
          try {
            await _tts.startSpeaking(message);
          } catch (e) {
            debugPrint('Action TTS failed: $e');
          }

          /*
           * Small intentional UX delay.
           *
           * User hears:
           *
           * "Opening..."
           *
           * then action happens.
           */
          await Future.delayed(const Duration(milliseconds: 450));

          if (!_isCustomCommandActive(commandGeneration)) {
            throw const VoiceAgentRequestCancelled();
          }

          setState(() {
            _state = VoiceUiState.executing;
          });
        },
      );

      if (!_isCustomCommandActive(commandGeneration)) return;

      // ========================================================
      // TOOL RESULT
      // ========================================================

      switch (result.status) {
        case ToolExecutionStatus.completed:
          if (result.containsMessageData) {
            _rememberConversation(
              command,
              'The requested private readout completed on the phone.',
            );
          }
          if (result.speakResult) {
            _rememberConversation(command, result.message);
            await _showAndSpeak(result.message, VoiceUiState.success);
            break;
          }

          /*
           * Do NOT speak again.
           *
           * This was already spoken in
           * onBeforeAction.
           */
          setState(() {
            _state = VoiceUiState.success;

            _agentMessage = result.message;
          });

          HapticFeedback.lightImpact();

          break;

        case ToolExecutionStatus.needsContactSelection:

          /*
           * No action happened yet.
           *
           * So speak this whole message.
           */
          await _showAndSpeak(result.message, VoiceUiState.needsInput);

          if (!_isCustomCommandActive(commandGeneration)) return;

          setState(() {
            _contacts = result.contacts;

            _pendingContactTool = result.pendingContactTool;

            _pendingContactArguments = result.pendingContactArguments;
          });

          break;

        case ToolExecutionStatus.error:

          /*
           * Error is useful information,
           * so speak the entire message.
           */
          await _showAndSpeak(result.message, VoiceUiState.error);

          break;

        case ToolExecutionStatus.needsInput:
          _pendingOriginalCommand ??= command;
          _pendingQuestion = result.containsMessageData
              ? result.messageReadout?.channel == 'maps'
                    ? 'Which displayed route number should I read?'
                    : 'Which sender or conversation do you mean?'
              : result.message;
          _rememberConversation(command, _pendingQuestion!);
          if (result.spokenLocally) {
            setState(() {
              _state = VoiceUiState.needsInput;
              _agentMessage = result.message;
            });
          } else {
            await _showAndSpeak(result.message, VoiceUiState.needsInput);
          }
          return;
      }

      _clearContext();
    } catch (e) {
      if (!_isCustomCommandActive(commandGeneration)) return;

      debugPrint('Agent error: $e');

      await _showAndSpeak(
        'I couldn\'t complete that request. Please try again.',
        VoiceUiState.error,
      );
    } finally {
      if (commandGeneration == _customCommandGeneration) {
        _localReadoutInProgress = false;
        _processing = false;

        if (_tts.isSpeaking) {
          await _tts.waitUntilFinished();
        }

        if (_isCustomCommandActive(commandGeneration)) {
          if (_state == VoiceUiState.needsInput &&
              _pendingOriginalCommand != null) {
            // Continue a clarification naturally without making the user say
            // Hey Agent again after questions such as "WhatsApp or Messages?".
            await Future<void>.delayed(const Duration(milliseconds: 250));
            await _wakeWord.stop();
            await _toggleCustomGroqMic();
          } else if (widget.backgroundAssistant &&
              _provider == AgentProvider.customGroq) {
            // The native nudge remains open after a Groq response. Start a
            // fresh one-turn STT session directly instead of returning to
            // Vosk, because the transparent host can be lifecycle-inactive
            // underneath Android's VoiceInteractionSession.
            await Future<void>.delayed(const Duration(milliseconds: 300));
            await _wakeWord.stop();
            await _toggleCustomGroqMic();
          } else {
            await _startWakeWordIfIdle();
          }
        }
      }
    }
  }

  bool _isCustomCommandActive(int generation) {
    return mounted &&
        !_closingSession &&
        _provider == AgentProvider.customGroq &&
        generation == _customCommandGeneration;
  }

  Future<void> _closeAssistantSession() async {
    if (_closingSession || !mounted) return;
    _closingSession = true;
    _voiceControlInProgress = true;
    _deepgramSpeechFallbackTimer?.cancel();
    _deepgramResponseGeneration++;
    try {
      await _cancelCustomActivity(resetUi: false);
      await _deepgramVoiceAgent.disconnect();
      await _wakeWord.stop();
      _clearContext();
      await DeviceActionService.closeAssistant();
    } catch (error) {
      debugPrint('Assistant dismissal failed: $error');
      _closingSession = false;
      _voiceControlInProgress = false;
      if (mounted) {
        setState(() {
          _state = VoiceUiState.error;
          _agentMessage =
              'I stopped listening, but could not close the assistant.';
        });
      }
    }
  }

  bool _isOpenAgentAppCommand(String raw) {
    final normalized = raw
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final asksToOpen = RegExp(r'\b(open|launch|show|start)\b')
        .hasMatch(normalized);
    final namesThisApp =
        normalized.contains('ai agent') ||
        normalized.contains('agent app') ||
        normalized.contains('voice agent app') ||
        normalized.contains('your app') ||
        normalized.contains('our agent app');

    return asksToOpen && namesThisApp;
  }

  Future<void> _openVisibleAgentApp() async {
    if (_voiceControlInProgress) return;
    _voiceControlInProgress = true;

    try {
      await _wakeWord.stop();
      await _tts.stop();

      if (_provider == AgentProvider.customGroq) {
        await _deepgram.cancelListening();
        VoiceAgentApiService.cancelActiveRequest();
      } else {
        _deepgramSpeechFallbackTimer?.cancel();
        _deepgramResponseGeneration++;
        await _deepgramVoiceAgent.disconnect();
      }

      await DeviceActionService.openAgentApp();
    } catch (error) {
      debugPrint('Unable to open the visible AI Agent app: $error');
      _voiceControlInProgress = false;
      await _showAndSpeak(
        'I couldn\'t open the AI Agent app.',
        VoiceUiState.error,
      );
      await _startWakeWordIfIdle();
    }
  }

  _ProviderVoiceAction? _parseProviderVoiceAction(String raw) {
    final normalized = raw
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (normalized.isEmpty) return null;

    final mentionsDeepgram = RegExp(r'\bdeep ?gram\b').hasMatch(normalized);
    final mentionsGroq =
        RegExp(r'\bgroq\b').hasMatch(normalized) ||
        normalized.contains('custom model') ||
        normalized.contains('custom provider');
    final asksCurrent =
        RegExp(r'\b(current|active) (model|provider)\b').hasMatch(normalized) ||
        RegExp(r'\b(what|which) (model|provider)\b').hasMatch(normalized) ||
        normalized.contains('model are you using') ||
        normalized.contains('provider are you using');
    final hasDirectSwitchVerb =
        RegExp(r'\b(switch|change|swap|select|choose)\b')
            .hasMatch(normalized) ||
        RegExp(r'\b(go|move) to\b').hasMatch(normalized);
    final hasUseRequest = RegExp(r'^(please )?((can|could|would) you )?use\b')
        .hasMatch(normalized);
    final hasSwitchVerb = hasDirectSwitchVerb || hasUseRequest;
    final mentionsProvider =
        RegExp(r'\b(model|provider|engine)\b').hasMatch(normalized) ||
        mentionsDeepgram ||
        mentionsGroq ||
        normalized.contains('other one');

    if (asksCurrent && !hasDirectSwitchVerb) {
      return const _ProviderVoiceAction.current();
    }

    if (hasSwitchVerb && mentionsProvider) {
      if (mentionsDeepgram && !mentionsGroq) {
        return const _ProviderVoiceAction.switchProvider(
          AgentProvider.deepgramVoiceAgent,
        );
      }
      if (mentionsGroq && !mentionsDeepgram) {
        return const _ProviderVoiceAction.switchProvider(
          AgentProvider.customGroq,
        );
      }

      return const _ProviderVoiceAction.switchProvider();
    }

    return null;
  }

  Future<void> _executeProviderVoiceAction(
    String command,
    _ProviderVoiceAction action,
  ) async {
    if (!mounted || _voiceControlInProgress || _switchingProvider) return;

    _voiceControlInProgress = true;
    final previousProvider = _provider;

    try {
      final target = action.type == _ProviderVoiceActionType.switchProvider
          ? action.target ?? _oppositeProvider(previousProvider)
          : null;

      if (target != null && target != previousProvider) {
        // This changes _provider before awaiting teardown, so late Deepgram
        // callbacks cannot turn the voice command into another agent turn.
        await _switchProvider(target, restartWakeWord: false);
      } else {
        await _wakeWord.stop();
        if (previousProvider == AgentProvider.deepgramVoiceAgent) {
          _deepgramSpeechFallbackTimer?.cancel();
          _deepgramResponseGeneration++;
          await _tts.stop();
          await _deepgramVoiceAgent.disconnect();
        }
      }

      if (!mounted) return;
      setState(() {
        _transcript = command;
      });

      final message = switch (action.type) {
        _ProviderVoiceActionType.current => _currentProviderMessage(),
        _ProviderVoiceActionType.switchProvider
            when target == previousProvider =>
          'You are already using ${_providerName(previousProvider)}.',
        _ProviderVoiceActionType.switchProvider =>
          'Switched from ${_providerName(previousProvider)} to ${_providerName(target!)}.',
      };

      await _showAndSpeak(message, VoiceUiState.success);
    } catch (error) {
      debugPrint('Voice provider control failed: $error');
      await _showAndSpeak(
        'I couldn\'t change the voice provider.',
        VoiceUiState.error,
      );
    } finally {
      _voiceControlInProgress = false;
      await _startWakeWordIfIdle();
    }
  }

  AgentProvider _oppositeProvider(AgentProvider provider) {
    return provider == AgentProvider.customGroq
        ? AgentProvider.deepgramVoiceAgent
        : AgentProvider.customGroq;
  }

  String _providerName(AgentProvider provider) {
    return provider == AgentProvider.customGroq
        ? 'Groq'
        : 'Deepgram Voice Agent';
  }

  String _currentProviderMessage() {
    return _provider == AgentProvider.customGroq
        ? 'The current provider is Groq, using the GPT OSS 20B model.'
        : 'The current provider is Deepgram Voice Agent, using Claude Sonnet 4.6.';
  }

  // ============================================================
  // CONTACT SELECTION
  // ============================================================

  Future<void> _selectContact(ContactMatch contact) async {
    if (_pendingContactTool == 'send_message') {
      await _selectMessageContact(contact);
      return;
    }

    await _wakeWord.stop();

    final message = 'Opening the dialer for ${contact.name}.';
    final speechGeneration = ++_speechGeneration;

    setState(() {
      _contacts = [];

      _pendingContactTool = null;

      _pendingContactArguments = <String, dynamic>{};

      _state = VoiceUiState.speaking;

      _agentMessage = message;
    });

    /*
     * Start speaking.
     *
     * Do not wait for the sentence
     * to finish.
     */
    try {
      await _tts.startSpeaking(message);
    } catch (e) {
      debugPrint('Contact TTS failed: $e');
    }

    await Future.delayed(const Duration(milliseconds: 450));

    try {
      if (!mounted || speechGeneration != _speechGeneration) return;

      setState(() {
        _state = VoiceUiState.executing;
      });

      await DeviceActionService.dialNumber(phoneNumber: contact.phoneNumber);

      if (!mounted || speechGeneration != _speechGeneration) return;

      setState(() {
        _state = VoiceUiState.success;

        _agentMessage = message;
      });

      HapticFeedback.lightImpact();

      if (_tts.isSpeaking) {
        await _tts.waitUntilFinished();
      }
      await _startWakeWordIfIdle();
    } catch (e) {
      debugPrint('Dialer error: $e');

      await _showAndSpeak('I couldn\'t open the dialer.', VoiceUiState.error);
    }
  }

  Future<void> _selectMessageContact(ContactMatch contact) async {
    final messageBody =
        _pendingContactArguments['message']?.toString().trim() ?? '';
    final channel =
        _pendingContactArguments['channel']?.toString().trim() ?? '';

    if (messageBody.isEmpty || channel.isEmpty) {
      await _showAndSpeak(
        'I lost the message details. Please try that request again.',
        VoiceUiState.error,
      );
      return;
    }

    await _wakeWord.stop();
    final speechGeneration = ++_speechGeneration;

    setState(() {
      _contacts = [];
      _pendingContactTool = null;
      _pendingContactArguments = <String, dynamic>{};
    });

    final result = await ToolExecutor.composeMessageToContact(
      contact: contact,
      messageBody: messageBody,
      channel: channel,
      beforeAction: (message) async {
        if (!mounted || speechGeneration != _speechGeneration) return;
        setState(() {
          _state = VoiceUiState.speaking;
          _agentMessage = message;
        });

        try {
          await _tts.startSpeaking(message);
        } catch (error) {
          debugPrint('Message TTS failed: $error');
        }

        await Future<void>.delayed(const Duration(milliseconds: 450));
        if (!mounted || speechGeneration != _speechGeneration) return;
        setState(() {
          _state = VoiceUiState.executing;
        });
      },
    );

    if (!mounted || speechGeneration != _speechGeneration) return;

    if (result.status == ToolExecutionStatus.completed) {
      setState(() {
        _state = VoiceUiState.success;
        _agentMessage = result.message;
      });
      HapticFeedback.lightImpact();
      if (_tts.isSpeaking) await _tts.waitUntilFinished();
      await _startWakeWordIfIdle();
      return;
    }

    await _showAndSpeak(result.message, VoiceUiState.error);
    await _startWakeWordIfIdle();
  }

  // ============================================================
  // SPEAK COMPLETE RESPONSE
  // ============================================================

  Future<void> _showAndSpeak(String message, VoiceUiState finalState) async {
    if (!mounted) return;

    final speechGeneration = ++_speechGeneration;

    setState(() {
      _messageReadout = null;
      _state = VoiceUiState.speaking;

      _agentMessage = message;
    });

    /*
     * Here we DO wait until TTS
     * completely finishes.
     *
     * Used for:
     *
     * - errors
     * - clarification questions
     * - unsupported commands
     * - contact selection questions
     */
    try {
      await _tts.speakAndWait(message);
    } catch (e) {
      debugPrint('TTS error: $e');
    }

    if (!mounted || speechGeneration != _speechGeneration) return;

    setState(() {
      _state = finalState;
    });
  }

  void _clearContext() {
    _pendingOriginalCommand = null;

    _pendingQuestion = null;
  }

  // ============================================================
  // STATE
  // ============================================================

  String get _statusText {
    switch (_state) {
      case VoiceUiState.idle:
        return 'SYSTEM READY';

      case VoiceUiState.listening:
        return 'LISTENING';

      case VoiceUiState.thinking:
        return 'NEURAL ROUTING';

      case VoiceUiState.speaking:
        return 'RESPONDING';

      case VoiceUiState.executing:
        return 'EXECUTING';

      case VoiceUiState.success:
        return 'ACTION COMPLETE';

      case VoiceUiState.needsInput:
        return 'INPUT REQUIRED';

      case VoiceUiState.error:
        return 'ACTION BLOCKED';
    }
  }

  IconData get _coreIcon {
    switch (_state) {
      case VoiceUiState.listening:
        return Icons.graphic_eq_rounded;

      case VoiceUiState.thinking:
        return Icons.auto_awesome_rounded;

      case VoiceUiState.speaking:
        return Icons.waves_rounded;

      case VoiceUiState.executing:
        return Icons.bolt_rounded;

      case VoiceUiState.success:
        return Icons.check_rounded;

      case VoiceUiState.error:
        return Icons.close_rounded;

      default:
        return Icons.memory_rounded;
    }
  }

  String get _engineDescription {
    switch (_provider) {
      case AgentProvider.customGroq:
        return 'FLUX STT • GPT-OSS • AURA TTS';

      case AgentProvider.deepgramVoiceAgent:
        return 'FLUX • CLAUDE 4.6 • KIT TTS';
    }
  }

  // ============================================================
  // UI
  // ============================================================

  void _scheduleNativeAssistantUi() {
    final signature = '${_state.name}|$_transcript';
    if (_lastNativeUi == signature) return;
    _lastNativeUi = signature;
    final phase = _state.name;
    final caption = _transcript.isEmpty ? 'How can I help?' : _transcript;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closingSession) {
        unawaited(_wakeWord.updateAssistantUi(phase, caption));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.backgroundAssistant) {
      _scheduleNativeAssistantUi();
      return const SizedBox.expand();
    }

    return Scaffold(
      backgroundColor: const Color(0xFF02050A),

      body: Stack(
        children: [
          _background(),

          SafeArea(
            child: Column(
              children: [
                _header(),

                _providerSelector(),

                _wakeWordControl(),

                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),

                    padding: const EdgeInsets.symmetric(horizontal: 22),

                    child: Column(
                      children: [
                        const SizedBox(height: 38),

                        _agentCore(),

                        const SizedBox(height: 28),

                        _status(),

                        const SizedBox(height: 28),

                        if (_transcript.isNotEmpty) _transcriptView(),

                        if (_agentMessage != null) ...[
                          const SizedBox(height: 14),

                          _responseView(),
                        ],

                        if (_contacts.isNotEmpty) _contactView(),

                        const SizedBox(height: 30),
                      ],
                    ),
                  ),
                ),

                _bottomControls(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _background() {
    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,

              end: Alignment.bottomCenter,

              colors: [Color(0xFF02050A), Color(0xFF050B15), Color(0xFF02050A)],
            ),
          ),
        ),

        Positioned(
          top: -150,
          right: -130,

          child: Container(
            width: 380,
            height: 380,

            decoration: const BoxDecoration(
              shape: BoxShape.circle,

              gradient: RadialGradient(
                colors: [Color(0x332F6BFF), Color(0x0002050A)],
              ),
            ),
          ),
        ),

        Positioned(
          bottom: -160,
          left: -160,

          child: Container(
            width: 400,
            height: 400,

            decoration: const BoxDecoration(
              shape: BoxShape.circle,

              gradient: RadialGradient(
                colors: [Color(0x2200C8FF), Color(0x0002050A)],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _readSavedMessages(
    Map<String, dynamic> arguments, {
    String tool = 'read_messages',
    String? commandText,
  }) async {
    if (_processing ||
        _localReadoutInProgress ||
        _switchingProvider ||
        _closingSession) {
      return;
    }
    final generation = ++_customCommandGeneration;
    bool active() =>
        mounted &&
        !_closingSession &&
        !_switchingProvider &&
        generation == _customCommandGeneration;
    _processing = true;
    _localReadoutInProgress = true;
    _deepgramSpeechFallbackTimer?.cancel();
    _deepgramResponseGeneration++;
    setState(() {
      _state = VoiceUiState.thinking;
      _transcript =
          commandText ??
          (tool == 'read_gmail'
              ? 'Read Gmail.'
              : tool == 'get_driving_route'
              ? 'Read the current Maps route.'
              : 'Read all saved messages.');
      _agentMessage = null;
      _messageReadout = null;
    });
    try {
      // Explicit Gmail/Maps voice commands own the action before the remote
      // model can also issue a function request or a generic refusal.
      if (commandText != null) await _deepgramVoiceAgent.disconnect();
      await _wakeWord.stop();
      await _deepgram.cancelListening();
      await _tts.stop();
      // A local history-button readout owns the microphone/audio until done.
      await _deepgramVoiceAgent.disconnect();
      if (!active()) return;
      final result = await ToolExecutor.execute(
        tool: tool,
        arguments: arguments,
        onLocalReadout: (readout) async {
          if (!active()) throw const VoiceAgentRequestCancelled();
          _localReadoutInProgress = true;
          setState(() {
            _messageReadout = readout;
            _agentMessage = readout.displayText;
            _state = VoiceUiState.speaking;
          });
        },
      );
      if (!active()) return;
      if (result.status == ToolExecutionStatus.error) {
        await _showAndSpeak(result.message, VoiceUiState.error);
      } else if (tool == 'get_driving_route' && result.speakResult) {
        await _showAndSpeak(result.message, VoiceUiState.success);
      } else {
        setState(() {
          _messageReadout = result.messageReadout;
          _agentMessage = result.message;
          _state = result.status == ToolExecutionStatus.needsInput
              ? VoiceUiState.needsInput
              : VoiceUiState.success;
        });
      }
    } catch (_) {
      if (active()) {
        await _showAndSpeak(
          tool == 'read_gmail' || tool == 'check_gmail'
              ? 'I could not complete the Gmail request. Try again or check Connect Gmail in settings.'
              : tool == 'get_driving_route'
              ? 'I could not complete the Maps request. Check that Google Maps is installed and try again.'
              : 'I could not replay the saved messages.',
          VoiceUiState.error,
        );
      }
    } finally {
      if (generation == _customCommandGeneration) {
        _processing = false;
        _localReadoutInProgress = false;
        if (mounted) setState(() {});
        await _startWakeWordIfIdle();
      }
    }
  }

  Future<void> _openSettings() async {
    if (_settingsOpen || _switchingProvider || _closingSession) return;
    _settingsOpen = true;
    SettingsReadRequest? request;
    try {
      await _cancelCustomActivity();
      await _deepgramVoiceAgent.disconnect();
      await _wakeWord.stop();
      if (!mounted) return;
      setState(() => _state = VoiceUiState.idle);
      request = await Navigator.of(context).push<SettingsReadRequest>(
        MaterialPageRoute(
          builder: (_) => AgentSettingsScreen(
            provider: _provider.name,
            wakeEnabled: _wakeWordEnabled,
            isDefaultAssistant: _wakeWord.isSystemAssistant,
            onProviderChanged: (name) => _switchProvider(
              AgentProvider.values.byName(name),
              restartWakeWord: false,
            ),
            onWakeChanged: _toggleWakeWord,
            onMakeDefault: () async {
              await _requestSystemAssistantRole();
              return _wakeWord.isSystemAssistant;
            },
            onRefreshDefault: _wakeWord.refreshAssistantStatus,
            onPreview: _previewAssistantUi,
          ),
        ),
      );
    } finally {
      _settingsOpen = false;
      if (mounted) setState(() {});
    }
    if (!mounted || _closingSession) return;
    if (request != null) {
      await _readSavedMessages(request.arguments, tool: request.tool);
    } else {
      await _startWakeWordIfIdle();
    }
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),

      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,

            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),

              gradient: const LinearGradient(
                colors: [Color(0xFF2F6BFF), Color(0xFF00C8FF)],
              ),
            ),

            child: const Icon(Icons.hub_rounded, color: Colors.white, size: 21),
          ),

          const SizedBox(width: 12),

          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                Text(
                  'AI AGENT',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,

                  style: TextStyle(
                    color: Color(0xFFF5F8FF),

                    fontSize: 16,

                    fontWeight: FontWeight.w800,

                    letterSpacing: 1.1,
                  ),
                ),

                SizedBox(height: 2),

                Text(
                  'VOICE COMMAND INTERFACE',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,

                  style: TextStyle(
                    color: Color(0xFF63708A),

                    fontSize: 9,

                    letterSpacing: 1.7,

                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(
              Icons.settings_outlined,
              color: Color(0xFF7D9FD9),
              size: 21,
            ),
          ),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),

            decoration: BoxDecoration(
              color: const Color(0xFF07111F),

              borderRadius: BorderRadius.circular(30),

              border: Border.all(color: const Color(0xFF17345F)),
            ),

            child: const Row(
              children: [
                _LiveDot(),

                SizedBox(width: 7),

                Text(
                  'ONLINE',

                  style: TextStyle(
                    fontSize: 10,

                    color: Color(0xFF7D9FD9),

                    fontWeight: FontWeight.w700,

                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _agentCore() {
    return AnimatedBuilder(
      animation: _animation,

      builder: (context, child) {
        final active =
            _state == VoiceUiState.listening ||
            _state == VoiceUiState.thinking ||
            _state == VoiceUiState.speaking;

        final pulse = active
            ? 1 + math.sin(_animation.value * math.pi * 2) * 0.025
            : 1.0;

        return Transform.scale(
          scale: pulse,

          child: SizedBox(
            width: 228,
            height: 228,

            child: Stack(
              alignment: Alignment.center,

              children: [
                Transform.rotate(
                  angle: _animation.value * math.pi * 2,

                  child: Container(
                    width: 216,
                    height: 216,

                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,

                      gradient: SweepGradient(
                        colors: [
                          Color(0x002F6BFF),
                          Color(0xFF2F6BFF),
                          Color(0xFF00C8FF),
                          Color(0x002F6BFF),
                        ],
                      ),
                    ),

                    child: Padding(
                      padding: const EdgeInsets.all(2),

                      child: Container(
                        decoration: const BoxDecoration(
                          color: Color(0xFF02050A),

                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),

                Container(
                  width: 170,
                  height: 170,

                  decoration: BoxDecoration(
                    shape: BoxShape.circle,

                    color: const Color(0xFF07101D),

                    border: Border.all(color: const Color(0xFF193B70)),

                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF2F6BFF)
                            .withValues(alpha: active ? .35 : .16),

                        blurRadius: active ? 50 : 25,

                        spreadRadius: active ? 8 : 2,
                      ),
                    ],
                  ),

                  child: Center(
                    child: Container(
                      width: 110,
                      height: 110,

                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,

                        gradient: RadialGradient(
                          colors: [Color(0xFF164FB5), Color(0xFF07101D)],
                        ),
                      ),

                      child: Icon(
                        _coreIcon,

                        color: const Color(0xFFCBE9FF),

                        size: 45,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _status() {
    return Column(
      children: [
        Text(
          _statusText,

          style: const TextStyle(
            color: Color(0xFF3C8BFF),

            fontSize: 11,

            fontWeight: FontWeight.w800,

            letterSpacing: 2.4,
          ),
        ),

        if (_state == VoiceUiState.listening) ...[
          const SizedBox(height: 16),

          _waveform(),
        ],
      ],
    );
  }

  Widget _waveform() {
    return AnimatedBuilder(
      animation: _animation,

      builder: (context, child) {
        return SizedBox(
          height: 36,

          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,

            children: List.generate(22, (index) {
              final value = math
                  .sin((_animation.value * math.pi * 2) + index * .55)
                  .abs();

              return Container(
                width: 3,

                height: 5 + value * 25,

                margin: const EdgeInsets.symmetric(horizontal: 2),

                decoration: BoxDecoration(
                  color: Color.lerp(
                    const Color(0xFF2F6BFF),

                    const Color(0xFF00C8FF),

                    index / 22,
                  ),

                  borderRadius: BorderRadius.circular(10),
                ),
              );
            }),
          ),
        );
      },
    );
  }

  Widget _transcriptView() {
    return Container(
      width: double.infinity,

      padding: const EdgeInsets.all(18),

      decoration: BoxDecoration(
        color: const Color(0xB307101D),

        borderRadius: BorderRadius.circular(18),

        border: Border.all(color: const Color(0xFF142A4A)),
      ),

      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          const Text(
            'INPUT',

            style: TextStyle(
              color: Color(0xFF536785),

              fontSize: 9,

              fontWeight: FontWeight.w800,

              letterSpacing: 1.8,
            ),
          ),

          const SizedBox(height: 9),

          Text(
            '"$_transcript"',

            style: const TextStyle(
              color: Color(0xFFE8F2FF),

              fontSize: 19,

              fontWeight: FontWeight.w500,

              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _responseView() {
    return Container(
      width: double.infinity,

      padding: const EdgeInsets.all(18),

      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF081A33), Color(0xFF07111F)],
        ),

        borderRadius: BorderRadius.circular(18),

        border: Border.all(color: const Color(0xFF20569F)),

        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2F6BFF).withValues(alpha: .08),

            blurRadius: 30,
          ),
        ],
      ),

      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,

        children: [
          Container(
            width: 3,
            height: 44,

            decoration: BoxDecoration(
              color: const Color(0xFF2F7BFF),

              borderRadius: BorderRadius.circular(20),
            ),
          ),

          const SizedBox(width: 14),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                const Text(
                  'AGENT',

                  style: TextStyle(
                    color: Color(0xFF4B91FF),

                    fontSize: 9,

                    fontWeight: FontWeight.w800,

                    letterSpacing: 1.8,
                  ),
                ),

                const SizedBox(height: 7),

                if (_messageReadout != null)
                  MessageReadoutView(
                    readout: _messageReadout!,
                    onReadAllAgain:
                        _processing ||
                            _localReadoutInProgress ||
                            _switchingProvider ||
                            _state == VoiceUiState.thinking ||
                            _state == VoiceUiState.speaking ||
                            _state == VoiceUiState.executing
                        ? null
                        : () => unawaited(
                            _readSavedMessages(
                              _messageReadout!.replayArguments,
                              tool: _messageReadout!.channel == 'gmail'
                                  ? 'read_gmail'
                                  : _messageReadout!.channel == 'maps'
                                  ? 'get_driving_route'
                                  : 'read_messages',
                            ),
                          ),
                  )
                else
                  Text(
                    _agentMessage!,

                    style: const TextStyle(
                      color: Color(0xFFF3F7FF),

                      fontSize: 17,

                      height: 1.4,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _contactView() {
    return Padding(
      padding: const EdgeInsets.only(top: 14),

      child: Column(
        children: _contacts.map((contact) {
          return Container(
            margin: const EdgeInsets.only(bottom: 10),

            decoration: BoxDecoration(
              color: const Color(0xFF07111F),

              borderRadius: BorderRadius.circular(16),

              border: Border.all(color: const Color(0xFF17345F)),
            ),

            child: ListTile(
              onTap: () => _selectContact(contact),

              leading: const CircleAvatar(
                backgroundColor: Color(0xFF10284C),

                child: Icon(Icons.person_outline, color: Color(0xFF65A9FF)),
              ),

              title: Text(
                contact.name,

                style: const TextStyle(color: Colors.white),
              ),

              subtitle: Text(
                contact.phoneNumber,

                style: const TextStyle(color: Color(0xFF70819B)),
              ),

              trailing: const Icon(
                Icons.call_rounded,

                color: Color(0xFF4C94FF),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _bottomControls() {
    final isDeepgram = _provider == AgentProvider.deepgramVoiceAgent;

    final showStop = isDeepgram
        ? _deepgramAgentCanStop
        : _state == VoiceUiState.listening ||
              _state == VoiceUiState.thinking ||
              _state == VoiceUiState.speaking ||
              _processing;

    final disabled = _switchingProvider || _state == VoiceUiState.executing;

    final helperText = showStop
        ? (isDeepgram
              ? 'Stop voice session'
              : (_state == VoiceUiState.listening
                    ? 'Tap to finish'
                    : 'Stop response'))
        : (_state == VoiceUiState.needsInput
              ? 'Tap to answer'
              : 'Tap to speak');

    return Container(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 24),
      child: Column(
        children: [
          Text(
            helperText,
            style: const TextStyle(color: Color(0xFF536785), fontSize: 12),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: disabled ? null : _handleVoiceButton,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: disabled
                    ? null
                    : const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF2F6BFF), Color(0xFF00A9FF)],
                      ),
                color: disabled ? const Color(0xFF101722) : null,
                boxShadow: disabled
                    ? null
                    : [
                        BoxShadow(
                          color: const Color(0xFF2F6BFF).withValues(alpha: .35),
                          blurRadius: 28,
                          spreadRadius: 3,
                        ),
                      ],
              ),
              child: Icon(
                showStop ? Icons.stop_rounded : Icons.mic_rounded,
                color: disabled ? const Color(0xFF445064) : Colors.white,
                size: 35,
              ),
            ),
          ),
          const SizedBox(height: 13),
          Text(
            _engineDescription,
            style: const TextStyle(
              fontSize: 8,
              color: Color(0xFF34445D),
              letterSpacing: 1.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    unawaited(MessageNotificationService.stopReadout().catchError((_) {}));
    VoiceAgentApiService.cancelActiveRequest();

    WidgetsBinding.instance.removeObserver(this);

    _deepgramSpeechFallbackTimer?.cancel();

    _transcriptSub?.cancel();

    _finalSub?.cancel();

    unawaited(_deepgram.dispose());

    unawaited(_deepgramVoiceAgent.dispose());

    unawaited(_tts.dispose());

    unawaited(_wakeWord.dispose());

    _animation.dispose();

    super.dispose();
  }
}

class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late AnimationController controller;

  @override
  void initState() {
    super.initState();

    controller = AnimationController(
      vsync: this,

      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: .35, end: 1).animate(controller),

      child: Container(
        width: 7,
        height: 7,

        decoration: const BoxDecoration(
          color: Color(0xFF2F8BFF),

          shape: BoxShape.circle,
        ),
      ),
    );
  }

  @override
  void dispose() {
    controller.dispose();

    super.dispose();
  }
}
