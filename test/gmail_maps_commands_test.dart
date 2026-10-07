import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/voice_agent/services/voice_agent_api_service.dart';
import 'package:frontend/voice_agent/tools/gmail_maps_commands.dart';

void main() {
  test(
    'Screenshot commands route to phone tools with latest/unread semantics',
    () {
      for (final row in <(String, String, Map<String, dynamic>)>[
        (
          'Read last email from JetGPT.',
          'read_gmail',
          {'limit': 1, 'unread_only': false, 'sender': 'JetGPT'},
        ),
        (
          'Show me 1 last unread email.',
          'read_gmail',
          {'limit': 1, 'unread_only': true},
        ),
        (
          'How much is Punerco from my current location?',
          'get_driving_route',
          {'destination': 'Punerco'},
        ),
        (
          'Read five emails from Yash',
          'read_gmail',
          {'limit': 5, 'unread_only': true, 'sender': 'Yash'},
        ),
        (
          'Read last email from Five Guys',
          'read_gmail',
          {'limit': 1, 'unread_only': false, 'sender': 'Five Guys'},
        ),
        (
          'Read the latest unread Gmail message',
          'read_gmail',
          {'limit': 1, 'unread_only': true},
        ),
        (
          'Read my already-read emails',
          'read_gmail',
          {'limit': 5, 'unread_only': false},
        ),
        ('Do I have unread Gmail?', 'check_gmail', {}),
        ('Repeat those emails', 'read_gmail', {'repeat_last': true}),
        (
          'Navigate to Pune from my current location',
          'get_driving_route',
          {'destination': 'Pune', 'start_navigation': true},
        ),
        (
          'Take me to Phoenix Marketcity, Kurla',
          'get_driving_route',
          {
            'destination': 'Phoenix Marketcity, Kurla',
            'start_navigation': true,
          },
        ),
        (
          'Open driving directions to Mumbai airport',
          'get_driving_route',
          {'destination': 'Mumbai airport'},
        ),
        (
          'How far is Mumbai airport by car?',
          'get_driving_route',
          {'destination': 'Mumbai airport'},
        ),
        (
          'How long will it take to drive to Phoenix Marketcity, Kurla?',
          'get_driving_route',
          {'destination': 'Phoenix Marketcity, Kurla'},
        ),
        (
          'Read the current Maps route',
          'get_driving_route',
          {'read_current': true},
        ),
        (
          'The second route',
          'get_driving_route',
          {'read_current': true, 'choice': 2},
        ),
      ]) {
        final result = routeGmailMapsCommand(row.$1);
        expect(result?.tool, row.$2, reason: row.$1);
        expect(result?.arguments, row.$3, reason: row.$1);
      }
    },
  );
  test('Unrelated questions, negation, quoted instructions and other origins stay with existing router', () {
    for (final text in [
      'How much is an iPhone?',
      'Read Gmail documentation',
      'Do not read my emails',
      'How far is the Moon from Earth?',
      'How does Gmail work?',
      'Send an email to Yash',
      'Open WhatsApp',
      'Explain what navigate to Pune means',
      'Read WhatsApp messages',
      'Original request:\nRead my emails',
    ]) {
      expect(routeGmailMapsCommand(text), isNull, reason: text);
    }
  });
  test('Actual custom API entry bypasses backend and contradictory history, including pending context', () async {
    final result = await VoiceAgentApiService.executeCommand(
      'Original request:\nAn unrelated clarification',
      commandText: 'Show me 1 last unread email.',
      history: [
        {'role': 'assistant', 'content': 'I cannot read emails.'},
      ],
    );
    expect(result.tool, 'read_gmail');
    expect(result.arguments, {'limit': 1, 'unread_only': true});
  });
}
