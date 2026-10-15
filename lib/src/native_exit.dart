import 'package:flutter/services.dart';

import 'crash.dart';
import 'verification/keys.dart' show deviceChannel;

/// How the platform says the app's last process ended (docs/feedback-reports.md §3.4), from the
/// plugin's `lastExit`: Android's `ApplicationExitInfo` on API 30+ (`exit_info`), iOS MetricKit's
/// newest `MXCrashDiagnostic` (`metrickit`). The iOS side hands a diagnostic over once and forgets
/// it. Null when the platform says nothing, has no implementation, or the exit was an ordinary one.
Future<FeedbackCrash?> readLastExit([MethodChannel channel = deviceChannel]) async {
  try {
    final map = await channel.invokeMapMethod<String, Object?>('lastExit');
    return FeedbackCrash.fromJson(map);
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}
