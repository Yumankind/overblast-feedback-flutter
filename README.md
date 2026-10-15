# overblast_feedback

Shake-to-report for Flutter apps built on [Overblast](https://overblast.app). A person using the app
shakes the phone (or taps your own "Report a problem" button), says what is wrong, optionally points
at the part of the screen that is wrong, chooses whether to attach a screenshot, and sends it. The
report lands in your Overblast workspace as a **task**, with the selected widget, the recent logs and
network calls, the device, the person's account reference in your product, and the screenshot when
they chose to attach one.

iOS and Android. Desktop works without the shake (call `show()` from a button) and without device
verification; the web has its own library, `@overblast/feedback`.

## Install

Until the package is on pub.dev, depend on it by git URL and tag:

```yaml
dependencies:
  overblast_feedback:
    git:
      url: https://github.com/Yumankind/overblast-feedback-flutter
      ref: 0.2.0
```

It brings `http`, `crypto` (SHA-256 for device verification), `sensors_plus` (the shake),
`path_provider` (where unsent reports wait), `package_info_plus` (app version and build) and
`device_info_plus` (model and OS version). Since 0.2.0 it is a plugin with a small native half of its
own (Swift and Kotlin, no third-party code) for device verification; after adding it, run
`pod install` in `ios/` as for any plugin. It works with CocoaPods and with Swift Package Manager.

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
| `deviceVerification` | `true` | Register the device and sign reports when the key asks for it; `false` never does |
| `screenshots` | `true` | Offer a screenshot; `false` never does (the key can also switch them off) |
| `errorPrompt` | `true` | Allow the error prompt when the key enables it; `false` never shows it |
| `appHosts` | none | Your own API hosts, whose 5xx and failed requests count towards the error prompt |
| `trackCrashes` | `true` | Keep the log on disk and a session marker, for the report after a crash |
| `offerReportAfterCrash` | `true` | After an unexpected end, offer a report once at the next launch |
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
- **Logs** are bounded as described under "Logs and network", and each kept line is redacted as it
  is recorded: bearer and basic credentials,
  `sk-`/`sk_live_`/`ob_live_`/`obfk_` keys, JWTs, card numbers (13 to 19 digits passing the Luhn
  check) and `password=`/`token=`/`secret=`/`api_key=` values (also in JSON) become `[redacted]`.
- **Network** entries are method, URL without query string or fragment (and without any
  `user:password@`), status and milliseconds. No bodies, no headers.
- Unsent reports are kept in the app's support directory (at most five), already redacted, and are
  deleted once sent or refused for good. So is the on-disk copy of the log (at most 4 MB, redacted),
  which a new session clears once it has read the last one's.

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

Logging is cheap to leave on, even for an app that prints hundreds of `debugPrint` lines a second:

- **Repeats collapse.** A line identical to the one before is stored once, with `repeat` (how many
  times it occurred) and `last` (when it last did).
- **Intake is capped**: 50 lines a second, warnings and errors up to 200. Past that, lines are counted
  and dropped without being redacted or copied, and one warning marks the gap: `1,950 lines dropped
  in 1 s (too fast)`.
- **The buffer** holds 20,000 lines or 2 MB, whichever comes first. When it is full, debug and info
  lines go before warnings and errors.
- **Nothing is collected while the sheet is open**, so the report is of what happened before it.
- **In the report**, `logs` is an excerpt (every warning and error in the two minutes before the
  report was opened, then the newest other lines, up to 500 lines and 256 KB) and, when that leaves
  lines out, `logFile` carries all of them as gzip NDJSON, at most 4 MB, the oldest cut first with a
  line saying so. The log file shrinks to keep the body within 8 MB beside a screenshot. On the web,
  which has no `dart:io`, the file is sent uncompressed.

`captureErrors` chains to the handlers that were installed before it (Crashlytics, say) and hands
every error on unchanged; it never swallows one. Install your own handlers first, in `main()`, and the
widget's `initState` runs after them.

## The error prompt

When the key turns it on, a small pill can appear after something goes wrong: "Something may have
gone wrong. Tell us?", with Report and a close button, above the bottom safe area (bottom right on a
wide screen) and above the keyboard. What counts, by the key's choice:

- `exception`: a Dart error that reached `FlutterError.onError` or `PlatformDispatcher.onError`
  (Flutter keeps running after one, so it counts), or one you log as unexpected:
  `feedback.error(e, unexpected: true)`. A plain `error()` is a handled error and does not count.
- `server_error` and `network`: a request to one of `appHosts` (a subdomain matches) answered 500 to
  599, or never answered, as recorded by `OverblastHttpClient` or `recordNetwork`. Other hosts, 4xx
  answers and the library's own door never count. With no `appHosts`, only exceptions count.

It never gets in the way: not in the first ten seconds, not while the keyboard is up or within five
seconds of a key pressed in a text field (it waits up to 30 seconds, then gives up), not while the
sheet or the crash offer is showing, only in the foreground. At most once per session, once per the
key's `minHoursBetween` on the device, and after two closes in a row, not for seven days; errors a
second apart are one prompt. It goes by itself after about eight seconds (longer while the pointer is
over it), is announced politely to screen readers, and does not fade when animations are off.
Report opens the sheet with `trigger: error_prompt`, category Bug, and the moment of the tap as
`openedAt`, so the error is among the lines just before. Each prompt leaves a log line ("error prompt
shown", "dismissed", "went by itself", "reporting").

## After a crash

The library marks the session open when the app starts, closed when it goes to the background or
exits cleanly, and keeps the log on disk as it goes (every five seconds, and at once on an error). If
the next launch finds the last session never closed, it offers once, in a small card at the bottom of
the screen: "The app closed unexpectedly. Send a report?". Sending opens the sheet for that session,
with its saved logs and what is known about how it ended:

- **Android 11 and later**: `ApplicationExitInfo` (a crash, an ANR as `killed`, low memory as `oom`).
- **iOS**: MetricKit's crash diagnostic (exception, signal, the crashed thread's frames).
  MetricKit delivers it at a later launch, sometimes after the offer has been made.
