# overblast_feedback example

A small app around `OverblastFeedback`, used to build and try the plugin's native half (App Attest on
iOS, key attestation on Android).

```sh
flutter run --dart-define=OVERBLAST_FEEDBACK_KEY=obfk_...
flutter build ios --simulator --no-codesign
flutter build apk --debug
```

On the iOS simulator App Attest is unsupported, so the device registers by proof of work and shows
`registered`. On a phone, the bundle id and team must be listed on the key (`TEAMID.bundleId`) for
`attested`, and a run from Xcode attests in the development environment, which the worker counts as
`registered`.
