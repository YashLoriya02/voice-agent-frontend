import 'package:flutter/services.dart';

import '../models/contact_match.dart';
import '../models/installed_app.dart';

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

  static Future<void> openAppTarget({
    required List<String> packageNames,
    String? systemTarget,
  }) async {
    await _channel.invokeMethod<void>('openAppTarget', {
      'packageNames': packageNames,
      'systemTarget': ?systemTarget,
    });
  }

  static Future<void> openAgentApp() async {
    await _channel.invokeMethod<void>('openAgentApp');
  }

  static Future<void> closeAssistant() =>
      _channel.invokeMethod<void>('closeAssistant');

  static Future<List<InstalledApp>> getLaunchableApps() async {
    final apps =
        await _channel.invokeMethod<List<dynamic>>('getLaunchableApps') ?? [];
    return apps.map((app) => InstalledApp.fromMap(app as Map)).toList();
  }

  static Future<Map<String, dynamic>> deviceControl(
    String method,
    Map<String, dynamic> arguments,
  ) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      method,
      arguments,
    );
    if (result == null) throw StateError('No device control result.');
    return result;
  }

  /// Opens a pre-filled composer. The user still reviews and taps Send.
  static Future<String> composeMessage({
    required String phoneNumber,
    required String message,
    required String channel,
  }) async {
    return await _channel.invokeMethod<String>('composeMessage', {
          'phoneNumber': phoneNumber,
          'message': message,
          'channel': channel,
        }) ??
        'messages';
  }

  static Future<bool> isWhatsAppAvailable() async {
    return await _channel.invokeMethod<bool>('isWhatsAppAvailable') ?? false;
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