- **Dart**: the last error that reached `FlutterError.onError` or `PlatformDispatcher.onError`
  (Flutter does not end the process on one, so it is the account of the end only when the platform
  has none).
- Otherwise `unknown`: often the system ending the app for memory or a watchdog.

A session that ended in the background (the system reclaiming a suspended app) is not offered. With
`offerReportAfterCrash: false` the card is not shown; `controller.pendingCrash` holds the previous
session for the app's own prompt, and `controller.show(trigger: FeedbackTrigger.relaunch)` opens the
sheet for it. `trackCrashes: false` keeps nothing on disk at all.

Every report also says when it was opened (`openedAt`) and what opened it (`trigger`: `shake`,
`button` for `show()`, `api` for `report()`, `relaunch`).

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

## What the key decides

At start (and when the app comes back to the foreground, at most every five minutes) the library
reads `GET /v1/feedback/config` for its key, with the `ETag`, and keeps the answer on the device for
when the door cannot be reached. The key, set in the console, says whether devices register
(`verification`: `off`, the default, `flag` or `require`), whether the error prompt is on and for
what, whether screenshots are offered, and which categories it takes (with only Bug, the sheet
offers no choice; with several, only those, the first as the default; `report(category:)` with one
the key does not take is refused on the device with `category_not_accepted`, not sent). Until the library has had a first answer it behaves as
the defaults: no device registration, no error prompt. Your own options only ever turn things off.

A controller used without the widget reads it when you call `controller.refreshConfig()`.

## Device verification

A report from a device the worker knows is counted against that device, with more room than an
anonymous one (the limits are per IP and per device, by level). When the key's verification is
`flag` or `require`, the library registers the install once, the first time the sheet opens, and
signs every report afterwards:

| Platform | How it registers | Level |
|---|---|---|
| iOS, iPadOS (iOS 14 and later, real hardware) | **App Attest**: a Secure Enclave key Apple attests, naming `TEAMID.bundleId` | `attested` |
| Android (API 24 and later) | **Hardware key attestation**: an Android Keystore key (StrongBox first, then the TEE) whose certificate chain names the package and its signing certificate. Not Play Integrity: nothing talks to Google, and no Play services are needed | `attested` |
| The iOS simulator, an Android emulator, iOS without App Attest, a refused attestation | A **proof of work** with a plain key that never leaves the keychain or keystore | `registered` |
| macOS, Windows, Linux, the web | Nothing: there is no native key here, so reports go **unsigned** | `none` |

None of it asks you for a secret. What you do:

- **iOS**: in Xcode, Runner target > Signing & Capabilities > **+ Capability > App Attest**. That adds
  the `com.apple.developer.devicecheck.appattest-environment` entitlement to `Runner.entitlements`.
  Builds distributed through TestFlight and the App Store attest in production; a run from Xcode
  attests in development, which the worker counts as `registered`, not `attested`. Then, in the
  Overblast console, add `TEAMID.bundleId` (`ABCDE12345.com.example.app`) to the feedback key's Apple
  apps. Without the capability, App Attest fails and the library falls back to the proof of work.
  The package needs iOS 15.0 or later (Xcode 27 builds nothing older), which also covers App
  Attest's iOS 14.
- **Android**: in the console, add the package name and the SHA-256 of the app's signing certificate
  (Play Console > App signing; for a debug build, `./gradlew signingReport`) to the key's Android
  apps.

That is all. The registration runs while the reporter types (an attestation is a second or two; a
proof of work up to about twenty seconds, and it gives up after that); Send waits at most three
seconds more for it and otherwise sends unsigned, and the device is used from the next report on.
`controller.deviceLevel` says where it stands (`none`, `registered`, `attested`), and
`controller.prepareDevice()` registers ahead of the first report if you would rather not wait for the
sheet.

Signing covers the exact bytes sent, with the time. A device the worker no longer knows, or whose
signature it rejects, is dropped with its key, registered again, and the report resent once. A key
set to require verified devices refuses an unsigned report; the library then waits for the
registration if one has not been tried, and resends once. Unsent reports are signed again when they
are finally sent.

Pass `deviceVerification: false` to send every report unsigned.

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
payload version 1, and the device doors `POST /v1/feedback/devices/challenge` and
`POST /v1/feedback/devices`). The body carries exactly the contract's keys and nothing else, trimmed to its
limits before sending; the worker refuses an unknown field by name.

## Tests

```sh
flutter pub get && flutter analyze && flutter test
```

In your own widget tests, an `OverblastFeedback` in the tree is harmless with its defaults; pass
`enableShake: false`, `retryPendingOnStart: false`, `deviceVerification: false` and
`trackCrashes: false` to keep it quiet. (With device verification on, a platform channel nobody mocks
never answers inside a widget test's fake clock, so Send waits out its three seconds; with crash
tracking on, the log's five-second write is a pending timer at the end of the test.)

The `example/` app builds the native half:

```sh
cd example
flutter build ios --simulator --no-codesign
flutter build apk --debug
```

## Licence

MIT. See [LICENSE](LICENSE).
