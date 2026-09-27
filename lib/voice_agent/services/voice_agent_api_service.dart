import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/agent_response.dart';

class VoiceAgentApiService {
  static http.Client? _activeClient;

  static int _requestGeneration = 0;

  static const String baseUrl = String.fromEnvironment(
    'VOICE_AGENT_API_URL',
    defaultValue: 'https://voice-ai-agent-server.vercel.app',
  );

  static Future<AgentResponse> executeCommand(
    String text, {
    List<Map<String, String>> history = const [],
  }) async {
    final requestGeneration = ++_requestGeneration;

    _activeClient?.close();

    final client = http.Client();

    _activeClient = client;

    final uri = Uri.parse('$baseUrl/voice-agent/execute');

    try {
      final response = await client
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'text': text,
              'currentDateTime': _currentDateTimeWithOffset(),
              'history': history,
            }),
          )
          .timeout(const Duration(seconds: 20));

      if (requestGeneration != _requestGeneration) {
        throw const VoiceAgentRequestCancelled();
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'Backend error ${response.statusCode}: ${response.body}',
        );
      }

      final decoded = jsonDecode(response.body);

      if (decoded is! Map<String, dynamic>) {
        throw Exception('Unexpected response from backend.');
      }

      final agentResponse = AgentResponse.fromJson(decoded);

      if (!agentResponse.success) {
        throw Exception(decoded['error'] ?? 'Agent request failed.');
      }

      return agentResponse;
    } finally {
      if (requestGeneration == _requestGeneration) {
        _activeClient = null;
      }

      client.close();
    }
  }

  static void cancelActiveRequest() {
    _requestGeneration++;

    _activeClient?.close();

    _activeClient = null;
  }

  static String _currentDateTimeWithOffset() {
    final now = DateTime.now();

    final offset = now.timeZoneOffset;

    final sign = offset.isNegative ? '-' : '+';

    final absoluteOffset = offset.abs();

    final hours = absoluteOffset.inHours.toString().padLeft(2, '0');

    final minutes = (absoluteOffset.inMinutes % 60).toString().padLeft(2, '0');

    return '${now.toIso8601String()}'
        '$sign$hours:$minutes';
  }
}

class VoiceAgentRequestCancelled implements Exception {
  const VoiceAgentRequestCancelled();

  @override
  String toString() => 'Voice agent request cancelled.';
}
