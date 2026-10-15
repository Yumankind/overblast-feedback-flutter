/// Shake-to-report for Flutter apps built on Overblast. See the README, and the contract this
/// library implements: the payload of `POST /v1/feedback` (docs/feedback-reports.md in the
/// Overblast repository).
library;

export 'src/anchor.dart' show anchorAt, isFrameworkNoise;
export 'src/capture.dart' show FeedbackCapture;
export 'src/config.dart' show FeedbackErrorKind, FeedbackErrorPromptConfig, FeedbackRemoteConfig, FeedbackVerification;
export 'src/controller.dart' show OverblastFeedbackController, FeedbackPresenter, FeedbackPreviousSession;
export 'src/crash.dart' show FeedbackCrash, FeedbackCrashKind, FeedbackCrashSource, FeedbackTrigger;
export 'src/device.dart' show FeedbackDeviceFacts, readDeviceFacts;
export 'src/http_client.dart' show OverblastHttpClient;
export 'src/log_buffer.dart' show FeedbackLogLevel, FeedbackLogEntry, FeedbackNetworkEntry, stripUrl;
export 'src/payload.dart'
    show
        FeedbackCategory,
        FeedbackContext,
        FeedbackLimits,
        FeedbackPayload,
        FeedbackRect,
        FeedbackReporter,
        FeedbackScreenshot,
        FeedbackViewport,
        NativeAnchor;
export 'src/private.dart' show OverblastPrivate;
export 'src/redact.dart' show redact;
export 'src/route_observer.dart' show OverblastNavigatorObserver;
export 'src/shake.dart' show ShakeOptions, ShakeDetector;
export 'src/store/store.dart' show FeedbackStore, MemoryFeedbackStore, PendingReport;
export 'src/transport.dart' show FeedbackResult, OverblastFeedbackException, defaultFeedbackEndpoint;
export 'src/verification/pow.dart' show PowSolver;
export 'src/verification/registration.dart'
    show FeedbackDeviceLevel, FeedbackDeviceMethod, FeedbackDeviceRegistration;
export 'src/version.dart' show sdkName, sdkVersion;
export 'src/ui/theme.dart' show FeedbackTheme;
export 'src/widget.dart' show OverblastFeedback;
