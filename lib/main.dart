import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:frontend/voice_agent/screens/voice_agent_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final backgroundAssistant =
      ui.PlatformDispatcher.instance.defaultRouteName ==
      '/assistant-background';

  runApp(MyApp(backgroundAssistant: backgroundAssistant));
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    this.backgroundAssistant = false,
  });

  final bool backgroundAssistant;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      home: VoiceAgentScreen(backgroundAssistant: backgroundAssistant),
    );
  }
}
