import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/voice_agent/services/speech_text.dart';

void main() {
  test('strips presentation markers and emojis, keeping the actual answer', () {
    expect(
      SpeechText.clean(
        '## Lunch\n**Try** *rice* 🍽️ 🛍️ 🫂\n- [Details](https://example.com)',
      ),
      'Lunch Try rice Details',
    );
    expect(SpeechText.clean('Great 👩🏽‍💻 🇮🇳 👨‍👩‍👧‍👦!'), 'Great !');
  });
  test('preserves math, amounts, accents and Indian-language text', () {
    expect(
      SpeechText.clean(
        '₹250, 50%, 25°C. 2 * 3 * 4 = 24. 3 < 5. Café मुंबई नमस्ते.',
      ),
      '₹250, 50%, 25°C. 2 times 3 times 4 = 24. 3 < 5. Café मुंबई नमस्ते.',
    );
  });
  test('code and markup become plain text without losing content', () {
    expect(
      SpeechText.clean(
        '```text\nhello world\n```\n<b>Nice</b> &amp; `file_name`',
      ),
      'hello world Nice & file_name',
    );
  });
  test(
    'long responses fit the existing backend limit without losing words',
    () {
      final text = List.generate(500, (i) => 'word$i').join(' ');
      final chunks = SpeechText.chunks(text);
      expect(chunks.length, greaterThan(1));
      expect(chunks.every((chunk) => chunk.length <= 1750), isTrue);
      expect(chunks.join(' '), text);
      expect(SpeechText.completionTimeout(text).inSeconds, greaterThan(30));
    },
  );
  test('hard splits do not leave half a surrogate pair', () {
    final chunks = SpeechText.chunks('𐐀' * 2000);
    expect(chunks.join(), '𐐀' * 2000);
    expect(chunks.every((part) => part.length <= 1750), isTrue);
    expect(chunks.every((part) => !part.contains('\uFFFD')), isTrue);
  });
}
