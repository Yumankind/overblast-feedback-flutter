import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

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
