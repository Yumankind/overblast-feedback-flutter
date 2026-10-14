# overblast_feedback

Shake-to-report for Flutter apps built on [Overblast](https://overblast.app). A person using the app
shakes the phone (or taps your own "Report a problem" button), says what is wrong, optionally points
at the part of the screen that is wrong, chooses whether to attach a screenshot, and sends it. The
report lands in your Overblast workspace as a **task**, with the selected widget, the recent logs and
network calls, the device, the person's account reference in your product, and the screenshot when
they chose to attach one.

iOS and Android. Desktop works without the shake (call `show()` from a button); the web has its own
library, `@overblast/feedback`.

## Install

Until the package is on pub.dev, depend on it by git URL and tag:

```yaml
dependencies:
  overblast_feedback:
    git:
      url: https://github.com/Yumankind/overblast-feedback-flutter
      ref: 0.1.0
```

It brings `http`, `sensors_plus` (the shake), `path_provider` (where unsent reports wait),
`package_info_plus` (app version and build) and `device_info_plus` (model and OS version). After
adding it, run `pod install` in `ios/` as for any plugin.

## Quick start

Create a feedback key in the Overblast console (Feedback keys). It is public, like a Sentry DSN: it
ships inside the app and grants nothing but "file a report into this workspace". Then wrap the app:

```dart
import 'package:overblast_feedback/overblast_feedback.dart';

void main() {
  runApp(
    OverblastFeedback(
      feedbackKey: 'obfk_...',
      child: MaterialApp(
        navigatorObservers: [OverblastFeedback.navigatorObserver],
        home: const HomeScreen(),
      ),
    ),
  );
}
```

That is the whole integration: shaking opens the sheet. From anywhere below it:

```dart
OverblastFeedback.of(context).show();                       // the sheet, as a shake opens it
OverblastFeedback.of(context).setReporter(                  // on sign-in; nulls on sign-out
  email: user.email, name: user.name, accountRef: user.id);
OverblastFeedback.of(context).log(FeedbackLogLevel.warn, 'Cart total mismatch');
await OverblastFeedback.of(context).report(message: '...'); // file one without the sheet
```

Code without a `BuildContext` (a service, an HTTP layer) reaches the same controller through
`OverblastFeedback.current`.

### Where to put it

Around `MaterialApp`, as above, is preferred: it then sees the whole app, dialogs included, and is
first to hear the Android back button, which closes the sheet. Inside `MaterialApp.builder` also
works:

```dart
MaterialApp(
  builder: (context, child) => OverblastFeedback(controller: feedback, child: child!),
)
```

Either way it owns a `RepaintBoundary` around its child, which is what the screenshot captures, and
draws the sheet beside that boundary rather than inside it, so the sheet is never in the image. It
brings its own overlay, theme and localizations where there are none, which is what lets it sit
above `MaterialApp`.

### Logging from the first line

To log before the first frame, make the controller in `main()` and hand it to the widget:

```dart
final feedback = OverblastFeedbackController(feedbackKey: 'obfk_...');

void main() {
  feedback.info('starting');
  runApp(OverblastFeedback(controller: feedback, child: const MyApp()));
}
```

A key that is not `obfk_...` throws at construction, by name, rather than failing on the first
report.

## Options

| Parameter | Default | What it does |
|---|---|---|
| `feedbackKey` | (required unless `controller`) | The workspace's public key |
| `controller` | made by the widget | A controller made earlier, to log from `main()` |
| `endpoint` | `https://brain.deployd.network/v1/feedback` | The door |
| `reporter` | none | `FeedbackReporter(email:, name:, accountRef:)`; or `setReporter` later |
| `appVersion`, `buildNumber` | from `package_info_plus` | Override the app's version and build |
| `enableShake` | `true` | Shake opens the sheet (iOS and Android only) |
| `shakeOptions` | 2.5 g, 3 peaks in 1.2 s, 2 s cooldown | How hard and how often |
| `captureDebugPrint` | `true` | Copy `debugPrint` lines into the logs |
| `captureErrors` | `true` | Log `FlutterError.onError` and `PlatformDispatcher.onError` |
| `retryPendingOnStart` | `true` | Try reports kept after a `429` once, five seconds after start |
| `theme` | Material 3, light or dark with the system | The sheet's theme |
| `httpClient`, `store` | real ones | For tests and custom storage |

The controller also takes `timeZone` (pass an IANA name such as `Europe/Lisbon` if the app knows it;
Dart alone only knows the abbreviation, `WEST`) and `extra` (up to 20 strings sent with every report,
also settable with `setExtra(key, value)`).

## The sheet

- **Message** (required) and **category**: Bug (the default), Idea, Question, Other.
- **Email**, only when the app has not supplied one through the reporter: optional, "only if you
  would like a reply".
- **Point at the problem**: the screen as it was when the sheet opened, full size; a tap selects
  the widget there, and its box is drawn on the screenshot.
- **Attach a screenshot**: **off by default**. Turned on, the image is shown as a thumbnail with
  Remove, exactly as it will be sent.
- A line saying what will be sent: the message, the selected element, the screenshot, device and
  app details, and this session's logs and network calls.
- **Send**. A refusal shows the worker's own sentence. A `429` (too many reports from this device),
  or no connection at all, keeps the report on the device and says so; it is tried again once at the
  next start (or when you call `retryPending()`), never in a loop.

Dark mode follows the system; the sheet is a labelled route for screen readers, and errors are live
regions.

## Privacy

- **The screenshot is opt-in per report**, shown before sending, and removable.
- **`OverblastPrivate`** marks a part of the screen that is never in a screenshot:

  ```dart
  OverblastPrivate(child: Text(account.iban))
  ```

  It is painted over with a flat box before the reporter even sees the image. Password fields
  (`obscureText: true`) and fields with a password, one-time-code or card autofill hint are blanked
  without it. Only what is actually painted is blanked: a private widget on a route under the
  current page, or in an `IndexedStack`'s hidden child, is not on the screen and needs no box.
- **The element picker never reads a text field's content**, nor any text inside `OverblastPrivate`
  or a password field: for those it sends the widget type and the box only.
- **Logs** are the last 500 lines, each redacted as it is recorded: bearer and basic credentials,
  `sk-`/`sk_live_`/`ob_live_`/`obfk_` keys, JWTs, card numbers (13 to 19 digits passing the Luhn
  check) and `password=`/`token=`/`secret=`/`api_key=` values (also in JSON) become `[redacted]`.
- **Network** entries are method, URL without query string or fragment (and without any
  `user:password@`), status and milliseconds. No bodies, no headers.
- Unsent reports are kept in the app's support directory (at most five), already redacted, and are
  deleted once sent or refused for good.

If your app keeps its own logs out of release builds because they may carry what a request held,
keep them out of reports too: pass `captureDebugPrint: !kReleaseMode` and log what you want reported
with `log()`.

## Logs and network

```dart
final feedback = OverblastFeedback.of(context);
feedback.info('Opened cart 8812');
feedback.error(e, src: 'checkout');
feedback.recordNetwork('POST', uri, response.statusCode, stopwatch.elapsedMilliseconds);
```

Or wrap the `http.Client` the app uses, and every call is recorded:

```dart
final client = OverblastHttpClient(http.Client());   // records into OverblastFeedback.current
```

`captureErrors` chains to the handlers that were installed before it (Crashlytics, say) and hands
every error on unchanged; it never swallows one. Install your own handlers first, in `main()`, and the
widget's `initState` runs after them.

## How the element is selected, and its limits

The tap is hit tested against the **live render tree**, exactly as a real tap would be, so what is
on top, what is offstage and what ignores pointers are all already decided by Flutter. The deepest
render object hit is mapped back to its widget through one walk of the element tree (no
`debugCreator`, so it works in release builds), and the library climbs from there to the widget a
person would name:

- the nearest **interactive** widget (buttons, text fields, list tiles, switches, chips, tabs,
  `InkWell`, `GestureDetector`, ...), climbing to the outermost of a cluster of the same size, so a
  tap on a button's label gives `ElevatedButton`, not the `InkWell` inside it;
- any widget with a **`ValueKey`** the app chose, which also becomes the element's `id` (a
  `Semantics(identifier:)` is used when there is no key);
