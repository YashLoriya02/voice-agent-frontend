class AppDefinition {
  const AppDefinition({
    required this.displayName,
    this.packageNames = const <String>[],
    this.systemTarget,
  });

  final String displayName;
  final List<String> packageNames;
  final String? systemTarget;
}

class AppRegistry {
  static const AppDefinition _youtube = AppDefinition(
    displayName: 'YouTube',
    packageNames: <String>['com.google.android.youtube'],
  );
  static const AppDefinition _spotify = AppDefinition(
    displayName: 'Spotify',
    packageNames: <String>['com.spotify.music'],
  );
  static const AppDefinition _whatsApp = AppDefinition(
    displayName: 'WhatsApp',
    packageNames: <String>['com.whatsapp', 'com.whatsapp.w4b'],
  );
  static const AppDefinition _chrome = AppDefinition(
    displayName: 'Chrome',
    packageNames: <String>['com.android.chrome'],
  );
  static const AppDefinition _instagram = AppDefinition(
    displayName: 'Instagram',
    packageNames: <String>['com.instagram.android', 'com.instagram.lite'],
  );
  static const AppDefinition _pubg = AppDefinition(
    displayName: 'PUBG',
    packageNames: <String>[
      'com.pubg.imobile',
      'com.tencent.ig',
      'com.pubg.krmobile',
    ],
  );
  static const AppDefinition _zomato = AppDefinition(
    displayName: 'Zomato',
    packageNames: <String>['com.application.zomato'],
  );
  static const AppDefinition _swiggy = AppDefinition(
    displayName: 'Swiggy',
    packageNames: <String>['in.swiggy.android'],
  );
  static const AppDefinition _zepto = AppDefinition(
    displayName: 'Zepto',
    packageNames: <String>['com.zeptoconsumerapp'],
  );
  static const AppDefinition _blinkit = AppDefinition(
    displayName: 'Blinkit',
    packageNames: <String>['com.grofers.customerapp'],
  );
  static const AppDefinition _messages = AppDefinition(
    displayName: 'Messages',
    packageNames: <String>[
      'com.google.android.apps.messaging',
      'com.samsung.android.messaging',
    ],
    systemTarget: 'messages',
  );
  static const AppDefinition _gallery = AppDefinition(
    displayName: 'Gallery',
    packageNames: <String>[
      'com.google.android.apps.photos',
      'com.sec.android.gallery3d',
      'com.miui.gallery',
    ],
    systemTarget: 'gallery',
  );
  static const AppDefinition _settings = AppDefinition(
    displayName: 'Settings',
    systemTarget: 'settings',
  );
  static const AppDefinition _camera = AppDefinition(
    displayName: 'Camera',
    systemTarget: 'camera',
  );
  static const AppDefinition _gmail = AppDefinition(
    displayName: 'Gmail',
    packageNames: <String>['com.google.android.gm'],
    systemTarget: 'email',
  );
  static const AppDefinition _maps = AppDefinition(
    displayName: 'Maps',
    packageNames: <String>['com.google.android.apps.maps'],
    systemTarget: 'maps',
  );
  static const AppDefinition _groww = AppDefinition(
    displayName: 'Groww',
    packageNames: <String>['com.nextbillion.groww'],
  );
  static const AppDefinition _bajajBroking = AppDefinition(
    displayName: 'Bajaj Broking',
    packageNames: <String>['com.msf.bfsltrade'],
  );

  static const Map<String, AppDefinition> _apps = <String, AppDefinition>{
    'youtube': _youtube,
    'spotify': _spotify,
    'whatsapp': _whatsApp,
    'whatsapp business': _whatsApp,
    'chrome': _chrome,
    'google chrome': _chrome,
    'instagram': _instagram,
    'insta': _instagram,
    'pubg': _pubg,
    'pubg mobile': _pubg,
    'bgmi': _pubg,
    'battlegrounds mobile india': _pubg,
    'zomato': _zomato,
    'swiggy': _swiggy,
    'zepto': _zepto,
    'blinkit': _blinkit,
    'messages': _messages,
    'message': _messages,
    'sms': _messages,
    'gallery': _gallery,
    'photos': _gallery,
    'google photos': _gallery,
    'settings': _settings,
    'phone settings': _settings,
    'camera': _camera,
    'gmail': _gmail,
    'email': _gmail,
    'maps': _maps,
    'google maps': _maps,
    'groww': _groww,
    'grow app': _groww,
    'bajaj broking': _bajajBroking,
    'bajaj brokerage': _bajajBroking,
  };

  static AppDefinition? find(String appName) {
    final normalized = appName
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final withoutGenericSuffix = normalized.replaceFirst(
      RegExp(r' (app|game)$'),
      '',
    );

    return _apps[normalized] ?? _apps[withoutGenericSuffix];
  }
}
