import '../models/tool_execution_result.dart';
import '../services/device_action_service.dart';
import 'app_registry.dart';

typedef BeforeActionCallback = Future<void> Function(String message);

class ToolExecutor {
  static Future<ToolExecutionResult> execute({
    required String tool,

    required Map<String, dynamic> arguments,

    BeforeActionCallback? onBeforeAction,
  }) async {
    try {
      switch (tool) {
        case 'set_alarm':
          return await _setAlarm(arguments, onBeforeAction);

        case 'set_timer':
          return await _setTimer(arguments, onBeforeAction);

        case 'open_app':
          return await _openApp(arguments, onBeforeAction);

        case 'call_contact':
          return await _callContact(arguments, onBeforeAction);

        default:
          return ToolExecutionResult.error('That action isn\'t available yet.');
      }
    } catch (e) {
      return ToolExecutionResult.error('I couldn\'t complete that action.');
    }
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

    final packageName = AppRegistry.getPackageName(appName);

    if (packageName == null) {
      return ToolExecutionResult.error(
        'I don\'t know how to open $appName yet.',
      );
    }

    final message = 'Opening $appName.';

    if (beforeAction != null) {
      await beforeAction(message);
    }

    try {
      await DeviceActionService.openApp(packageName: packageName);
    } catch (_) {
      return ToolExecutionResult.error(
        'I couldn\'t open $appName on this phone.',
      );
    }

    return ToolExecutionResult.completed(message);
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
