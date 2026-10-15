import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:overblast_feedback/overblast_feedback.dart';

import 'helpers.dart';

// What a library reads at start (docs/feedback-reports.md §2.1).

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemoryFeedbackStore store;
  late DateTime now;
  late List<http.Request> requests;
  late List<http.Response Function(http.Request)> answers;

  Map<String, Object?> config({String verification = 'flag', bool prompt = true, bool screenshots = true}) => {
    'verification': verification,
    'errorPrompt': {
      'enabled': prompt,
      'on': ['exception', 'server_error'],
      'minHoursBetween': 12,
    },
    'screenshots': screenshots,
  };

  http.Response ok(Map<String, Object?> body, {String etag = '"v1"'}) =>
      http.Response(jsonEncode(body), 200, headers: {'etag': etag, 'content-type': 'application/json'});

  setUp(() {
    store = MemoryFeedbackStore();
    now = DateTime.utc(2026, 10, 15, 9);
    requests = [];
    answers = [];
  });

  OverblastFeedbackController make({String key = testKey, bool errorPrompt = true, bool screenshots = true}) =>
      OverblastFeedbackController(
        feedbackKey: key,
        store: store,
        deviceFacts: fakeFacts,
        clock: () => now,
        deviceVerification: false,
        trackCrashes: false,
        errorPrompt: errorPrompt,
        screenshots: screenshots,
        httpClient: MockClient((req) async {
          requests.add(req);
          if (req.url.path.endsWith('/config')) {
            return answers.isEmpty ? http.Response('', 503) : answers.removeAt(0)(req);
          }
          return http.Response(jsonEncode({'id': 'fbr_1', 'taskId': 't'}), 201);
        }),
      );

  test('before any answer: the defaults, which register nothing and prompt nothing', () {
    final c = make();
    expect(c.config.verification, FeedbackVerification.off);
    expect(c.config.errorPrompt.enabled, isFalse);
    expect(c.config.errorPrompt.on, {FeedbackErrorKind.exception});
    expect(c.config.errorPrompt.minHoursBetween, 24);
    expect(c.config.screenshots, isTrue);
    expect(c.errorPromptAllowed, isFalse);
    c.dispose();
  });

  test('GET <endpoint>/config with the key; the answer is kept with its ETag', () async {
    answers.add((_) => ok(config()));
    final c = make();
    final got = await c.refreshConfig();
    final req = requests.single;
    expect(req.method, 'GET');
    expect(req.url.toString(), 'https://brain.deployd.network/v1/feedback/config');
    expect(req.headers['X-Overblast-Feedback-Key'], testKey);
    expect(req.headers.containsKey('If-None-Match'), isFalse);
    expect(got.verification, FeedbackVerification.flag);
    expect(got.errorPrompt.on, {FeedbackErrorKind.exception, FeedbackErrorKind.serverError});
    expect(got.errorPrompt.minHoursBetween, 12);
    final kept = await store.readState('config');
    expect(kept!['etag'], '"v1"');
    expect(kept['key'], testKey);
    c.dispose();
  });

  test('at most every five minutes, then with If-None-Match; a 304 keeps the answer', () async {
    answers.add((_) => ok(config()));
    final c = make();
    await c.refreshConfig();
    now = now.add(const Duration(minutes: 4));
    await c.refreshConfig();
    expect(requests.length, 1);
    now = now.add(const Duration(minutes: 2));
    answers.add((_) => http.Response('', 304));
    final got = await c.refreshConfig();
    expect(requests.length, 2);
    expect(requests.last.headers['If-None-Match'], '"v1"');
    expect(got.verification, FeedbackVerification.flag);
    c.dispose();
  });

  test('offline at the next start: the kept answer stands', () async {
    answers.add((_) => ok(config(verification: 'require')));
    final first = make();
    await first.refreshConfig();
    first.dispose();

    final second = make(); // the door answers 503 from here on
    final got = await second.refreshConfig();
    expect(got.verification, FeedbackVerification.require);
    expect(requests.last.headers['If-None-Match'], '"v1"');
    second.dispose();
  });

  test('an answer kept for another key is not this key\'s', () async {
    answers.add((_) => ok(config(verification: 'require')));
    final first = make();
    await first.refreshConfig();
    first.dispose();
    final other = make(key: 'obfk_ZYXWVUTSRQPONMLKJIHGFEDCBA');
    expect((await other.refreshConfig()).verification, FeedbackVerification.off);
    other.dispose();
  });

  test('a local option only turns things off', () async {
    answers.add((_) => ok(config(prompt: true, screenshots: true)));
    final local = make(errorPrompt: false, screenshots: false);
    await local.refreshConfig();
    expect(local.errorPromptAllowed, isFalse);
    expect(local.screenshotsAllowed, isFalse);
    local.dispose();

    answers.add((_) => ok(config(prompt: false, screenshots: false), etag: '"v2"'));
    final keyOff = make();
    await keyOff.refreshConfig();
    expect(keyOff.errorPromptAllowed, isFalse);
    expect(keyOff.screenshotsAllowed, isFalse);
    keyOff.dispose();
  });

  group('categories (§2)', () {
    test('default all four; the order kept; unknown and repeated left out; empty means all', () {
      expect(FeedbackRemoteConfig.defaults.categories, FeedbackCategory.values);
      expect(
        FeedbackRemoteConfig.fromJson({
          'categories': ['idea', 'bug', 'nonsense', 'idea'],
        }).categories,
        [FeedbackCategory.idea, FeedbackCategory.bug],
      );
      expect(FeedbackRemoteConfig.fromJson({'categories': []}).categories, FeedbackCategory.values);
      expect(FeedbackRemoteConfig.fromJson({}).categories, FeedbackCategory.values);
    });

    test('report() with a category the key does not take is not sent: category_not_accepted', () async {
      answers.add((_) => ok({...config(), 'categories': ['bug']}));
      final c = make();
      await c.refreshConfig();
      final before = requests.length;
      await expectLater(
        c.report(message: 'An idea', category: FeedbackCategory.idea),
        throwsA(
          isA<OverblastFeedbackException>()
              .having((e) => e.status, 'status', 403)
              .having((e) => e.code, 'code', 'category_not_accepted')
              .having((e) => e.message, 'message', 'This app only takes problem reports.')
              .having((e) => e.savedForLater, 'saved', isFalse),
        ),
      );
      expect(requests.length, before);
      expect(await c.pending(), isEmpty);
      await c.report(message: 'A bug');
      expect(requests.length, before + 1);
      c.dispose();
    });

    Future<OverblastFeedbackController> sheetWith(WidgetTester tester, List<String> categories) async {
      answers.add((_) => ok({...config(), 'categories': categories}));
      final c = make();
      await tester.pumpWidget(
        OverblastFeedback(
          controller: c,
          enableShake: false,
          captureDebugPrint: false,
          captureErrors: false,
          retryPendingOnStart: false,
          child: const MaterialApp(home: Scaffold(body: Text('App'))),
        ),
      );
      await tester.pump();
      unawaited(c.show(category: FeedbackCategory.question));
      await tester.pump();
      return c;
    }

    testWidgets('one category: no choice, "Report a problem", and that category is sent', (tester) async {
      final c = await sheetWith(tester, ['bug']);
      expect(find.text('Report a problem'), findsOneWidget);
      expect(find.byKey(const ValueKey('overblast_feedback.categories')), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
      await tester.enterText(find.byKey(const ValueKey('overblast_feedback.message')), 'Broken');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('overblast_feedback.send')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final report = requests.lastWhere((r) => r.url.path == '/v1/feedback');
      expect((jsonDecode(report.body) as Map)['category'], 'bug');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('several: only those, the first the default', (tester) async {
      final c = await sheetWith(tester, ['idea', 'bug']);
      final chips = tester.widgetList<ChoiceChip>(find.byType(ChoiceChip)).toList();
      expect(chips.map((chip) => (chip.label as Text).data), ['Idea', 'Bug']);
      expect(chips.first.selected, isTrue, reason: 'question is not taken, so the default');
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  testWidgets('screenshots off for the key: the sheet offers none', (tester) async {
    answers.add((_) => ok(config(screenshots: false)));
    final c = make();
    await tester.pumpWidget(
      OverblastFeedback(
        controller: c,
        enableShake: false,
        captureDebugPrint: false,
        captureErrors: false,
        retryPendingOnStart: false,
        child: const MaterialApp(home: Scaffold(body: Text('App'))),
      ),
    );
    await tester.pump();
    expect(c.screenshotsAllowed, isFalse);
    unawaited(c.show());
    await tester.pump();
    expect(find.text('Report a problem'), findsOneWidget);
    expect(find.byKey(const ValueKey('overblast_feedback.screenshot')), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}