- otherwise the nearest widget that is not framework plumbing (`Text`, your own `CartRow`).

The `path` is the chain of widget types from the outside in, with layout and framework plumbing
left out, the last 12 kept: `["MaterialApp", "CartScreen", "Scaffold", "ElevatedButton"]`. The
`label` is the semantics label, the tooltip, or the visible text inside. The `rect` is the part of
the widget's box on screen, as fractions of the app's surface.

Limits:

- Your own **private widgets** (`_CartRow`) look like framework internals and are left out of the
  path (in a debug session where Flutter's widget inspector knows your project's root, the ones
  created in your code are kept). A `ValueKey` always makes a widget the chosen one, whatever its
  name.
- In a build compiled with **`--obfuscate`**, type names are minified; keys and labels still read.
- Widgets inside an `IgnorePointer` cannot be hit, as they cannot be tapped.
- The frozen screenshot is what the reporter taps on, but the selection is made against the screen
  as it is at the moment of the tap. Something that moved in between (an animation, a timer) is
  selected where it is now.
- Platform views (maps, web views) are one widget to Flutter; their insides cannot be selected.

## How reports appear in Overblast

Each report becomes a **task** in the workspace, titled `Bug: <first line of the message>` (`Idea:`,
`Question:`, `Feedback:` by category), tagged `feedback`, the category and `flutter`, and assigned to
the key's group when it names one. The task's files hold `screenshot.png` when one was attached and
`feedback-report.json` with the element, logs, network and device. The webhook `feedback.created`
fires.

When the reporter gave an **email address** (yours through `setReporter`, or theirs in the sheet),
the task also carries an email conversation with them, which the team answers from the task. No
mail is sent when the report arrives; the thread opens when someone on the team replies. Without an
email there is nobody to answer and no conversation.

## The contract

This library implements the `flutter` half of the feedback-reports contract (`POST /v1/feedback`,
payload version 1). The body carries exactly the contract's keys and nothing else, trimmed to its
limits before sending; the worker refuses an unknown field by name.

## Tests

```sh
flutter pub get && flutter analyze && flutter test
```

In your own widget tests, an `OverblastFeedback` in the tree is harmless with its defaults; pass
`enableShake: false` and `retryPendingOnStart: false` to keep it quiet.

## Licence

MIT. See [LICENSE](LICENSE).
