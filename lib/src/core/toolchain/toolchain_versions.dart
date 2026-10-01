import 'dart:convert';

import '../io/process_runner.dart';
import '../managed/lock_file.dart';

/// The Flutter and Xcode versions on this machine, as plain strings.
///
/// Strings rather than parsed versions because they are compared for equality
/// and written into a committed file: `3.47.2` and `26.6` should read in
/// `.shipway/lock.json` exactly as the tools print them.
abstract final class ToolchainVersions {
  /// Flutter's own version, or null when it cannot be asked.
  ///
  /// `--machine` is asked first because its JSON has one unambiguous field.
  /// The banner is still understood, since a wrapper that ignores the flag
  /// prints that instead.
  static Future<String?> flutter(
    ProcessRunner runner, {
    String? workingDirectory,
  }) async {
    final result = await runner.run('flutter', const <String>[
      '--version',
      '--machine',
    ], workingDirectory: workingDirectory);
    if (result.notFound || !result.ok) return null;
    return parseFlutter(result.stdout);
  }

  /// Xcode's version, or null off macOS or when no Xcode is selected.
  static Future<String?> xcode(ProcessRunner runner) async {
    final result = await runner.run('xcodebuild', const <String>['-version']);
    if (result.notFound || !result.ok) return null;
    return parseXcode(result.output);
  }

  static String? parseFlutter(String output) {
    final start = output.indexOf('{');
    final end = output.lastIndexOf('}');
    if (start != -1 && end > start) {
      try {
        final decoded = jsonDecode(output.substring(start, end + 1));
        if (decoded is Map) {
          final version =
              decoded['frameworkVersion'] ?? decoded['flutterVersion'];
          if (version is String && version.isNotEmpty) return version;
        }
      } on FormatException {
        // Not JSON after all; the banner is tried next.
      }
    }
    return RegExp(
      r'^Flutter\s+(\d+\.\d+\.\d+[^\s•]*)',
      multiLine: true,
    ).firstMatch(output)?.group(1);
  }

  /// `Xcode 26.6` on the first line; the build number on the second is not
  /// something a workflow can ask for.
  static String? parseXcode(String output) => RegExp(
    r'^Xcode\s+(\d+(?:\.\d+){0,2})',
    multiLine: true,
  ).firstMatch(output)?.group(1);
}

/// Writes the toolchain a release was built with into `.shipway/lock.json`.
///
/// Two commits in a field report pinned Flutter and moved a runner to a newer
/// Xcode because CI and a laptop had drifted apart without anything saying
/// so. Recording what the last release used gives `doctor` something to
/// compare a machine against, and the workflow generator something to pin.
abstract final class ToolchainRecord {
  /// Probes this machine and records what it finds, saving only on a change.
  ///
  /// Xcode is recorded for an iOS release only: it took no part in an Android
  /// build, and recording it there would report drift in a tool the release
  /// never ran. Returns what is now on record when the file was rewritten, and
  /// null when it was left alone.
  ///
  /// Never throws. This runs after the upload has succeeded, and a lock file
  /// that cannot be read or written is not a reason to call that a failure.
  static Future<LockedToolchain?> afterRelease(
    ProcessRunner runner, {
    required String root,
    required bool ios,
  }) async {
    try {
      final flutter = await ToolchainVersions.flutter(
        runner,
        workingDirectory: root,
      );
      final xcode = ios ? await ToolchainVersions.xcode(runner) : null;
      if (flutter == null && xcode == null) return null;

      final lock = await LockFile.load(root);
      if (!lock.recordToolchain(flutter: flutter, xcode: xcode)) return null;
      await lock.save(root);
      return lock.toolchain;
    } on Exception {
      return null;
    }
  }
}
