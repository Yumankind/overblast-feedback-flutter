import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../payload.dart' show FeedbackLimits;
import '../verification/registration.dart';
import 'store.dart';

FeedbackStore createDefaultStore() => FileFeedbackStore(() async {
  final base = await getApplicationSupportDirectory();
  return Directory('${base.path}${Platform.pathSeparator}overblast_feedback');
});

/// One small file for the install id and one JSON file per unsent report, in a folder of the app's
/// own support directory (not backed up to iCloud by default on iOS, private to the app on Android).
///
/// Files rather than shared preferences because an unsent report can carry a screenshot of several
/// megabytes, which NSUserDefaults and Android's preferences XML are not meant to hold.
class FileFeedbackStore implements FeedbackStore {
  FileFeedbackStore(this._directory);

  final Future<Directory> Function() _directory;
  Directory? _dir;

  Future<Directory> _root() async {
    final dir = _dir ??= await _directory();
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _pendingDir() async {
    final root = await _root();
    final dir = Directory('${root.path}${Platform.pathSeparator}pending');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<String?> readDeviceId() async {
    final file = File('${(await _root()).path}${Platform.pathSeparator}device_id');
    if (!file.existsSync()) return null;
    final id = (await file.readAsString()).trim();
    return id.isEmpty ? null : id;
  }

  @override
  Future<void> writeDeviceId(String id) async {
    final file = File('${(await _root()).path}${Platform.pathSeparator}device_id');
    await file.writeAsString(id, flush: true);
  }

  /// The registered device, `device.json`. It names the native key (an alias or an App Attest key
  /// id), never holds it: the key stays in the keychain or the keystore, this device only, so a copy
  /// of this file restored elsewhere signs nothing and is registered afresh.
  @override
  Future<FeedbackDeviceRegistration?> readRegisteredDevice() async {
    final file = File('${(await _root()).path}${Platform.pathSeparator}device.json');
    if (!file.existsSync()) return null;
    try {
      return FeedbackDeviceRegistration.fromJson(jsonDecode(await file.readAsString()));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writeRegisteredDevice(FeedbackDeviceRegistration? device) async {
    final file = File('${(await _root()).path}${Platform.pathSeparator}device.json');
    if (device == null) {
      if (file.existsSync()) await file.delete();
      return;
    }
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(device.toJson()), flush: true);
    await tmp.rename(file.path);
  }

  // The on-disk log: logs.0.ndjson (older) and logs.1.ndjson (newer), each at most
  // FeedbackLimits.diskLogFileBytes. When the newer would overflow, the older is deleted and the newer
  // takes its name.

  Future<File> _logFile(int i) async => File('${(await _root()).path}${Platform.pathSeparator}logs.$i.ndjson');

  @override
  Future<void> appendLogLines(List<String> lines) async {
    if (lines.isEmpty) return;
    final older = await _logFile(0);
    var newer = await _logFile(1);
    var size = newer.existsSync() ? newer.lengthSync() : 0;
    final chunk = BytesBuilder(copy: false);
    Future<void> rotate() async {
      if (chunk.isNotEmpty) await newer.writeAsBytes(chunk.takeBytes(), mode: FileMode.append, flush: true);
      if (older.existsSync()) await older.delete();
      if (newer.existsSync()) await newer.rename(older.path);
      newer = await _logFile(1);
      size = 0;
    }

    for (final line in lines) {
      final bytes = utf8.encode('$line\n');
      if (size + bytes.length > FeedbackLimits.diskLogFileBytes && size + chunk.length > 0) await rotate();
      chunk.add(bytes);
      size += bytes.length;
    }
    if (chunk.isNotEmpty) await newer.writeAsBytes(chunk.takeBytes(), mode: FileMode.append, flush: true);
  }

  @override
  Future<List<String>> readLogLines() async {
    final out = <String>[];
    for (final i in [0, 1]) {
      final file = await _logFile(i);
      if (!file.existsSync()) continue;
      // A crash can leave half a line at the end; it is dropped when parsed.
      out.addAll(const LineSplitter().convert(utf8.decode(await file.readAsBytes(), allowMalformed: true)));
    }
    return out.where((l) => l.isNotEmpty).toList();
  }

  @override
  Future<void> clearLogLines() async {
    for (final i in [0, 1]) {
      final file = await _logFile(i);
      if (file.existsSync()) await file.delete();
    }
  }

  @override
  Future<Map<String, Object?>?> readSession() async {
    final file = File('${(await _root()).path}${Platform.pathSeparator}session.json');
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      return json is Map ? json.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writeSession(Map<String, Object?>? session) async {
    final file = File('${(await _root()).path}${Platform.pathSeparator}session.json');
    if (session == null) {
      if (file.existsSync()) await file.delete();
      return;
    }
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(session), flush: true);
    await tmp.rename(file.path);
  }

  Future<File> _stateFile(String name) async =>
      File('${(await _root()).path}${Platform.pathSeparator}state_${_safe(name)}.json');

  @override
  Future<Map<String, Object?>?> readState(String name) async {
    final file = await _stateFile(name);
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(await file.readAsString());
      return json is Map ? json.cast<String, Object?>() : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> writeState(String name, Map<String, Object?>? value) async {
    final file = await _stateFile(name);
    if (value == null) {
      if (file.existsSync()) await file.delete();
      return;
    }
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<List<PendingReport>> loadPending() async {
    final dir = await _pendingDir();
    final out = <PendingReport>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final report = PendingReport.fromJson(jsonDecode(await entity.readAsString()));
        if (report != null) {
          out.add(report);
        } else {
          await entity.delete();
        }
      } on FormatException {
        await entity.delete(); // a half-written file from a crash; it can never be sent
      }
    }
    out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  @override
  Future<void> savePending(PendingReport report) async {
    final dir = await _pendingDir();
    final file = File('${dir.path}${Platform.pathSeparator}${_safe(report.id)}.json');
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(report.toJson()), flush: true);
    await tmp.rename(file.path);
    final all = await loadPending();
    for (var i = 0; i < all.length - FeedbackStore.maxPending; i++) {
      await deletePending(all[i].id);
    }
  }

  @override
  Future<void> deletePending(String id) async {
    final dir = await _pendingDir();
    final file = File('${dir.path}${Platform.pathSeparator}${_safe(id)}.json');
    if (file.existsSync()) await file.delete();
  }

  static String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
}
