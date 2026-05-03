import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';

class ActionManager {
  static const Set<String> _supportedActions = {
    'VOLUME_UP',
    'VOLUME_DOWN',
    'VOLUME_MUTE',
    'CONNECTIVITY_PANEL',
  };

  /// Scans the AI text for <ACTION> tags and executes them.
  static Future<void> processActions(String text) async {
    final actionRegex = RegExp(r'<ACTION>(.*?)<\/ACTION>');
    final matches = actionRegex.allMatches(text);

    for (final match in matches) {
      final action = match.group(1);
      if (action != null) {
        await _executeAction(action);
      }
    }
  }

  static Future<void> processActionList(List<dynamic> actions) async {
    for (final item in actions) {
      if (item is! String) {
        continue;
      }

      final normalized = item.trim().toUpperCase();
      if (_supportedActions.contains(normalized)) {
        await _executeAction(normalized);
      }
    }
  }

  static Future<void> _executeAction(String action) async {
    print('Executing Jarvis Action: $action');
    
    switch (action) {
      case 'VOLUME_UP':
        double? currentVol = await FlutterVolumeController.getVolume();
        if (currentVol != null) {
          // User requested 20% steps
          await FlutterVolumeController.setVolume((currentVol + 0.2).clamp(0.0, 1.0));
        }
        break;
        
      case 'VOLUME_DOWN':
        double? currentVol = await FlutterVolumeController.getVolume();
        if (currentVol != null) {
          await FlutterVolumeController.setVolume((currentVol - 0.2).clamp(0.0, 1.0));
        }
        break;
        
      case 'VOLUME_MUTE':
        await FlutterVolumeController.setVolume(0.0);
        break;
        
      case 'CONNECTIVITY_PANEL':
        // Android 15 Connectivity Panel Intent (Zero-Touch target)
        final intent = AndroidIntent(
          action: 'android.settings.WIFI_SETTINGS',
          flags: [Flag.FLAG_ACTIVITY_NEW_TASK],
        );
        await intent.launch();
        break;
        
      default:
        print('Unknown action: $action');
    }
  }
}
