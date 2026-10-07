import '../models/message_readout.dart';

/// Display text from a private readout must never become a cloud TTS fallback.
String cloudFallbackText(String? displayText, MessageReadout? privateReadout) =>
    privateReadout == null ? displayText?.trim() ?? '' : '';
