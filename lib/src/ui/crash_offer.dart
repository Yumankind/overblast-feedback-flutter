import 'package:flutter/material.dart';

import 'layer.dart';
import 'theme.dart';

/// The one-time prompt after an unexpected end (docs/feedback-reports.md §3.4): a small card at the
/// bottom of the screen, over the app but outside its captured surface, that leaves the app usable
/// around it.
class FeedbackCrashOffer extends StatelessWidget {
  const FeedbackCrashOffer({super.key, required this.theme, required this.onSend, required this.onDismiss});

  final ThemeData? theme;
  final VoidCallback onSend;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final content = Builder(
      builder: (context) {
        final data = feedbackTheme(context, theme);
        return Theme(
          data: data,
          child: SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Material(
                    key: const ValueKey('overblast_feedback.crash_offer'),
                    elevation: 6,
                    borderRadius: BorderRadius.circular(FeedbackStyle.radiusOf(context) * 0.7),
                    color: data.colorScheme.surfaceContainerHigh,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              'The app closed unexpectedly. Send a report?',
                              style: data.textTheme.bodyLarge,
                            ),
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              TextButton(
                                key: const ValueKey('overblast_feedback.crash_offer.dismiss'),
                                onPressed: onDismiss,
                                child: const Text('Not now'),
                              ),
                              TextButton(
                                key: const ValueKey('overblast_feedback.crash_offer.send'),
                                onPressed: onSend,
                                child: const Text('Send a report'),
                              ),
                            ],
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
    );
    return wrapAmbient(context, content);
  }
}
