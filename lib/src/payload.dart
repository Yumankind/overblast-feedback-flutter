import 'dart:convert';
import 'dart:typed_data';

import 'log_buffer.dart';
import 'version.dart';

/// The numbers in the contract (docs/feedback-reports.md §3.1, §3.2), in one place.
///
/// The worker refuses a field that breaks one of these by name (`400 invalid_field`), so the library
/// trims everything to fit before it sends rather than finding out from a refusal. Where the contract
/// says "5 MB" or "256 KB" without saying which megabyte, the smaller reading is used, so the library
/// can never be refused for a number it thought was inside the limit.
abstract final class FeedbackLimits {
  static const int message = 4000;
  static const int reporterName = 120;
  static const int accountRef = 200;
  static const int email = 254;
  static const int screen = 200;
  static const int title = 200;
  static const int shortField = 40; // appVersion, build, os, osVersion, locale, timeZone
  static const int device = 80;
  static const int deviceId = 64;
  static const int extraKeys = 20;
  static const int extraKey = 40;
  static const int extraValue = 200;

  static const int pathSteps = 12;
  static const int pathStep = 80;
  static const int elementType = 80;
  static const int elementId = 120;
  static const int elementLabel = 120;

  static const int screenshotBytes = 5000000;
  static const int logEntries = 500;
  static const int logMessage = 4000;
  static const int logSource = 40;
  static const int logBytes = 250000;
  static const int networkEntries = 100;
  static const int networkUrl = 500;
}

/// What the report is about. The wire spelling is [name].
enum FeedbackCategory {
  bug,
  idea,
  question,
  other;

  String get label => switch (this) {
    FeedbackCategory.bug => 'Bug',
    FeedbackCategory.idea => 'Idea',
    FeedbackCategory.question => 'Question',
    FeedbackCategory.other => 'Other',
  };
}

/// The person filing the report, as the integrator knows them. Every field is optional.
///
/// [email] is the only one that changes what the worker makes: with it, the task carries an email
/// conversation the team can answer from; without it, there is nobody to answer.
class FeedbackReporter {
  const FeedbackReporter({this.email, this.name, this.accountRef});

  final String? email;
  final String? name;

  /// The integrator's own id for this person (a customer id, a user id), so the team can find them.
  final String? accountRef;

  bool get isEmpty => _blank(email) && _blank(name) && _blank(accountRef);

  FeedbackReporter copyWith({String? email, String? name, String? accountRef}) =>
      FeedbackReporter(email: email ?? this.email, name: name ?? this.name, accountRef: accountRef ?? this.accountRef);

  Map<String, Object?>? toJson() {
    final out = <String, Object?>{};
    final e = email?.trim();
    if (e != null && e.isNotEmpty && isPlausibleEmail(e)) out['email'] = clip(e, FeedbackLimits.email);
    _put(out, 'name', name, FeedbackLimits.reporterName);
    _put(out, 'accountRef', accountRef, FeedbackLimits.accountRef);
    return out.isEmpty ? null : out;
  }
}

/// A loose address check: one `@`, something either side, a dot in the domain, no spaces. The worker
/// is the authority; this only stops an obvious typo from costing the reporter a refusal.
bool isPlausibleEmail(String value) =>
    RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.trim()) && value.trim().length <= FeedbackLimits.email;

/// The logical size of the app's surface and its device pixel ratio.
class FeedbackViewport {
  const FeedbackViewport({required this.width, required this.height, required this.devicePixelRatio});

  final double width;
  final double height;
  final double devicePixelRatio;

  Map<String, Object?> toJson() => {'w': width.round(), 'h': height.round(), 'dpr': _round(devicePixelRatio, 2)};
}

/// Where the report happened. `platform` is always `flutter`; `url` and `userAgent` are the web
/// library's and are never sent from here.
class FeedbackContext {
  const FeedbackContext({
    this.screen,
    this.title,
    this.appVersion,
    this.build,
    this.os,
    this.osVersion,
    this.device,
    this.locale,
    this.timeZone,
    this.viewport,
    this.deviceId,
    this.extra = const {},
  });

