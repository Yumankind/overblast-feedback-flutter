import 'package:http/http.dart' as http;

import 'controller.dart';

/// An `http.Client` that records each call's method, URL (no query string, no fragment), status
/// and duration into the feedback log's network list. Bodies and headers are never read.
///
/// ```dart
/// final client = OverblastHttpClient(http.Client());
/// ```
///
/// Records into [feedback], or into the most recently created controller when none is given.
class OverblastHttpClient extends http.BaseClient {
  OverblastHttpClient(this._inner, {OverblastFeedbackController? feedback}) : _feedback = feedback;

  final http.Client _inner;
  final OverblastFeedbackController? _feedback;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final watch = Stopwatch()..start();
    try {
      final response = await _inner.send(request);
      _record(request, response.statusCode, watch.elapsedMilliseconds);
      return response;
    } catch (_) {
      _record(request, 0, watch.elapsedMilliseconds);
      rethrow;
    }
  }

  void _record(http.BaseRequest request, int status, int ms) {
    (_feedback ?? OverblastFeedbackController.current)?.recordNetwork(request.method, request.url, status, ms);
  }

  @override
  void close() => _inner.close();
}
