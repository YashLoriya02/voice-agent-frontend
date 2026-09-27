class AppRegistry {
  static const Map<String, String> _apps = {
    'youtube': 'com.google.android.youtube',

    'spotify': 'com.spotify.music',

    'whatsapp': 'com.whatsapp',

    'chrome': 'com.android.chrome',

    'google chrome': 'com.android.chrome',

    'google maps': 'com.google.android.apps.maps',

    'maps': 'com.google.android.apps.maps',
  };

  static String? getPackageName(String appName) {
    final normalized = appName.trim().toLowerCase();

    return _apps[normalized];
  }
}
