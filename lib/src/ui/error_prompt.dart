import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../config.dart';
import '../store/store.dart';
import 'layer.dart';

/// How a shown prompt ended.
enum ErrorPromptOutcome {
  /// The person pressed Report.
  report,

  /// The person closed it. Two in a row and it stays away for seven days.
  dismissed,

  /// It went by itself after about eight seconds. Not a close.
  timedOut,
}

/// When the error prompt may show (docs/feedback-reports.md §3.6), apart from how it looks.
///
/// [notice] is called with each error the controller counts. The first one in a quiet moment starts
/// a wait of at least a second (so two errors a second apart are one prompt) and until ten seconds
/// after start; then, while [blocked] says the person is typing, the sheet or the crash offer is up or
/// the app is not in the foreground, it looks again every half second for up to thirty seconds and
/// then gives up. It shows at most once per session, at most once per `minHoursBetween` on the device,
/// and not for seven days after two closes in a row. The device-wide record is the store's
/// `error_prompt` state.
class ErrorPromptGate {
  ErrorPromptGate({
    required this.now,
    required this.startedAt,
    required this.store,
    required this.enabledFor,
    required this.minHoursBetween,
    required this.blocked,
    required this.show,
    required this.log,
    required this.onReport,
  });

  static const String storeName = 'error_prompt';
  static const Duration startDelay = Duration(seconds: 10);
  static const Duration merge = Duration(seconds: 1);
  static const Duration waitLimit = Duration(seconds: 30);
  static const Duration poll = Duration(milliseconds: 500);
  static const Duration muteAfterTwoCloses = Duration(days: 7);

  /// Milliseconds since the epoch.
  final int Function() now;
  final int startedAt;
  final FeedbackStore store;
  final bool Function(FeedbackErrorKind kind) enabledFor;
  final num Function() minHoursBetween;
  final bool Function() blocked;

  /// Shows the prompt and answers how it ended and when (the tap, for `openedAt`).
  final Future<(ErrorPromptOutcome, int)> Function() show;
  final void Function(String line) log;
  final void Function(int openedAt) onReport;

  bool _shownThisSession = false;
  bool _busy = false;
  bool _disposed = false;
  Timer? _timer;
  int? _waitingSince;

  bool get shownThisSession => _shownThisSession;

  void notice(FeedbackErrorKind kind) {
    if (_disposed || _shownThisSession || _busy || _timer != null || !enabledFor(kind)) return;
    final t = now();
    final at = math.max(t + merge.inMilliseconds, startedAt + startDelay.inMilliseconds);
    _waitingSince = null;
    _timer = Timer(Duration(milliseconds: at - t), _evaluate);
  }

  Future<void> _evaluate() async {
    _timer = null;
    if (_disposed || _shownThisSession) return;
    final t = now();
    if (blocked()) {
      _waitingSince ??= t;
      if (t - _waitingSince! >= waitLimit.inMilliseconds) {
        _waitingSince = null; // gave up; a later error may try again
        return;
      }
      _timer = Timer(poll, _evaluate);
      return;
    }
    _busy = true;
    try {
      Map<String, Object?> state;
      try {
        state = await store.readState(storeName) ?? {};
      } catch (_) {
        state = {};
      }
      final last = state['lastShownAt'];
      final muted = state['mutedUntil'];
      final gap = (minHoursBetween() * 3600000).round();
      if (last is int && t - last < gap) return;
      if (muted is int && t < muted) return;
      if (_disposed || blocked()) return;
      _shownThisSession = true;
      await _write({...state, 'lastShownAt': t});
      log('error prompt shown');
      final (outcome, at) = await show();
      final closes = state['closes'] is int ? state['closes']! as int : 0;
      switch (outcome) {
        case ErrorPromptOutcome.report:
          log('error prompt: reporting');
          await _write({...state, 'lastShownAt': t, 'closes': 0});
          onReport(at);
        case ErrorPromptOutcome.dismissed:
          log('error prompt dismissed');
          final next = closes + 1;
          await _write({
            ...state,
            'lastShownAt': t,
            'closes': next >= 2 ? 0 : next,
            if (next >= 2) 'mutedUntil': at + muteAfterTwoCloses.inMilliseconds,
          });
        case ErrorPromptOutcome.timedOut:
          log('error prompt went by itself');
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _write(Map<String, Object?> state) async {
    try {
      await store.writeState(storeName, state);
    } catch (_) {
      // Unrecorded, it may show again sooner; never more than once a session.
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

/// The prompt itself: a pill above the bottom safe area (bottom right on a wide screen), above the
/// keyboard when it is up, in the sheet's theme. It fades in unless animations are off, is announced
/// politely, and goes by itself after [duration], or later while the pointer is over it.
class FeedbackErrorPrompt extends StatefulWidget {
  const FeedbackErrorPrompt({
    super.key,
    required this.theme,
    required this.onReport,
    required this.onClose,
    required this.onTimeout,
    this.duration = const Duration(seconds: 8),
  });

  static const String text = 'Something may have gone wrong. Tell us?';

  final ThemeData? theme;
  final VoidCallback onReport;
  final VoidCallback onClose;
  final VoidCallback onTimeout;
  final Duration duration;

  @override
  State<FeedbackErrorPrompt> createState() => _FeedbackErrorPromptState();
}

class _FeedbackErrorPromptState extends State<FeedbackErrorPrompt> {
  Timer? _timer;
  bool _visible = false;
  bool _announced = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, widget.onTimeout);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_announced) {
      _announced = true;
      final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
      // Polite is the default. `announce` rather than `sendAnnouncement`, which the package's oldest
      // supported Flutter does not have.
      // ignore: deprecated_member_use
      unawaited(SemanticsService.announce(FeedbackErrorPrompt.text, direction));
    }
  }

  void _hold() => _timer?.cancel();

  void _release() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 3), widget.onTimeout);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return wrapAmbient(
      context,
      Builder(
        builder: (context) {
          final media = MediaQuery.of(context);
          final data = feedbackTheme(context, widget.theme);
          final bottom = math.max(media.viewPadding.bottom, media.viewInsets.bottom) + 12;
          final wide = media.size.width >= 600;
          return Theme(
            data: data,
            child: Align(
              alignment: wide ? Alignment.bottomRight : Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(left: 12, right: 12 + media.viewPadding.right, bottom: bottom),
                child: AnimatedOpacity(
                  opacity: _visible ? 1 : 0,
                  duration: media.disableAnimations ? Duration.zero : const Duration(milliseconds: 220),
                  child: MouseRegion(
                    onEnter: (_) => _hold(),
                    onExit: (_) => _release(),
                    child: Material(
                      key: const ValueKey('overblast_feedback.error_prompt'),
                      elevation: 4,
                      shape: const StadiumBorder(),
                      color: data.colorScheme.surfaceContainerHigh,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 18, right: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(child: Text(FeedbackErrorPrompt.text, style: data.textTheme.bodyMedium)),
                            const SizedBox(width: 4),
                            TextButton(
                              key: const ValueKey('overblast_feedback.error_prompt.report'),
                              onPressed: widget.onReport,
                              child: const Text('Report'),
                            ),
                            IconButton(
                              key: const ValueKey('overblast_feedback.error_prompt.close'),
                              // No tooltip: above MaterialApp there is no overlay for one.
                              onPressed: widget.onClose,
                              icon: const Icon(Icons.close, semanticLabel: 'Close'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
