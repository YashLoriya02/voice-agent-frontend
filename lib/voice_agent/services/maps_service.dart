import 'dart:async';

import '../models/message_readout.dart';
import '../models/tool_execution_result.dart';
import 'device_action_service.dart';
import 'voice_agent_api_service.dart';

/// Uses only the installed Google Maps application, never a routing HTTP API.
class MapsService {
  static int _generation = 0;
  static bool _active = false;
  static int _routeChoices = 0;
  static DateTime? _choiceTime;

  static Future<Map<String, dynamic>> status() =>
      DeviceActionService.deviceControl('installedMapsStatus', const {});
  static Future<void> openReaderSettings() async {
    await DeviceActionService.deviceControl('openMapsReaderSettings', const {});
  }

  static void cancel() {
    _generation++;
    if (_active) {
      _active = false;
      unawaited(
        DeviceActionService.deviceControl(
          'stopInstalledMapsRoute',
          const {},
        ).catchError((_) => <String, dynamic>{}),
      );
    }
  }

  static Future<ToolExecutionResult> execute(
    Map<String, dynamic> args, {
    Future<void> Function(MessageReadout)? onLocalReadout,
  }) async {
    final destination = args['destination']?.toString().trim() ?? '';
    var readCurrent = args['read_current'] ?? false;
    final startNavigation = args['start_navigation'] ?? false;
    final choice = args['choice'];
    if (readCurrent is! bool ||
        startNavigation is! bool ||
        destination.length > 250 ||
        (startNavigation && (readCurrent || choice != null))) {
      return ToolExecutionResult.error(
        'Tell me a destination name and area, or ask to read the current Maps route.',
      );
    }
    if (choice != null) {
      if (choice is! int ||
          choice < 1 ||
          choice > _routeChoices ||
          _choiceTime == null ||
          DateTime.now().difference(_choiceTime!).inMinutes >= 5) {
        return ToolExecutionResult.needsInput(
          'The previous Maps route choices are unavailable. Ask me to read the current Maps route again.',
        );
      }
      readCurrent = true;
    }
    if (!readCurrent && destination.isEmpty) {
      return ToolExecutionResult.needsInput(
        'Where would you like to drive? Tell me the place name and area or address.',
      );
    }

    if (startNavigation) {
      final data = await DeviceActionService.deviceControl(
        'getInstalledMapsRoute',
        {
          'destination': destination,
          'readCurrent': false,
          'startNavigation': true,
        },
      );
      return data['success'] == true
          ? ToolExecutionResult.completed(
              data['message']?.toString() ??
                  'Opening Google Maps navigation from your current location.',
              speakResult: true,
            )
          : ToolExecutionResult.error(
              data['message']?.toString() ??
                  'Could not open Google Maps navigation.',
            );
    }

    // Existing provider callback prevents the microphone from uploading the
    // offline readout. Run it before this request owns native Maps reading.
    await onLocalReadout?.call(
      MessageReadout(
        intro: readCurrent
            ? 'Reading the displayed Google Maps route.'
            : 'Opening driving directions in Google Maps.',
        channel: 'maps',
      ),
    );
    final current = ++_generation;
    _active = true;
    try {
      final data = await DeviceActionService.deviceControl(
        'getInstalledMapsRoute',
        {
          'destination': destination,
          'readCurrent': readCurrent,
          'choice': ?choice,
        },
      );
      if (current != _generation) {
        throw const VoiceAgentRequestCancelled();
      }
      _active = false;
      if (data['status'] == 'opened') {
        return ToolExecutionResult.completed(
          data['message']?.toString() ?? 'Google Maps directions are open.',
          speakResult: true,
        );
      }
      if (data['status'] == 'needs_input') {
        final routes = data['routes'];
        if (routes is List && routes.isNotEmpty) {
          _routeChoices = routes.length;
          _choiceTime = DateTime.now();
          final question =
              'Google Maps shows several driving routes. ${[for (var i = 0; i < routes.length; i++) '${i + 1}. ${routes[i]['distanceText']}, ${routes[i]['durationText']}'].join('\n')}\nWhich route number should I read?';
          final readout = MessageReadout(intro: question, channel: 'maps');
          await onLocalReadout?.call(readout);
          if (data['spokenLocally'] != true) {
            _active = true;
            final spoken = await DeviceActionService.deviceControl(
              'speakInstalledMapsRoute',
              {'text': question},
            );
            if (spoken['success'] != true) {
              return ToolExecutionResult.error(
                spoken['message']?.toString() ??
                    'On-device Maps speech failed.',
              );
            }
          }
          return ToolExecutionResult(
            status: ToolExecutionStatus.needsInput,
            message: question,
            messageReadout: readout,
            spokenLocally: true,
            containsMessageData: true,
          );
        }
        return ToolExecutionResult.needsInput(
          data['message']?.toString() ?? 'Choose a driving route in Google Maps, then ask me to read the current Maps route.',
        );
      }
      if (data['success'] != true) {
        return ToolExecutionResult.error(
          data['message']?.toString() ??
              'Could not read driving estimates from Google Maps.',
        );
      }
      final row = data['route'];
      if (row is! Map ||
          row['distanceMeters'] is! num ||
          row['durationSeconds'] is! num ||
          !(row['distanceMeters'] as num).isFinite ||
          !(row['durationSeconds'] as num).isFinite ||
          row['distanceMeters'] < 0 ||
          row['durationSeconds'] <= 0 ||
          row['distanceText'] is! String ||
          row['durationText'] is! String) {
        return ToolExecutionResult.error(
          'Maps did not expose valid distance and time. Choose the driving route in Maps and try again.',
        );
      }
      _routeChoices = 0;
      _choiceTime = null;
      final answer =
          'Google Maps shows ${row['distanceText']} and ${row['durationText']} by car for the displayed route. This is an estimate and can change.';
      final readout = MessageReadout(
        intro: answer,
        channel: 'maps',
        footer:
            'Source: installed Google Maps app. No Maps API key or billing.',
      );
      await onLocalReadout?.call(readout);
      if (data['spokenLocally'] != true) {
        _active = true;
        final spoken = await DeviceActionService.deviceControl(
          'speakInstalledMapsRoute',
          {'text': answer},
        );
        if (spoken['success'] != true) {
          return ToolExecutionResult.error(
            spoken['message']?.toString() ?? 'On-device Maps speech failed.',
          );
        }
      }
      return ToolExecutionResult(
        status: ToolExecutionStatus.completed,
        message: readout.displayText,
        messageReadout: readout,
        spokenLocally: true,
        containsMessageData: true,
      );
    } finally {
      _active = false;
    }
  }
}
