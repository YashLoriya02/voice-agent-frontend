class InstalledApp {
  const InstalledApp({required this.name, required this.packageName});

  final String name;
  final String packageName;

  factory InstalledApp.fromMap(Map<dynamic, dynamic> map) => InstalledApp(
    name: map['name'].toString(),
    packageName: map['packageName'].toString(),
  );
}

/// Exact labels win. Close speech spellings are considered only after literal
/// matches; similarly scored apps are returned together for clarification.
List<InstalledApp> matchInstalledApps(
  String query,
  List<InstalledApp> apps, {
  bool allowApproximate = true,
}) {
  final name = _normalize(query);
  if (name.isEmpty) return [];
  final unique = <String, InstalledApp>{
    for (final app in apps) app.packageName: app,
  }.values.toList();
  final exact = unique.where((app) => _normalize(app.name) == name).toList();
  if (exact.isNotEmpty) return exact;
  final withoutSuffix = _normalize(
    query.replaceFirst(RegExp(r'\s+(app|game)$', caseSensitive: false), ''),
  );
  if (withoutSuffix.isEmpty) return [];
  final suffixExact = unique
      .where((app) => _normalize(app.name) == withoutSuffix)
      .toList();
  if (suffixExact.isNotEmpty) return suffixExact;
  final partial = unique
      .where((app) => _normalize(app.name).contains(withoutSuffix))
      .toList();
  if (partial.isNotEmpty || !allowApproximate) return partial;

  // Very short names are too easy to confuse. Limit corrections to one edit
  // for short names and two for longer names, never arbitrary nearest apps.
  if (withoutSuffix.runes.length < 4) return [];
  final scored = <InstalledApp, double>{};
  for (final app in unique) {
    var best = 0.0;
    for (final label in _labelVariants(app.name)) {
      final candidate = _normalize(label);
      if (candidate.runes.length < 4) continue;
      final score = _similarity(withoutSuffix, candidate);
      if (score > best) best = score;
    }
    if (best >= 0.75) scored[app] = best;
  }
  if (scored.isEmpty) return [];
  final best = scored.values.reduce((a, b) => a > b ? a : b);
  return scored.entries
      .where((entry) => best - entry.value <= 0.08)
      .map((entry) => entry.key)
      .toList();
}

String _normalize(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

Iterable<String> _labelVariants(String label) sync* {
  yield label;
  // Launcher labels may include descriptions: "Upstox: Stocks & Demat".
  final brand = label.split(RegExp(r'[:\u2013\u2014]|\s-\s')).first.trim();
  yield brand;
  final words = brand.split(RegExp(r'\s+'));
  for (var count = 1; count < words.length && count <= 3; count++) {
    yield words.take(count).join(' ');
  }
}

// A small spelling equivalence handles "Upstocks" / "Upstox" without a
// dictionary of apps. Other substitutions still require a close edit match.
String _speechSpelling(String value) =>
    value.replaceAll('x', 'ks').replaceAll('cks', 'ks');

double _similarity(String query, String candidate) {
  var best = 0.0;
  for (final pair in [
    (query, candidate),
    (_speechSpelling(query), _speechSpelling(candidate)),
  ]) {
    final length = pair.$1.runes.length > pair.$2.runes.length
        ? pair.$1.runes.length
        : pair.$2.runes.length;
    final distance = _editDistance(pair.$1, pair.$2);
    final limit = length >= 7 ? 2 : 1;
    if (distance > limit) continue;
    final score = 1 - distance / length;
    if (score > best) best = score;
  }
  return best;
}

/// Edit distance including adjacent transpositions, using Unicode code points.
int _editDistance(String first, String second) {
  final a = first.runes.toList();
  final b = second.runes.toList();
  final rows = List.generate(
    a.length + 1,
    (i) => List<int>.filled(b.length + 1, 0),
  );
  for (var i = 0; i <= a.length; i++) {
    rows[i][0] = i;
  }
  for (var j = 0; j <= b.length; j++) {
    rows[0][j] = j;
  }
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      final values = [
        rows[i - 1][j] + 1,
        rows[i][j - 1] + 1,
        rows[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
        if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1])
          rows[i - 2][j - 2] + 1,
      ];
      rows[i][j] = values.reduce((a, b) => a < b ? a : b);
    }
  }
  return rows[a.length][b.length];
}
