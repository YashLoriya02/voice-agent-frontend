import 'dart:async';

import 'package:flutter/material.dart';

import '../services/deepgram_service.dart';

class VoiceTranscriptionTestScreen extends StatefulWidget {
  const VoiceTranscriptionTestScreen({super.key});

  @override
  State<VoiceTranscriptionTestScreen> createState() =>
      _VoiceTranscriptionTestScreenState();
}

class _VoiceTranscriptionTestScreenState
    extends State<VoiceTranscriptionTestScreen> {
  final DeepgramService _deepgram = DeepgramService();

  StreamSubscription<String>? _transcriptSubscription;

  StreamSubscription<String>? _finalSubscription;

  StreamSubscription<String>? _statusSubscription;

  String _transcript = '';

  String _finalTranscript = '';

  String _status = 'Ready';

  bool _listening = false;

  @override
  void initState() {
    super.initState();

    _transcriptSubscription = _deepgram.transcriptStream.listen((text) {
      if (!mounted) return;

      setState(() {
        _transcript = text;
      });
    });

    _finalSubscription = _deepgram.finalTranscriptStream.listen((text) {
      if (!mounted) return;

      setState(() {
        _finalTranscript = text;
        _transcript = text;
        _listening = false;
      });
    });

    _statusSubscription = _deepgram.statusStream.listen((status) {
      if (!mounted) return;

      setState(() {
        _status = status;
      });
    });
  }

  Future<void> _toggleMicrophone() async {
    if (_listening) {
      await _deepgram.stopListening();

      setState(() {
        _listening = false;
      });

      return;
    }

    setState(() {
      _transcript = '';
      _finalTranscript = '';
    });

    try {
      await _deepgram.startListening();

      if (!mounted) return;

      setState(() {
        _listening = true;
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _status = 'Unable to start: $e';

        _listening = false;
      });
    }
  }

  @override
  void dispose() {
    _transcriptSubscription?.cancel();

    _finalSubscription?.cancel();

    _statusSubscription?.cancel();

    _deepgram.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Healo Voice — Deepgram')),

      body: Padding(
        padding: const EdgeInsets.all(24),

        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,

          children: [
            Text(
              _status,
              textAlign: TextAlign.center,

              style: Theme.of(context).textTheme.titleMedium,
            ),

            const SizedBox(height: 40),

            Expanded(
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),

                  child: Text(
                    _transcript.isEmpty
                        ? _listening
                              ? 'Listening...'
                              : 'Tap the microphone and speak'
                        : _transcript,

                    key: ValueKey(_transcript),

                    textAlign: TextAlign.center,

                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),

            if (_finalTranscript.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(16),

                margin: const EdgeInsets.only(bottom: 30),

                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),

                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),

                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [
                    const Text(
                      'FINAL COMMAND',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),

                    const SizedBox(height: 8),

                    Text(
                      _finalTranscript,

                      style: const TextStyle(fontSize: 18),
                    ),
                  ],
                ),
              ),

            Center(
              child: FloatingActionButton.large(
                onPressed: _toggleMicrophone,

                child: Icon(_listening ? Icons.stop : Icons.mic),
              ),
            ),

            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}
