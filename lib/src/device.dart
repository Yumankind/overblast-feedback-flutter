import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The facts about the device and the app that go into `context`, read once per session.
class FeedbackDeviceFacts {
  const FeedbackDeviceFacts({this.os, this.osVersion, this.device, this.appVersion, this.build});

  final String? os;
  final String? osVersion;

  /// The model: `iPhone15,3`, `Google Pixel 8`.
  final String? device;
  final String? appVersion;
  final String? build;
}

/// The operating system's name as people write it, from [defaultTargetPlatform] (which works on
/// the web too, unlike `dart:io`'s `Platform`).
String osName() {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.android => 'Android',
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.fuchsia => 'Fuchsia',
  };
}

/// Reads the model and OS version from `device_info_plus` and the version and build from
/// `package_info_plus`. Each read is allowed to fail on its own (a platform without the plugin, a
/// test without a channel), leaving that field out rather than failing the report.
Future<FeedbackDeviceFacts> readDeviceFacts() async {
  String? osVersion;
  String? device;
  try {
    final info = DeviceInfoPlugin();
    if (kIsWeb) {
      final web = await info.webBrowserInfo;
      device = web.browserName.name;
    } else {
      switch (defaultTargetPlatform) {
        case TargetPlatform.iOS:
          final ios = await info.iosInfo;
          osVersion = ios.systemVersion;
          device = ios.utsname.machine;
        case TargetPlatform.android:
          final android = await info.androidInfo;
          osVersion = '${android.version.release} (SDK ${android.version.sdkInt})';
          device = '${android.manufacturer} ${android.model}'.trim();
        case TargetPlatform.macOS:
          final mac = await info.macOsInfo;
          osVersion = mac.osRelease;
          device = mac.model;
        default:
          break;
      }
    }
  } catch (_) {
    // The fields stay empty; the report goes without them.
  }
  String? appVersion;
  String? build;
  try {
    final package = await PackageInfo.fromPlatform();
    appVersion = package.version.isEmpty ? null : package.version;
    build = package.buildNumber.isEmpty ? null : package.buildNumber;
  } catch (_) {
    // Same: the integrator can pass appVersion and build themselves.
  }
  return FeedbackDeviceFacts(os: osName(), osVersion: osVersion, device: device, appVersion: appVersion, build: build);
}
