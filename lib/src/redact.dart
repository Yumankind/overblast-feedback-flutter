/// What the library writes in place of a value that looks like a secret (contract §6).
const String redactedMarker = '[redacted]';

final RegExp _bearer = RegExp(r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false);

// Our own keys and the shapes most often pasted into a log: OpenAI-style `sk-`, Stripe's
// `sk_live_`/`sk_test_`/`rk_live_`, Overblast's `ob_live_` API keys and `obfk_` feedback keys.
final RegExp _apiKey = RegExp(
  r'\b(?:sk-[A-Za-z0-9_-]{8,}|[sr]k_(?:live|test)_[A-Za-z0-9]{8,}|ob_live_[A-Za-z0-9_-]{8,}|obfk_[A-Za-z0-9]{8,})',
);

// Three base64url segments, the first a JSON header (`{"` encodes as `eyJ`).
final RegExp _jwt = RegExp(r'\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*');

// `password=…`, `token: …`, `"api_key": "…"` and their relatives (`authToken`, `client_secret`).
final RegExp _pair = RegExp(
  r'''(["']?)\b([A-Za-z0-9_-]*(?:password|passwd|pwd|token|secret|api[_-]?key))\1(\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s&,;"'}\]]+)''',
  caseSensitive: false,
);

// 13 to 19 digits, optionally grouped by spaces or dashes, not part of a longer run of digits.
final RegExp _cardish = RegExp(r'(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)');

/// Replaces bearer tokens, API keys, JWTs, `password=`/`token=` values and card numbers (13 to 19
/// digits passing the Luhn check) with `[redacted]`.
///
/// The Luhn check keeps most long numbers (order ids, phone numbers) readable; about one in ten
/// numbers of card length passes it by chance and is blanked too, which is the right way to be
/// wrong here.
String redact(String input) {
  if (input.isEmpty) return input;
  var out = input.replaceAllMapped(_bearer, (m) => '${m[1]} $redactedMarker');
  out = out.replaceAll(_jwt, redactedMarker);
  out = out.replaceAll(_apiKey, redactedMarker);
  out = out.replaceAllMapped(_pair, (m) {
    final quote = m[1] ?? '';
    final value = m[4] ?? '';
    final wrapped = value.startsWith('"')
        ? '"$redactedMarker"'
        : value.startsWith("'")
        ? "'$redactedMarker'"
        : redactedMarker;
    return '$quote${m[2]}$quote${m[3]}$wrapped';
  });
  out = out.replaceAllMapped(_cardish, (m) {
    final digits = m[0]!.replaceAll(RegExp(r'[ -]'), '');
    if (digits.length < 13 || digits.length > 19 || !passesLuhn(digits)) return m[0]!;
    return redactedMarker;
  });
  return out;
}

/// The Luhn checksum card numbers carry.
bool passesLuhn(String digits) {
  var sum = 0;
  var double = false;
  for (var i = digits.length - 1; i >= 0; i--) {
    final c = digits.codeUnitAt(i) - 48;
    if (c < 0 || c > 9) return false;
    var d = c;
    if (double) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    double = !double;
  }
  return sum % 10 == 0;
}
