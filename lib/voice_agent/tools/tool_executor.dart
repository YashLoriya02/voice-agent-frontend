import '../models/contact_match.dart';
import '../models/installed_app.dart';
import '../models/message_readout.dart';
import '../models/tool_execution_result.dart';
import '../services/device_action_service.dart';
import '../services/message_notification_service.dart';
import '../services/gmail_service.dart';
import '../services/maps_service.dart';
import 'app_registry.dart';

typedef BeforeActionCallback = Future<void> Function(String message);

class ToolExecutor {
  static Future<ToolExecutionResult> execute({
    required String tool,

    required Map<String, dynamic> arguments,

    BeforeActionCallback? onBeforeAction,
    Future<void> Function(MessageReadout)? onLocalReadout,
  }) async {
    try {
      switch (tool) {
        case 'get_driving_route':
          return await MapsService.execute(
            arguments,
            onLocalReadout: onLocalReadout,
          );
        case 'read_gmail':
        case 'check_gmail':
          return await GmailService.execute(
            arguments,
            readAloud: tool == 'read_gmail',
            onLocalReadout: onLocalReadout,
          );
        case 'read_messages':
          return await MessageNotificationService.execute(
            arguments,
            readAloud: true,
            onLocalReadout: onLocalReadout,
          );

        case 'check_messages':
          return await MessageNotificationService.execute(
            arguments,
            readAloud: false,
            onLocalReadout: onLocalReadout,
          );

        case 'set_alarm':
          return await _setAlarm(arguments, onBeforeAction);

        case 'set_timer':
          return await _setTimer(arguments, onBeforeAction);

        case 'open_app':
          return await _openApp(arguments, onBeforeAction);

        case 'call_contact':
          return await _callContact(arguments, onBeforeAction);

        case 'send_message':
          return await _sendMessage(arguments, onBeforeAction);

        case 'set_torch':
          if (arguments['enabled'] is! bool) {
            return ToolExecutionResult.error(
              'Tell me whether to turn the torch on or off.',
            );
          }
          return await _deviceControl('setTorch', arguments);

        case 'control_volume':
          return await _deviceControl('controlVolume', arguments);

        case 'set_brightness':
          return await _deviceControl('setBrightness', arguments);

        case 'get_battery':
          return await _deviceControl('getBattery', const {});

        default:
          return ToolExecutionResult.error('That action isn\'t available yet.');
      }
    } catch (e) {
      return ToolExecutionResult.error('I couldn\'t complete that action.');
    }
  }

  static Future<ToolExecutionResult> _deviceControl(
    String method,
    Map<String, dynamic> arguments,
  ) async {
    final result = await DeviceActionService.deviceControl(method, arguments);
    final message =
        result['message']?.toString() ?? 'The device action failed.';
    return result['success'] == true
        ? ToolExecutionResult.completed(message, speakResult: true)
        : ToolExecutionResult.error(message);
  }

  // ---------------------------------------------
  // CALL CONTACT
  // ---------------------------------------------

  static Future<ToolExecutionResult> _callContact(
    Map<String, dynamic> args,
    BeforeActionCallback? beforeAction,
  ) async {
    final name = args['name']?.toString().trim();

    if (name == null || name.isEmpty) {
      return ToolExecutionResult.error('Tell me who you want to call.');
    }

    final permission = await DeviceActionService.requestContactsPermission();

    if (!permission) {
      return ToolExecutionResult.error(
        'I need contacts permission before I can make calls.',
      );
    }

    final contacts = await DeviceActionService.findContacts(query: name);

    if (contacts.isEmpty) {
      return ToolExecutionResult.error(
        'I couldn\'t find $name in your contacts.',
      );
    }

    if (contacts.length > 1) {
      return ToolExecutionResult.needsContactSelection(
        'I found ${contacts.length} matches for $name. Choose the one you want to call.',
        contacts,
        pendingContactTool: 'call_contact',
      );
    }

    final contact = contacts.first;

    final message = 'Opening the dialer for ${contact.name}.';

    if (beforeAction != null) {
      await beforeAction(message);
    }

    try {
      await DeviceActionService.dialNumber(phoneNumber: contact.phoneNumber);
    } catch (_) {
      return ToolExecutionResult.error(
        'I found ${contact.name}, but I couldn\'t open the dialer.',
      );
    }

    return ToolExecutionResult.completed(message);
  }

  // ---------------------------------------------
  // TIMER
  // ---------------------------------------------

