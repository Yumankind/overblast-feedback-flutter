import 'dart:collection';

import 'payload.dart' show FeedbackLimits, clip;
import 'redact.dart';

/// `logs[].level`.
enum FeedbackLogLevel { debug, info, warn, error }

/// One line of the log, already redacted.
///
/// [repeat] is the total number of times the line occurred, the first included, and [last] the time
/// of the latest occurrence (docs/feedback-reports.md §3.5): five identical lines in a row are one
/// entry with `repeat: 5`. Both are left out of the JSON for a line that occurred once.
class FeedbackLogEntry {
  FeedbackLogEntry({required this.t, required this.level, required String msg, String? src, this.repeat = 1, this.last})
    : msg = clip(msg, FeedbackLimits.logMessage),
      src = src == null || src.isEmpty ? null : clip(src, FeedbackLimits.logSource);

  /// Milliseconds since the epoch.
  final int t;
  final FeedbackLogLevel level;
  final String msg;
  final String? src;
  int repeat;
  int? last;

  /// The buffer's order of arrival, for merging and for the on-disk copy. Zero outside a buffer.
  int seq = 0;

  bool get isUrgent => level == FeedbackLogLevel.warn || level == FeedbackLogLevel.error;

  /// What the entry costs against the buffer's byte budget: its UTF-8 text and a fixed overhead for
  /// the rest of the JSON object.
  late final int byteSize = utf8Length(msg) + (src?.length ?? 0) + 64;

  Map<String, Object?> toJson() => {
    't': t,
    'level': level.name,
    'msg': msg,
    if (src != null) 'src': src,
    if (repeat > 1) 'repeat': repeat,
    if (repeat > 1) 'last': last ?? t,
  };

  static FeedbackLogEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final t = json['t'];
    final msg = json['msg'];
    final src = json['src'];
    final repeat = json['repeat'];
    final last = json['last'];
    final level = FeedbackLogLevel.values.asNameMap()[json['level']];
    if (t is! int || msg is! String || level == null) return null;
    return FeedbackLogEntry(
      t: t,
      level: level,
      msg: msg,
      src: src is String ? src : null,
      repeat: repeat is int && repeat > 1 ? repeat : 1,
      last: last is int ? last : null,
    );
  }
}

/// The UTF-8 length of [s] without encoding it.
int utf8Length(String s) {
  var n = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c < 0x80) {
      n += 1;
    } else if (c < 0x800) {
      n += 2;
    } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
      n += 4;
      i++;
    } else {
      n += 3;
    }
  }
  return n;
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

/// The session's log (docs/feedback-reports.md §3.5), bounded in three ways:
///
/// - **Repeats collapse**: a line identical to the one before (level, source, text) bumps that
///   entry's `repeat` and `last` instead of being stored again. The comparison is on the raw text's
///   length and hash, so a repeat costs no redaction.
/// - **Intake is capped per second**: [perSecond] lines a second, warnings and errors up to
///   [urgentPerSecond]. Past that, lines are counted and dropped unread (no redaction, no copy), and
///   one warning, `1,204 lines dropped in 3 s (too fast)`, marks the gap once the storm has passed
///   (a full second without a drop) or when the log is read.
/// - **A line count and a byte budget**: [maxLines] and [maxBytes]. When either is exceeded, the
///   oldest debug and info lines go first; warnings and errors only when nothing else is left.
///
/// Every kept line is redacted as it arrives, so nothing secret is ever held, let alone sent.
/// [paused] stops intake altogether, which is what the sheet does while it is open (§3.4).
class FeedbackLogBuffer {
  FeedbackLogBuffer({
    this.maxLines = FeedbackLimits.bufferLines,
    this.maxBytes = FeedbackLimits.bufferBytes,
    this.perSecond = 50,
    this.urgentPerSecond = 200,
    DateTime Function()? clock,
    String Function(String)? redactor,
  }) : _clock = clock ?? DateTime.now,
       _redact = redactor ?? redact;

  final int maxLines;
  final int maxBytes;
  final int perSecond;
  final int urgentPerSecond;
  final DateTime Function() _clock;
  final String Function(String) _redact;

  /// Called with each entry stored, and with an entry whose `repeat` just grew (`updated: true`).
  void Function(FeedbackLogEntry entry, {required bool updated})? onAdded;

  bool paused = false;

  final ListQueue<FeedbackLogEntry> _plain = ListQueue();
  final ListQueue<FeedbackLogEntry> _urgent = ListQueue();
  int _bytes = 0;
  int _seq = 0;

  FeedbackLogEntry? _tail;
  int _tailHash = 0;
  int _tailLength = -1;

