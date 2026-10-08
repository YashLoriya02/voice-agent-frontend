/// Keep presentation markers out of speech without deleting meaningful numbers,
/// units, accented names or Hindi/Marathi text.
class SpeechText {
  static String clean(String input) {
    var text = input
        .replaceAll(RegExp(r'```[^\n]*\n'), '')
        .replaceAll('```', '')
        .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!)
        .replaceAll(RegExp(r'</?[A-Za-z][A-Za-z0-9]*(?:\s[^>]*)?/?>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(
          RegExp(r'^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+)', multiLine: true),
          '',
        )
        .replaceAll(RegExp(r'^\s*(?:[-_*]\s*){3,}\s*$', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*\|?[ :|-]+\|[ :|-]*$', multiLine: true), '')
        .replaceAllMapped(
          RegExp(r'(\d)\s*\*\s*(?=\d)'),
          (m) => '${m[1]} times ',
        )
        .replaceAllMapped(
          RegExp(r'\*\*(.+?)\*\*|__(.+?)__|~~(.+?)~~'),
          (m) => m[1] ?? m[2] ?? m[3]!,
        )
        .replaceAllMapped(
          RegExp(r'(?<!\w)[*_]([^*_\n]+)[*_](?!\w)'),
          (m) => m[1]!,
        )
        .replaceAll('`', '')
        .replaceAllMapped(
          RegExp(r'(\d)\s*\*\s*(?=\d)'),
          (m) => '${m[1]} times ',
        )
        .replaceAll(RegExp(r'\*+'), '')
        .replaceAll('|', ', ');
    text = String.fromCharCodes(text.runes.where((rune) => !_emoji(rune)));
    return text.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static bool _emoji(int rune) =>
      rune >= 0x1F000 && rune <= 0x1FAFF ||
      rune >= 0x2600 && rune <= 0x27BF ||
      rune >= 0x23E9 && rune <= 0x23F3 ||
      rune == 0x231A ||
      rune == 0x231B ||
      rune == 0x2B50 ||
      rune == 0x2B55 ||
      rune == 0x200D ||
      rune == 0xFE0E ||
      rune == 0xFE0F ||
      rune == 0x20E3 ||
      rune >= 0xE0020 && rune <= 0xE007F;

  /// One response may need several synthesis requests. Nothing is truncated.
  static List<String> chunks(String text, {int maximum = 1750}) {
    assert(maximum > 1);
    final result = <String>[];
    var remaining = text.trim();
    while (remaining.length > maximum) {
      var end = maximum;
      final prefix = remaining.substring(0, end);
      final sentences = RegExp(r'[.!?।](?:\s|$)').allMatches(prefix).toList();
      if (sentences.isNotEmpty && sentences.last.end > maximum ~/ 2) {
        end = sentences.last.end;
      } else {
        final space = prefix.lastIndexOf(' ');
        if (space > maximum ~/ 2) end = space;
      }
      final last = remaining.codeUnitAt(end - 1);
      if (last >= 0xD800 && last <= 0xDBFF) end--;
      result.add(remaining.substring(0, end).trim());
      remaining = remaining.substring(end).trimLeft();
    }
    if (remaining.isNotEmpty) result.add(remaining);
    return result;
  }

  static Duration completionTimeout(String text) {
    final words = text.trim().split(RegExp(r'\s+')).length;
    final seconds = 30 + (words * 0.8).ceil() + (text.length / 40).ceil();
    return Duration(seconds: seconds < 45 ? 45 : seconds);
  }
}