  static Future<ToolExecutionResult> _setTimer(
    Map<String, dynamic> args,
    BeforeActionCallback? beforeAction,
  ) async {
    final seconds = _toInt(args['seconds']);

    if (seconds == null || seconds <= 0) {
      return ToolExecutionResult.error(
        'I couldn\'t understand the timer duration.',
      );
    }

    final label = args['label']?.toString().trim();

    final message = 'Starting a ${_formatDuration(seconds)} timer.';

    if (beforeAction != null) {
      await beforeAction(message);
    }

    try {
      await DeviceActionService.setTimer(
        seconds: seconds,

        label: label == null || label.isEmpty ? 'Healo Agent' : label,
      );
    } catch (_) {
      return ToolExecutionResult.error(
        'I couldn\'t start the timer on this phone.',
      );
    }

    return ToolExecutionResult.completed(message);
  }

  // ---------------------------------------------
  // ALARM
  // ---------------------------------------------

  static Future<ToolExecutionResult> _setAlarm(
    Map<String, dynamic> args,
    BeforeActionCallback? beforeAction,
  ) async {
    final hour = _toInt(args['hour']);

    final minute = _toInt(args['minute']);

    if (hour == null ||
        minute == null ||
        hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59) {
      return ToolExecutionResult.error(
        'I couldn\'t understand the alarm time.',
      );
    }

    final label = args['label']?.toString().trim();

    final spokenTime = _formatTime(hour, minute);

    final message = 'Setting an alarm for $spokenTime.';

    if (beforeAction != null) {
      await beforeAction(message);
    }

    try {
      await DeviceActionService.setAlarm(
        hour: hour,
        minute: minute,

        label: label == null || label.isEmpty ? 'Healo Agent' : label,
      );
    } catch (_) {
      return ToolExecutionResult.error(
        'I couldn\'t set the alarm on this phone.',
      );
    }

    return ToolExecutionResult.completed(message);
  }

  // ---------------------------------------------
  // OPEN APP
  // ---------------------------------------------

  static Future<ToolExecutionResult> _openApp(
    Map<String, dynamic> args,
    BeforeActionCallback? beforeAction,
  ) async {
    final appName = args['app_name']?.toString().trim();

    if (appName == null || appName.isEmpty) {
      return ToolExecutionResult.error('Tell me which app you want to open.');
    }

    final apps = await DeviceActionService.getLaunchableApps();
    var matches = apps.where((app) => app.packageName == appName).toList();
    if (matches.isEmpty) {
      matches = matchInstalledApps(appName, apps, allowApproximate: false);
    }
    final fallback = AppRegistry.find(appName);
    // Preserve useful aliases (e.g. "insta") and system intents, while new
    // installed apps are resolved from their real labels without a mapping.
    if (matches.isEmpty && fallback != null) {
      matches = apps
          .where((app) => fallback.packageNames.contains(app.packageName))
          .toList();
    }
    if (matches.isEmpty && fallback == null) {
      matches = matchInstalledApps(appName, apps);
    }
    if (matches.length > 1) {
      final duplicateNames =
          matches.map((app) => app.name).toSet().length != matches.length;
      final choices = matches
          .map(
            (app) => matches.where((other) => other.name == app.name).length > 1
                ? '${app.name} (${app.packageName})'
                : app.name,
          )
          .join(', ');
      return ToolExecutionResult.needsInput(
        'I found $choices. Which app do you mean?'
        '${duplicateNames ? ' For identical names, tell me the package shown.' : ''}',
      );
    }
    if (matches.isEmpty && fallback == null) {
      return ToolExecutionResult.error(
        'I couldn\'t find $appName among your installed apps.',
      );
    }

    final match = matches.isEmpty ? null : matches.single;
    final message = 'Opening ${match?.name ?? fallback!.displayName}.';

    if (beforeAction != null) {
      await beforeAction(message);
    }

    try {
      if (match != null) {
        await DeviceActionService.openApp(packageName: match.packageName);
      } else {
        await DeviceActionService.openAppTarget(
          packageNames: fallback!.packageNames,
          systemTarget: fallback.systemTarget,
        );
      }
    } catch (_) {
      return ToolExecutionResult.error(
        'I couldn\'t open $appName on this phone.',
      );
    }

    return ToolExecutionResult.completed(message);
  }

  // ---------------------------------------------
  // SEND MESSAGE
  // ---------------------------------------------

