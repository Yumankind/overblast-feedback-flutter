import 'package:overblast_feedback/overblast_feedback.dart';

const String testKey = 'obfk_ABCDEFGHIJKLMNOPQRSTUVWX';

Future<FeedbackDeviceFacts> fakeFacts() async =>
    const FeedbackDeviceFacts(os: 'iOS', osVersion: '18.2', device: 'iPhone15,3', appVersion: '2.4.1', build: '412');

// The contract's keys (docs/feedback-reports.md §3.1, §3.2), written out by hand on purpose: a test
// that derived them from the library would agree with any drift.
const Set<String> topKeys = {
  'v',
  'message',
  'category',
  'reporter',
  'context',
  'element',
  'screenshot',
  'logs',
  'network',
};
const Set<String> reporterKeys = {'email', 'name', 'accountRef'};
const Set<String> contextKeys = {
  'platform',
  'url',
  'screen',
  'title',
  'appVersion',
  'build',
  'os',
  'osVersion',
  'device',
  'locale',
  'timeZone',
  'viewport',
  'userAgent',
  'sdk',
  'deviceId',
  'extra',
};
const Set<String> viewportKeys = {'w', 'h', 'dpr'};
const Set<String> sdkKeys = {'name', 'version'};
const Set<String> nativeElementKeys = {'kind', 'path', 'type', 'id', 'label', 'rect', 'viewport'};
const Set<String> rectKeys = {'x', 'y', 'w', 'h'};
const Set<String> screenshotKeys = {'contentType', 'base64', 'highlighted'};
const Set<String> logKeys = {'t', 'level', 'msg', 'src'};
const Set<String> networkKeys = {'t', 'method', 'url', 'status', 'ms'};
