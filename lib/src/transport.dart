import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// The public door (contract §3).
final Uri defaultFeedbackEndpoint = Uri.parse('https://brain.deployd.network/v1/feedback');

/// What the worker answered when it filed the report.
class FeedbackResult {
  const FeedbackResult({
    this.id,
    this.taskId,
    this.conversationId,
    this.notice,
    this.storageFull = false,
    this.known = false,
  });

  /// `fbr_...`.
  final String? id;
  final String? taskId;

  /// Present only when the reporter gave an email address.
  final String? conversationId;

  /// The workspace was out of storage (`507 storage_full`): the task was filed without its files.
  final bool storageFull;

  /// A sentence for the reporter when the report was filed with a caveat.
  final String? notice;

  /// The report joined an issue the team already has (docs/feedback-reports.md §3.3, §9.2). The
  /// sheet then thanks the person with "Thanks. We already know about this one and we're on it.",
  /// and nothing else about the issue is ever shown.
  final bool known;
}

/// A refusal, or a report that never reached the worker.
///
/// [message] is the worker's own `error` sentence when it sent one, which the contract says a
/// library may show the reporter as is; otherwise a sentence of ours for the same [code].
class OverblastFeedbackException implements Exception {
  const OverblastFeedbackException({
    required this.status,
    required this.code,
    required this.message,
    this.field,
    this.retryAfter,
    this.savedForLater = false,
  });

  /// The HTTP status, or 0 when there was no answer at all.
  final int status;

  /// The contract's `code` (`invalid_field`, `rate_limited`, ...), or `network`, or `http_<status>`.
  final String code;
  final String message;

  /// For `invalid_field`: which field.
  final String? field;

  /// For `rate_limited`: seconds before trying again.
  final int? retryAfter;

  /// The report was kept on the device and [OverblastFeedbackController.retryPending] will send it.
  final bool savedForLater;

  bool get isRateLimited => status == 429;
  bool get isNetwork => status == 0;

  OverblastFeedbackException copyWith({bool? savedForLater, String? message}) => OverblastFeedbackException(
    status: status,
    code: code,
    message: message ?? this.message,
    field: field,
    retryAfter: retryAfter,
    savedForLater: savedForLater ?? this.savedForLater,
  );

  @override
  String toString() => 'OverblastFeedbackException($status $code${field == null ? '' : ' $field'}): $message';
}

/// The sentence shown when the worker sent none, by `code`.
String fallbackSentence(String code, {String? field, int status = 0}) => switch (code) {
  'invalid_field' =>
    field == null ? 'Part of the report was not accepted.' : 'Part of the report was not accepted ($field).',
  'unknown_key' => "This app's feedback key is not recognised, so the report could not be sent.",
  'key_disabled' => 'Feedback is switched off for this app at the moment.',
  'origin_not_allowed' => 'Feedback is not accepted from here.',
  'storage_full' => 'Your report was filed, but the screenshot could not be stored.',
  'too_large' => 'The report is too large to send. Try again without the screenshot.',
  'rate_limited' => 'Too many reports from this device for now. Try again later.',
  'misconfigured' => 'Feedback is not set up correctly on the server. Try again later.',
  'network' => 'The report could not be sent. Check the connection and try again.',
  'category_not_accepted' => 'This app does not take this kind of report.',
  'device_required' => 'This app only accepts reports from a verified device, and this one could not be verified.',
  'unknown_device' || 'device_signature_invalid' => 'This device could not be verified. Try again.',
  _ => 'The report could not be sent (HTTP $status). Try again later.',
};

/// Sends one body to the door and turns the answer into a [FeedbackResult] or an
/// [OverblastFeedbackException]. It never retries: what to do with a refusal is the caller's.
class FeedbackTransport {
  FeedbackTransport({
    required this.feedbackKey,
    Uri? endpoint,
    http.Client? client,
    this.timeout = const Duration(seconds: 45),
  }) : endpoint = endpoint ?? defaultFeedbackEndpoint,
       _client = client;

  final String feedbackKey;
  final Uri endpoint;
  final Duration timeout;
  final http.Client? _client;

  Future<FeedbackResult> send(Map<String, Object?> body) => sendBytes(utf8.encode(jsonEncode(body)));

  /// Sends [body] exactly as given, with [headers] beside the key's (a signed report's three device
  /// headers, §8.3, which cover these very bytes).
  Future<FeedbackResult> sendBytes(List<int> body, {Map<String, String> headers = const {}}) async {
    final client = _client ?? http.Client();
    final http.Response response;
    try {
      response = await client
          .post(
            endpoint,
            headers: {
              ...headers,
              'Content-Type': 'application/json',
              'X-Overblast-Feedback-Key': feedbackKey,
            },
            body: body,
          )
          .timeout(timeout);
    } on Exception {
      throw OverblastFeedbackException(status: 0, code: 'network', message: fallbackSentence('network'));
    } finally {
      if (_client == null) client.close();
    }
    return interpretResponse(response.statusCode, response.body, headers: response.headers);
  }
}

/// The answer table of §3.3. Public so the mapping is testable without a client.
FeedbackResult interpretResponse(int status, String body, {Map<String, String> headers = const {}}) {
  Map<String, Object?> json = const {};
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, Object?>) json = decoded;
  } on FormatException {
    // A proxy's HTML error page, say. The status still says what happened.
  }
  String? str(String key) => json[key] is String ? json[key] as String : null;

  if (status >= 200 && status < 300) {
    return FeedbackResult(
      id: str('id'),
      taskId: str('taskId'),
      conversationId: str('conversationId'),
      known: json['known'] == true,
    );
  }
  final code = str('code') ?? (status == 429 ? 'rate_limited' : 'http_$status');
  final field = str('field');
  final sentence = (str('error')?.trim().isNotEmpty ?? false)
      ? str('error')!.trim()
      : fallbackSentence(code, field: field, status: status);
  if (status == 507) {
    // §3.3: "the task is still filed, without the screenshot". Filed is filed; the reporter is told.
    return FeedbackResult(
      id: str('id'),
      taskId: str('taskId'),
      conversationId: str('conversationId'),
      storageFull: true,
      notice: sentence,
      known: json['known'] == true,
    );
  }
  int? retryAfter;
  final ra = json['retryAfter'];
  if (ra is num) {
    retryAfter = ra.ceil();
  } else {
    retryAfter = int.tryParse(headers['retry-after'] ?? '');
  }
  throw OverblastFeedbackException(
    status: status,
    code: code,
    message: sentence,
    field: field,
    retryAfter: status == 429 ? (retryAfter ?? 3600) : retryAfter,
  );
}
