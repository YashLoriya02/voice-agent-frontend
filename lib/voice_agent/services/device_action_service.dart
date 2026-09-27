import 'package:flutter/services.dart';

import '../models/contact_match.dart';

class DeviceActionService {
  static const MethodChannel _channel = MethodChannel(
    'com.infiheal.voice_agent/actions',
  );

  static Future<void> setAlarm({
    required int hour,
    required int minute,
    String label = 'Healo Alarm',
  }) async {
    await _channel.invokeMethod('setAlarm', {
      'hour': hour,
      'minute': minute,
      'label': label,
    });
  }

  static Future<void> setTimer({
    required int seconds,
    String label = 'Healo Timer',
  }) async {
    await _channel.invokeMethod('setTimer', {
      'seconds': seconds,
      'label': label,
    });
  }

  static Future<void> openApp({required String packageName}) async {
    await _channel.invokeMethod('openApp', {'packageName': packageName});
  }

  static Future<void> dialNumber({required String phoneNumber}) async {
    await _channel.invokeMethod('dialNumber', {'phoneNumber': phoneNumber});
  }

  static Future<bool> requestContactsPermission() async {
    final result = await _channel.invokeMethod<bool>(
      'requestContactsPermission',
    );

    return result ?? false;
  }

  static Future<List<ContactMatch>> findContacts({
    required String query,
  }) async {
    final result = await _channel.invokeMethod<List<dynamic>>('findContacts', {
      'query': query,
    });

    if (result == null) {
      return [];
    }

    return result
        .map((item) => ContactMatch.fromMap(Map<dynamic, dynamic>.from(item)))
        .toList();
  }
}