  int _window = -1;
  int _admitted = 0;
  int _admittedUrgent = 0;
  int _dropped = 0;
  int _dropFirst = 0;
  int _dropLast = 0;

  void add(FeedbackLogLevel level, Object? message, {String? src}) {
    if (paused) return;
    final now = _clock().millisecondsSinceEpoch;
    final text = message?.toString() ?? 'null';
    final source = src == null || src.isEmpty ? null : clip(src, FeedbackLimits.logSource);

    final tail = _tail;
    if (tail != null &&
        tail.level == level &&
        tail.src == source &&
        text.length == _tailLength &&
        text.hashCode == _tailHash) {
      tail.repeat++;
      tail.last = now;
      onAdded?.call(tail, updated: true);
      return;
    }

    final window = now ~/ 1000;
    if (window != _window) {
      _window = window;
      _admitted = 0;
      _admittedUrgent = 0;
    }
    final urgent = level == FeedbackLogLevel.warn || level == FeedbackLogLevel.error;
    final allowed = urgent ? _admittedUrgent < urgentPerSecond : _admitted < perSecond;
    if (!allowed) {
      if (_dropped == 0) _dropFirst = now;
      _dropped++;
      _dropLast = now;
      _tail = null; // the line before this one was not stored, so the next cannot repeat it
      return;
    }
    _admitted++;
    if (urgent) _admittedUrgent++;
    if (_dropped > 0 && now - _dropLast >= 1000) _emitDropMarker();

    // Redact before clipping to the 4,000-character limit, so a secret the limit would cut in half
    // is still recognised whole. The pre-cut at twice the limit only bounds the regex work.
    final entry = FeedbackLogEntry(
      t: now,
      level: level,
      msg: _redact(
        text.length > FeedbackLimits.logMessage * 2 ? text.substring(0, FeedbackLimits.logMessage * 2) : text,
      ),
      src: source,
    );
    _store(entry);
    _tail = entry;
    _tailHash = text.hashCode;
    _tailLength = text.length;
  }

  void _store(FeedbackLogEntry entry) {
    entry.seq = ++_seq;
    (entry.isUrgent ? _urgent : _plain).addLast(entry);
    _bytes += entry.byteSize;
    while ((_plain.length + _urgent.length > maxLines || _bytes > maxBytes) && _plain.length + _urgent.length > 1) {
      final queue = _plain.isNotEmpty ? _plain : _urgent;
      final gone = queue.removeFirst();
      _bytes -= gone.byteSize;
      if (identical(gone, _tail)) _tail = null;
    }
    onAdded?.call(entry, updated: false);
  }

  void _emitDropMarker() {
    final seconds = ((_dropLast - _dropFirst) / 1000).ceil().clamp(1, 1 << 30);
    final marker = FeedbackLogEntry(
      t: _dropLast,
      level: FeedbackLogLevel.warn,
      msg: '${groupThousands(_dropped)} lines dropped in $seconds s (too fast)',
      src: 'overblast',
    );
    _dropped = 0;
    _store(marker);
    _tail = null;
  }

  /// Everything held, oldest first. A pending drop marker is written first, so a report taken in the
  /// middle of a storm says so.
  List<FeedbackLogEntry> get entries => entriesSince(0);

  /// The entries stored after [seq], oldest first.
  List<FeedbackLogEntry> entriesSince(int seq) {
    if (_dropped > 0) _emitDropMarker();
    final out = <FeedbackLogEntry>[];
    // Both queues are in arrival order, so only their tails are read.
    final a = _tailAfter(_plain, seq).iterator;
    final b = _tailAfter(_urgent, seq).iterator;
    var hasA = a.moveNext();
    var hasB = b.moveNext();
    while (hasA || hasB) {
      if (hasA && (!hasB || a.current.seq < b.current.seq)) {
        out.add(a.current);
        hasA = a.moveNext();
      } else {
        out.add(b.current);
        hasB = b.moveNext();
      }
    }
    return out;
  }

  static Iterable<FeedbackLogEntry> _tailAfter(ListQueue<FeedbackLogEntry> queue, int seq) {
    var i = queue.length;
    while (i > 0 && queue.elementAt(i - 1).seq > seq) {
      i--;
    }
    return queue.skip(i);
  }

  int get length => _plain.length + _urgent.length;
  int get bytes => _bytes;

  void clear() {
    _plain.clear();
    _urgent.clear();
    _bytes = 0;
    _tail = null;
    _dropped = 0;
  }
}

/// `1204` as `1,204`.
String groupThousands(int n) {
  final digits = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}