  final String? screen;
  final String? title;
  final String? appVersion;
  final String? build;
  final String? os;
  final String? osVersion;
  final String? device;
  final String? locale;
  final String? timeZone;
  final FeedbackViewport? viewport;
  final String? deviceId;
  final Map<String, String> extra;

  Map<String, Object?> toJson() {
    final out = <String, Object?>{'platform': 'flutter'};
    _put(out, 'screen', screen, FeedbackLimits.screen);
    _put(out, 'title', title, FeedbackLimits.title);
    _put(out, 'appVersion', appVersion, FeedbackLimits.shortField);
    _put(out, 'build', build, FeedbackLimits.shortField);
    _put(out, 'os', os, FeedbackLimits.shortField);
    _put(out, 'osVersion', osVersion, FeedbackLimits.shortField);
    _put(out, 'device', device, FeedbackLimits.device);
    _put(out, 'locale', locale, FeedbackLimits.shortField);
    _put(out, 'timeZone', timeZone, FeedbackLimits.shortField);
    if (viewport != null) out['viewport'] = viewport!.toJson();
    out['sdk'] = {'name': sdkName, 'version': sdkVersion};
    final id = deviceId;
    if (id != null && isValidDeviceId(id)) out['deviceId'] = id;
    final cleanExtra = <String, String>{};
    for (final entry in extra.entries) {
      if (cleanExtra.length >= FeedbackLimits.extraKeys) break;
      final key = clip(entry.key.trim(), FeedbackLimits.extraKey);
      if (key.isEmpty) continue;
      cleanExtra[key] = clip(entry.value, FeedbackLimits.extraValue);
    }
    if (cleanExtra.isNotEmpty) out['extra'] = cleanExtra;
    return out;
  }
}

/// `context.deviceId`: 1 to 64 of `[A-Za-z0-9_-]`.
bool isValidDeviceId(String id) => RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id);

/// A rectangle as fractions of the viewport, each in 0..1, with the box kept inside the viewport.
class FeedbackRect {
  FeedbackRect({required double x, required double y, required double w, required double h})
    : x = _unit(x),
      y = _unit(y),
      w = _unit(w).clamp(0.0, 1.0 - _unit(x)).toDouble(),
      h = _unit(h).clamp(0.0, 1.0 - _unit(y)).toDouble();

  final double x;
  final double y;
  final double w;
  final double h;

  Map<String, Object?> toJson() => {'x': _round(x, 4), 'y': _round(y, 4), 'w': _round(w, 4), 'h': _round(h, 4)};

  static double _unit(double v) => v.isNaN ? 0.0 : v.clamp(0.0, 1.0).toDouble();
}

/// The `kind: "native"` element of §3.2: the widget the reporter pointed at.
class NativeAnchor {
  NativeAnchor({
    required List<String> path,
    required this.type,
    this.id,
    this.label,
    required this.rect,
    required this.viewportWidth,
    required this.viewportHeight,
  }) : path = List.unmodifiable(path);

  /// Widget type names from the outside in, framework plumbing left out, the target last.
  final List<String> path;
  final String type;

  /// A `ValueKey`'s value or a `Semantics(identifier:)`.
  final String? id;

  /// The semantics label, a tooltip, or the visible text. Never a text field's value.
  final String? label;
  final FeedbackRect rect;
  final double viewportWidth;
  final double viewportHeight;

  Map<String, Object?> toJson() {
    final steps = path.map((s) => clip(s, FeedbackLimits.pathStep)).where((s) => s.isNotEmpty).toList();
    final kept = steps.length > FeedbackLimits.pathSteps
        ? steps.sublist(steps.length - FeedbackLimits.pathSteps)
        : steps;
    final out = <String, Object?>{'kind': 'native', 'path': kept, 'type': clip(type, FeedbackLimits.elementType)};
    _put(out, 'id', id, FeedbackLimits.elementId);
    _put(out, 'label', label, FeedbackLimits.elementLabel);
    out['rect'] = rect.toJson();
    out['viewport'] = {'w': viewportWidth.round(), 'h': viewportHeight.round()};
    return out;
  }
}

