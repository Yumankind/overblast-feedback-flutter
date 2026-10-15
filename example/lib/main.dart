import 'package:flutter/material.dart';
import 'package:overblast_feedback/overblast_feedback.dart';

/// Pass a real key with `--dart-define=OVERBLAST_FEEDBACK_KEY=obfk_...`. The placeholder is shaped
/// like a key so the app starts, and every report with it is refused as `unknown_key`.
const String feedbackKey = String.fromEnvironment(
  'OVERBLAST_FEEDBACK_KEY',
  defaultValue: 'obfk_EXAMPLEEXAMPLEEXAMPLEEXAM',
);

final OverblastFeedbackController feedback = OverblastFeedbackController(feedbackKey: feedbackKey);

void main() {
  feedback.info('example starting');
  runApp(OverblastFeedback(controller: feedback, child: const ExampleApp()));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'overblast_feedback',
      navigatorObservers: [OverblastFeedback.navigatorObserver],
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = OverblastFeedback.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('overblast_feedback')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The level the worker gave this install, once the sheet has opened (or after
            // prepareDevice below).
            ListenableBuilder(
              listenable: controller,
              builder: (context, _) => Text('Device: ${controller.deviceLevel.name}'),
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('example.report'),
              onPressed: () => controller.show(),
              child: const Text('Report a problem'),
            ),
            TextButton(onPressed: () => controller.prepareDevice(), child: const Text('Register this device now')),
          ],
        ),
      ),
    );
  }
}
