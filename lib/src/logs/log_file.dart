import 'dart:convert';
import 'dart:typed_data';

import '../log_buffer.dart';
import '../payload.dart' show FeedbackLimits;
import 'gzip_stub.dart' if (dart.library.io) 'gzip_io.dart' as gz;

/// `logFile` (docs/feedback-reports.md §3.5): everything the buffer holds, oldest first, as NDJSON,
/// gzip-compressed where the platform can.
class FeedbackLogFile {
  const FeedbackLogFile({
    required this.bytes,
    required this.gzip,
    required this.lines,
    required this.from,
    required this.to,
    this.cut = 0,
  });

  /// The file as sent, before base64.
  final Uint8List bytes;
  final bool gzip;

  /// Lines in the file, the cut marker included.
  final int lines;
  final int from;
  final int to;

  /// How many of the oldest lines were cut to fit.
  final int cut;

  Map<String, Object?> toJson() => {
    'contentType': 'application/x-ndjson',
    'encoding': gzip ? 'gzip' : 'identity',
    'base64': base64Encode(bytes),
    'lines': lines,
    'from': from,
    'to': to,
  };
}

/// Builds the file from [entries] (oldest first) in at most [maxBytes] as sent. When the whole log
/// does not fit, the oldest lines are cut until it does, and the first line says so in the device's
/// local time: `older lines cut to fit: 12,000 lines from 13:40 to 13:52`. Null when there is
/// nothing to send or not even one line fits.
FeedbackLogFile? buildLogFile(
  List<FeedbackLogEntry> entries, {
  int maxBytes = FeedbackLimits.logFileBytes,
  List<int>? Function(List<int> bytes)? compress,
}) {
  if (entries.isEmpty || maxBytes <= 0) return null;
  final pack = compress ?? gz.gzipBytes;
  final lines = [for (final e in entries) jsonEncode(e.toJson())];
  var start = 0;
  for (var attempt = 0; attempt < 12; attempt++) {
    final out = StringBuffer();
    var count = 0;
    if (start > 0) {
      final marker = FeedbackLogEntry(
        t: entries[start].t,
        level: FeedbackLogLevel.warn,
        src: 'overblast',
        msg:
            'older lines cut to fit: ${groupThousands(start)} lines from ${_clock(entries.first.t)} '
            'to ${_clock(entries[start - 1].t)}',
      );
      out
        ..write(jsonEncode(marker.toJson()))
        ..write('\n');
      count++;
    }
    for (var i = start; i < lines.length; i++) {
      out
        ..write(lines[i])
        ..write('\n');
      count++;
    }
    final raw = utf8.encode(out.toString());
    final packed = pack(raw);
    final bytes = Uint8List.fromList(packed ?? raw);
    if (bytes.length <= maxBytes) {
      return FeedbackLogFile(
        bytes: bytes,
        gzip: packed != null,
        lines: count,
        from: entries[start].t,
        to: entries.last.t,
        cut: start,
      );
    }
    final kept = lines.length - start;
    if (kept <= 1) return null;
    // Cut in proportion to the overshoot, a little more than needed so a retry is rare.
    final keep = (kept * (maxBytes / bytes.length) * 0.92).floor().clamp(1, kept - 1);
    start = lines.length - keep;
  }
  return null;
}

String _clock(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}';
}

/// The excerpt for `logs` (§3.5): every warning and error in the two minutes before [anchor], then
/// the newest other lines, within 500 entries and the byte budget; oldest first.
List<FeedbackLogEntry> selectExcerpt(List<FeedbackLogEntry> all, {required int anchor}) {
  final chosen = List<bool>.filled(all.length, false);
  var count = 0;
  var bytes = 2; // the brackets
  bool take(int i) {
    if (count >= FeedbackLimits.logEntries) return false;
    final size = utf8.encode(jsonEncode(all[i].toJson())).length + 1;
    if (bytes + size > FeedbackLimits.logBytes) return false;
    bytes += size;
    count++;
    chosen[i] = true;
    return true;
  }

  final since = anchor - FeedbackLimits.excerptWindowMs;
  for (var i = all.length - 1; i >= 0; i--) {
    final e = all[i];
    if (e.isUrgent && e.t >= since && e.t <= anchor && !take(i)) break;
  }
  for (var i = all.length - 1; i >= 0; i--) {
    if (chosen[i]) continue;
    if (!take(i)) break;
  }
  return [
    for (var i = 0; i < all.length; i++)
      if (chosen[i]) all[i],
  ];
}