/// The image the reporter chose to attach.
class FeedbackScreenshot {
  const FeedbackScreenshot({required this.bytes, this.contentType = 'image/png', this.highlighted = false});

  final Uint8List bytes;
  final String contentType;

  /// The selected element's box is drawn on the image.
  final bool highlighted;

  Map<String, Object?> toJson() => {
    'contentType': contentType,
    'base64': base64Encode(bytes),
    'highlighted': highlighted,
  };
}

/// One whole report, ready to become the request body.
class FeedbackPayload {
  const FeedbackPayload({
    required this.message,
    this.category = FeedbackCategory.bug,
    this.reporter,
    required this.context,
    this.element,
    this.screenshot,
    this.logs = const [],
    this.network = const [],
  });

  final String message;
  final FeedbackCategory category;
  final FeedbackReporter? reporter;
  final FeedbackContext context;
  final NativeAnchor? element;
  final FeedbackScreenshot? screenshot;
  final List<FeedbackLogEntry> logs;
  final List<FeedbackNetworkEntry> network;

  /// The body of `POST /v1/feedback`: exactly the contract's keys, nulls and empty lists left out,
  /// every string trimmed to its limit.
  ///
  /// Throws [ArgumentError] for an empty message and for a screenshot over 5 MB: both are the
  /// caller's to fix (the sheet never lets either through), and trimming them silently would send
  /// something the reporter did not see.
  Map<String, Object?> toJson() {
    final text = message.trim();
    if (text.isEmpty) throw ArgumentError.value(message, 'message', 'must not be empty');
    final shot = screenshot;
    if (shot != null && shot.bytes.length > FeedbackLimits.screenshotBytes) {
      throw ArgumentError.value(shot.bytes.length, 'screenshot', 'is over ${FeedbackLimits.screenshotBytes} bytes');
    }
    final out = <String, Object?>{'v': 1, 'message': clip(text, FeedbackLimits.message), 'category': category.name};
    final who = reporter?.toJson();
    if (who != null) out['reporter'] = who;
    out['context'] = context.toJson();
    if (element != null) out['element'] = element!.toJson();
    if (shot != null) out['screenshot'] = shot.toJson();
    final logJson = fitLogs(logs);
    if (logJson.isNotEmpty) out['logs'] = logJson;
    final net = network.length > FeedbackLimits.networkEntries
        ? network.sublist(network.length - FeedbackLimits.networkEntries)
        : network;
    if (net.isNotEmpty) out['network'] = [for (final n in net) n.toJson()];
    return out;
  }
}

/// The newest log entries that fit both caps (500 entries, the byte budget), oldest first.
List<Map<String, Object?>> fitLogs(List<FeedbackLogEntry> logs) {
  final newestFirst = <Map<String, Object?>>[];
  var bytes = 2; // the brackets
  for (var i = logs.length - 1; i >= 0 && newestFirst.length < FeedbackLimits.logEntries; i--) {
    final json = logs[i].toJson();
    final size = utf8.encode(jsonEncode(json)).length + 1;
    if (bytes + size > FeedbackLimits.logBytes) break;
    bytes += size;
    newestFirst.add(json);
  }
  return newestFirst.reversed.toList();
}

/// Cuts [value] to at most [max] UTF-16 code units without splitting a surrogate pair, which is how
/// the worker (JavaScript) counts characters.
String clip(String value, int max) {
  if (value.length <= max) return value;
  var end = max;
  final unit = value.codeUnitAt(end - 1);
  if (unit >= 0xD800 && unit <= 0xDBFF) end -= 1;
  return value.substring(0, end);
}

void _put(Map<String, Object?> out, String key, String? value, int max) {
  final v = value?.trim();
  if (v == null || v.isEmpty) return;
  out[key] = clip(v, max);
}

bool _blank(String? s) => s == null || s.trim().isEmpty;

double _round(double v, int places) {
  var f = 1.0;
  for (var i = 0; i < places; i++) {
    f *= 10;
  }
  return (v * f).roundToDouble() / f;
}