  static Future<ToolExecutionResult> _sendMessage(
    Map<String, dynamic> args,
    BeforeActionCallback? beforeAction,
  ) async {
    final name = args['name']?.toString().trim();
    final body = args['message']?.toString().trim();
    final channel = _normalizeMessageChannel(args['channel']?.toString());

    if (name == null || name.isEmpty) {
      return ToolExecutionResult.error('Tell me who you want to message.');
    }
    if (body == null || body.isEmpty) {
      return ToolExecutionResult.error('Tell me what message to write.');
    }
    if (channel == null) {
      return ToolExecutionResult.error(
        'Choose WhatsApp or Messages for this message.',
      );
    }

    final permission = await DeviceActionService.requestContactsPermission();
    if (!permission) {
      return ToolExecutionResult.error(
        'I need contacts permission before I can prepare that message.',
      );
    }

    final contacts = await DeviceActionService.findContacts(query: name);
    if (contacts.isEmpty) {
      return ToolExecutionResult.error(
        'I couldn\'t find $name in your contacts.',
      );
    }

    if (contacts.length > 1) {
      return ToolExecutionResult.needsContactSelection(
        'I found ${contacts.length} matches for $name. Choose who should receive the message.',
        contacts,
        pendingContactTool: 'send_message',
        pendingContactArguments: <String, dynamic>{
          'message': body,
          'channel': channel,
        },
      );
    }

    return composeMessageToContact(
      contact: contacts.first,
      messageBody: body,
      channel: channel,
      beforeAction: beforeAction,
    );
  }

  static Future<ToolExecutionResult> composeMessageToContact({
    required ContactMatch contact,
    required String messageBody,
    required String channel,
    BeforeActionCallback? beforeAction,
  }) async {
    var resolvedChannel = channel;
    if (channel == 'whatsapp' &&
        !await DeviceActionService.isWhatsAppAvailable()) {
      resolvedChannel = 'messages';
    }
    final requestedName = resolvedChannel == 'whatsapp'
        ? 'WhatsApp'
        : 'Messages';
    final actionMessage = channel == 'whatsapp' && resolvedChannel == 'messages'
        ? 'WhatsApp is unavailable, so I\'m opening Messages for ${contact.name} instead.'
        : 'Opening $requestedName for ${contact.name} with your message ready.';

    if (beforeAction != null) {
      await beforeAction(actionMessage);
    }

    try {
      final actualChannel = await DeviceActionService.composeMessage(
        phoneNumber: contact.phoneNumber,
        message: messageBody,
        channel: resolvedChannel,
      );
      if (resolvedChannel == 'whatsapp' && actualChannel == 'messages') {
        return ToolExecutionResult.completed(
          'WhatsApp is unavailable, so I opened Messages for ${contact.name} instead.',
        );
      }
      return ToolExecutionResult.completed(actionMessage);
    } catch (_) {
      return ToolExecutionResult.error(
        'I found ${contact.name}, but I couldn\'t open a messaging app.',
      );
    }
  }

  static String? _normalizeMessageChannel(String? raw) {
    final value = raw?.trim().toLowerCase();
    if (value == 'whatsapp' || value == 'whats app') return 'whatsapp';
    if (value == 'messages' ||
        value == 'message' ||
        value == 'sms' ||
        value == 'text') {
      return 'messages';
    }
    return null;
  }

  // ---------------------------------------------
  // HELPERS
  // ---------------------------------------------

  static int? _toInt(dynamic value) {
    if (value is int) {
      return value;
    }

    if (value is num) {
      return value.toInt();
    }

    if (value == null) {
      return null;
    }

    return int.tryParse(value.toString());
  }

  static String _formatDuration(int seconds) {
    if (seconds < 60) {
      return '$seconds second${seconds == 1 ? '' : 's'}';
    }

    if (seconds % 3600 == 0) {
      final hours = seconds ~/ 3600;

      return '$hours hour${hours == 1 ? '' : 's'}';
    }

    if (seconds % 60 == 0) {
      final minutes = seconds ~/ 60;

      return '$minutes minute${minutes == 1 ? '' : 's'}';
    }

    final minutes = seconds ~/ 60;

    final remaining = seconds % 60;

    return '$minutes minutes and $remaining seconds';
  }

  static String _formatTime(int hour, int minute) {
    final period = hour >= 12 ? 'PM' : 'AM';

    var displayHour = hour % 12;

    if (displayHour == 0) {
      displayHour = 12;
    }

    final minuteString = minute.toString().padLeft(2, '0');

    return '$displayHour:$minuteString $period';
  }
}
