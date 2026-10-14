import 'dart:collection';

import 'payload.dart' show FeedbackLimits, clip;
import 'redact.dart';

/// `logs[].level`.
enum FeedbackLogLevel { debug, info, warn, error }

/// One line of the session's log, already redacted.
class FeedbackLogEntry {
  FeedbackLogEntry({required this.t, required this.level, required String msg, String? src})
    : msg = clip(msg, FeedbackLimits.logMessage),
      src = src == null || src.isEmpty ? null : clip(src, FeedbackLimits.logSource);

  /// Milliseconds since the epoch.
  final int t;
  final FeedbackLogLevel level;
  final String msg;
  final String? src;

  Map<String, Object?> toJson() => {'t': t, 'level': level.name, 'msg': msg, if (src != null) 'src': src};
}

/// One network call the app made: no body, no headers, no query string (contract §6).
class FeedbackNetworkEntry {
  FeedbackNetworkEntry({
    required this.t,
    required String method,
    required String url,
    required this.status,
    required this.ms,
  }) : method = clip(method.toUpperCase(), 16),
       url = clip(redact(stripUrl(url)), FeedbackLimits.networkUrl);

  final int t;
  final String method;
  final String url;

  /// The HTTP status, or 0 when the call never got an answer.
  final int status;
  final int ms;

  Map<String, Object?> toJson() => {'t': t, 'method': method, 'url': url, 'status': status, 'ms': ms};
}

/// [url] without its query string and fragment, at most 500 characters.
String stripUrl(String url) {
  var cut = url;
  final q = cut.indexOf('?');
  if (q >= 0) cut = cut.substring(0, q);
  final h = cut.indexOf('#');
  if (h >= 0) cut = cut.substring(0, h);
  // A user:password@ in the authority is a credential too.
  cut = cut.replaceFirstMapped(RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@]*@'), (m) => m[1]!);
  return clip(cut, FeedbackLimits.networkUrl);
}

/// A fixed-size buffer that forgets its oldest entry when full.
class RingBuffer<T> {
  RingBuffer(this.capacity) : assert(capacity > 0);

  final int capacity;
  final ListQueue<T> _items = ListQueue<T>();

  int get length => _items.length;

  void add(T item) {
    if (_items.length >= capacity) _items.removeFirst();
    _items.addLast(item);
  }

  /// A copy, oldest first.
  List<T> toList() => List<T>.of(_items);

  void clear() => _items.clear();
}

/// The session's log: the last [capacity] lines, each redacted as it arrives so nothing secret is
/// ever held, let alone sent.
class FeedbackLogBuffer {
  FeedbackLogBuffer({int capacity = FeedbackLimits.logEntries, DateTime Function()? clock})
    : _ring = RingBuffer<FeedbackLogEntry>(capacity),
      _clock = clock ?? DateTime.now;

  final RingBuffer<FeedbackLogEntry> _ring;
  final DateTime Function() _clock;

  void add(FeedbackLogLevel level, Object? message, {String? src}) {
    final text = message?.toString() ?? 'null';
    // Redact before clipping to the 4,000-character limit, so a secret the limit would cut in half
    // is still recognised whole. The pre-cut at twice the limit only bounds the regex work.
    _ring.add(
      FeedbackLogEntry(
        t: _clock().millisecondsSinceEpoch,
        level: level,
        msg: redact(
          text.length > FeedbackLimits.logMessage * 2 ? text.substring(0, FeedbackLimits.logMessage * 2) : text,
        ),
        src: src,
      ),
    );
  }

  List<FeedbackLogEntry> get entries => _ring.toList();
  int get length => _ring.length;
  void clear() => _ring.clear();
}
