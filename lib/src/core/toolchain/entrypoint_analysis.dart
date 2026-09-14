import 'dart:io';

import 'package:path/path.dart' as p;

import '../io/process_runner.dart';

/// Whether a flavor's Dart entrypoint compiles, asked before a build.
///
/// A Flutter release build compiles Dart partway through Gradle or Xcode, so a
/// missing symbol surfaces minutes in. A field report's generated entrypoint
/// called a `bootstrap` the project's `main_common.dart` did not define, and
/// found out that way. Analysing the one file answers it in seconds.
class EntrypointAnalysis {
  const EntrypointAnalysis._({this.errors = const <String>[], this.skipped});

  /// Each `error` line the analyzer reported. Warnings and infos never stop a
  /// build, so they never stop this.
  final List<String> errors;

  /// Why the analysis did not run, or gave no usable answer.
  final String? skipped;

  bool get failed => errors.isNotEmpty;

  static final RegExp _errorLine = RegExp(r'^\s*error\s+[-•]\s');

  static Future<EntrypointAnalysis> run(
    ProcessRunner runner, {
    required String root,
    required String entrypoint,
  }) async {
    // Unresolved packages make every import an error, which would say the
    // project is broken when it has only not been fetched. `flutter build`
    // fetches them itself, so this is a reason to skip, not to stop.
    if (!File(p.join(root, '.dart_tool', 'package_config.json')).existsSync()) {
      return const EntrypointAnalysis._(
        skipped: 'packages are not resolved yet (`flutter pub get`)',
      );
    }

    final result = await runner.run('dart', <String>[
      'analyze',
      '--no-fatal-warnings',
      entrypoint,
    ], workingDirectory: root);

    if (result.notFound) {
      return const EntrypointAnalysis._(skipped: 'dart is not on PATH');
    }
    if (result.ok) return const EntrypointAnalysis._();

    final errors = <String>[
      for (final line in result.output.split('\n'))
        if (_errorLine.hasMatch(line)) line.trim(),
    ];
    if (errors.isEmpty) {
      return EntrypointAnalysis._(
        skipped:
            'dart analyze exited ${result.exitCode} without reporting an '
            'error',
      );
    }
    return EntrypointAnalysis._(errors: errors);
  }
}
