import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/agent_response.dart';
import '../models/contact_match.dart';
import '../models/tool_execution_result.dart';

import '../services/agent_tts_service.dart';
import '../services/deepgram_service.dart';
import '../services/device_action_service.dart';
import '../services/voice_agent_api_service.dart';
import '../services/wake_word_service.dart';

import '../tools/tool_executor.dart';
import '../services/deepgram_voice_agent_service.dart';

enum AgentProvider { customGroq, deepgramVoiceAgent }

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
  const VoiceAgentScreen({super.key});

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

  int _customCommandGeneration = 0;

  int _speechGeneration = 0;

  Timer? _deepgramSpeechFallbackTimer;

  int _deepgramResponseGeneration = 0;

  bool _deepgramNativeAudioStarted = false;

  int? _deepgramFallbackSpeakingGeneration;

  String _deepgramFallbackSpokenText = '';

  bool _deepgramFallbackPending = false;

  bool _wakeWordEnabled = true;

  WakeWordState _wakeWordState = WakeWordState.uninitialized;

  String? _wakeWordMessage;

  List<ContactMatch> _contacts = [];

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
    )..repeat();

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
      unawaited(_startWakeWordIfIdle());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_startWakeWordIfIdle());
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(_wakeWord.stop());
    }
  }

  void _handleDeepgramAgentState(DeepgramVoiceAgentState state) {
    if (!mounted || _provider != AgentProvider.deepgramVoiceAgent) {
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
    if (!mounted || _provider != AgentProvider.deepgramVoiceAgent) {
      return;
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
    if (_provider != AgentProvider.deepgramVoiceAgent ||
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
    final completeMessage = _agentMessage?.trim() ?? '';
    if (!mounted ||
        completeMessage.isEmpty ||
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
    return _switchingProvider ||
        _processing ||
        _deepgramVoiceAgent.isConnected ||
        _state == VoiceUiState.listening ||
        _state == VoiceUiState.thinking ||
        _state == VoiceUiState.speaking ||
        _state == VoiceUiState.executing;
  }

  Future<void> _startWakeWordIfIdle() async {
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
    setState(() {
      _agentMessage = 'I\'m listening.';
    });

    await _handleVoiceButton();
  }

  Future<void> _toggleWakeWord(bool enabled) async {
    setState(() {
      _wakeWordEnabled = enabled;
    });

    if (!enabled) {
      await _wakeWord.stop();
      return;
    }

    await _startWakeWordIfIdle();
  }

  Future<void> _switchProvider(AgentProvider provider) async {
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

    await _startWakeWordIfIdle();

    HapticFeedback.selectionClick();
  }

  Future<void> _cancelCustomActivity({bool resetUi = true}) async {
    _customCommandGeneration++;
    _speechGeneration++;
    _processing = false;

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
    final setupRequired = _wakeWordState == WakeWordState.unavailable ||
        _wakeWordState == WakeWordState.error;

    final title = !_wakeWordEnabled
        ? 'HEY AGENT OFF'
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
                    color: _wakeWordEnabled
                        ? accent
                        : const Color(0xFF70819B),
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
          Switch.adaptive(
            value: _wakeWordEnabled,
            activeColor: const Color(0xFF53E6B1),
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

    final commandGeneration = ++_customCommandGeneration;

    _processing = true;

    setState(() {
      _state = VoiceUiState.thinking;

      _contacts = [];

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

      final result = await ToolExecutor.execute(
        tool: response.tool!,

        arguments: response.arguments,

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
          });

          break;

        case ToolExecutionStatus.error:

          /*
           * Error is useful information,
           * so speak the entire message.
           */
          await _showAndSpeak(result.message, VoiceUiState.error);

          break;
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
        _processing = false;

        if (_tts.isSpeaking) {
          await _tts.waitUntilFinished();
        }

        if (_isCustomCommandActive(commandGeneration)) {
          await _startWakeWordIfIdle();
        }
      }
    }
  }

  bool _isCustomCommandActive(int generation) {
    return mounted &&
        _provider == AgentProvider.customGroq &&
        generation == _customCommandGeneration;
  }

  // ============================================================
  // CONTACT SELECTION
  // ============================================================

  Future<void> _selectContact(ContactMatch contact) async {
    await _wakeWord.stop();

    final message = 'Opening the dialer for ${contact.name}.';
    final speechGeneration = ++_speechGeneration;

    setState(() {
      _contacts = [];

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

  // ============================================================
  // SPEAK COMPLETE RESPONSE
  // ============================================================

  Future<void> _showAndSpeak(String message, VoiceUiState finalState) async {
    if (!mounted) return;

    final speechGeneration = ++_speechGeneration;

    setState(() {
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

  @override
  Widget build(BuildContext context) {
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

          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,

            children: [
              Text(
                'AI AGENT',

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

                style: TextStyle(
                  color: Color(0xFF63708A),

                  fontSize: 9,

                  letterSpacing: 1.7,

                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),

          const Spacer(),

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
                            .withOpacity(active ? .35 : .16),

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
            color: const Color(0xFF2F6BFF).withOpacity(.08),

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
            style: const TextStyle(
              color: Color(0xFF536785),
              fontSize: 12,
            ),
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
                          color: const Color(0xFF2F6BFF).withOpacity(.35),
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
