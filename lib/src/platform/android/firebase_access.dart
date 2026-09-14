import 'dart:convert';

import '../../core/io/process_runner.dart';
import '../../core/toolchain/bundled_script.dart';

/// What App Distribution said about a service account and an app.
enum FirebaseAccessOutcome {
  ok,

  /// 401 or 403: the account exists and may not act on this app.
  denied,

  /// 404: App Distribution has no such app, or was never set up for it.
  appNotFound,

  /// The key itself was refused before the API was reached.
  badCredentials,

  /// No readable answer. Not a failure: a check that cannot run must not
  /// block a release that would have worked.
  unknown,
}

class FirebaseAccess {
  const FirebaseAccess(this.outcome, {this.status, this.message});

  final FirebaseAccessOutcome outcome;
  final int? status;
  final String? message;
}

/// Whether a service account can upload to a Firebase app, asked before the
/// build.
///
/// A field report found out at the upload: App Distribution answered 403 after
/// a full release build, for a service account from a different Firebase
/// project than the app. The plugin's message names no account, project or
/// role. The same question costs one read-only API call.
class FirebaseAccessCheck {
  const FirebaseAccessCheck({required this.runner, required this.scriptPath});

  final ProcessRunner runner;
  final String scriptPath;

  static String? locateScript({String? packageRoot}) => locateBundledScript(
    'tool/ruby/firebase_access_check.rb',
    packageRoot: packageRoot,
  );

  /// Runs the check in the bundle at [directory].
  Future<FirebaseAccess> check({
    required String directory,
    required String serviceAccountPath,
    required String appId,
    Map<String, String>? environment,
  }) async {
    final result = await runner.run(
      'bundle',
      <String>['exec', 'ruby', scriptPath, serviceAccountPath, appId],
      workingDirectory: directory,
      environment: environment,
    );

    final answer = _answerIn(result.stdout);
    if (answer == null) {
      return FirebaseAccess(
        FirebaseAccessOutcome.unknown,
        message: _lastLine(result.output),
      );
    }
    if (answer['ok'] == true) {
      return const FirebaseAccess(FirebaseAccessOutcome.ok);
    }

    final status = (answer['status'] as num?)?.toInt();
    final outcome = switch ((answer['stage'], status)) {
      ('auth', _) => FirebaseAccessOutcome.badCredentials,
      ('api', 401) || ('api', 403) => FirebaseAccessOutcome.denied,
      ('api', 404) => FirebaseAccessOutcome.appNotFound,
      _ => FirebaseAccessOutcome.unknown,
    };
    return FirebaseAccess(
      outcome,
      status: status,
      message: answer['message']?.toString(),
    );
  }

  /// The last line that is a JSON object. Bundler and Ruby print warnings to
  /// the same stream first.
  static Map<String, dynamic>? _answerIn(String stdout) {
    for (final line in stdout.split('\n').reversed) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('{')) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) return decoded;
      } on FormatException {
        continue;
      }
    }
    return null;
  }

  static String? _lastLine(String output) {
    final lines = output.trim().split('\n');
    return lines.last.trim().isEmpty ? null : lines.last.trim();
  }
}
