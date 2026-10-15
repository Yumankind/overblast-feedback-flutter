import 'payload.dart' show FeedbackLimits, clip;
import 'redact.dart';

/// `context.trigger` (docs/feedback-reports.md §3.1): what opened the report. [wire] is the
/// contract's spelling.
enum FeedbackTrigger {
  shake('shake'),
  button('button'),
  shortcut('shortcut'),
  agent('agent'),
  api('api'),
  relaunch('relaunch'),
  errorPrompt('error_prompt');

  const FeedbackTrigger(this.wire);
  final String wire;
}

/// `crash.kind`.
enum FeedbackCrashKind { crash, exception, oom, killed, unknown }

/// `crash.source`: who said how the previous session ended.
enum FeedbackCrashSource {
  /// iOS MetricKit's `MXCrashDiagnostic`, delivered at a later launch.
  metrickit('metrickit'),

  /// Android's `ApplicationExitInfo` (API 30+).
  exitInfo('exit_info'),

  /// The library's own error hooks: here, Dart errors through `FlutterError.onError` and
  /// `PlatformDispatcher.onError`.
  handler('handler'),

  /// Only the session marker: the session never closed and nothing said why.
  marker('marker');

  const FeedbackCrashSource(this.wire);
  final String wire;
}

/// `crash` (§3.4): how the PREVIOUS session ended, when it ended unexpectedly. [message] and [stack]
/// are redacted like logs and cut to their limits when sent.
class FeedbackCrash {
  const FeedbackCrash({required this.kind, required this.source, this.at, this.message, this.stack});

  final FeedbackCrashKind kind;
  final FeedbackCrashSource source;

  /// Milliseconds since the epoch, when known.
  final int? at;
  final String? message;
  final String? stack;

  Map<String, Object?> toJson() {
    final out = <String, Object?>{'kind': kind.name};
    if (at != null && at! > 0) out['at'] = at;
    final m = message?.trim();
    if (m != null && m.isNotEmpty) out['message'] = clip(redact(m), FeedbackLimits.crashMessage);
    final st = stack?.trim();
    if (st != null && st.isNotEmpty) out['stack'] = clip(redact(st), FeedbackLimits.crashStack);
    out['source'] = source.wire;
    return out;
  }

  static FeedbackCrash? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = FeedbackCrashKind.values.asNameMap()[json['kind']];
    final source = FeedbackCrashSource.values.where((s) => s.wire == json['source']).firstOrNull;
    if (kind == null || source == null) return null;
    final at = json['at'];
    final message = json['message'];
    final stack = json['stack'];
    return FeedbackCrash(
      kind: kind,
      source: source,
      at: at is num ? at.toInt() : null,
      message: message is String ? message : null,
      stack: stack is String ? stack : null,
    );
  }
}
