import 'dart:io';

import 'package:path/path.dart' as p;

/// Why writing a file would leave the project unable to build, and the one
/// thing to do about it.
typedef WriteBlocker = ({String reason, String remedy});

/// What reconciling a file's existing content produced.
class ReconcileResult {
  const ReconcileResult(this.text, {this.blockers = const <WriteBlocker>[]});

  final String text;

  /// What could not be rewritten with confidence. Any entry stops the write.
  final List<WriteBlocker> blockers;
}

/// Rewrites what a block-managed file already says, so shipway's block can
/// take over from it rather than repeat it.
///
/// Runs on the text *outside* the block — the writer masks the block first —
/// and only when shipway is about to write, so what it changes appears in the
/// diff `adopt` and `generate --dry-run` show.
abstract class ContentReconciler {
  const ContentReconciler();

  ReconcileResult reconcile(String content);
}

/// Something outside a generated file that has to hold for that file to
/// compile.
abstract class WriteGuard {
  const WriteGuard();

  /// Why writing now would break the build, or null. [root] is the project.
  WriteBlocker? check(String root);
}

/// A generated file calls a function another file has to define.
///
/// The generated entrypoints call `bootstrap` in `lib/main_common.dart`. That
/// file is shipway's scaffolding only when shipway created it; a project that
/// already had one keeps its own, and a field report's had no `bootstrap` —
/// found by the Dart build, partway through a Gradle build.
class DartFunctionGuard extends WriteGuard {
  const DartFunctionGuard({
    required this.path,
    required this.caller,
    required this.name,
    required this.parameter,
    required this.signature,
    required this.example,
  });

  /// The file that must define the function.
  final String path;

  /// The generated file that calls it.
  final String caller;

  final String name;

  /// A named parameter the declaration must have.
  final String parameter;

  /// How the function is written in a message.
  final String signature;

  /// A declaration that would satisfy the caller.
  final String example;

  @override
  WriteBlocker? check(String root) {
    final file = File(p.join(root, path));
    // Absent is fine: shipway creates it, with the function, in the same run.
    if (!file.existsSync()) return null;
    final source = file.readAsStringSync();

    // Re-exported from somewhere else, perhaps. Not something to guess about;
    // the entrypoint analysis before a build answers it properly.
    if (RegExp(r'^export\s', multiLine: true).hasMatch(source)) return null;

    // A top-level declaration, with or without a return type, whose
    // parameters mention the one the caller passes.
    final declared = RegExp(
      '^(?:[A-Za-z_][\\w<>?, ]*\\s+)?${RegExp.escape(name)}\\s*\\([^)]*\\b'
      '${RegExp.escape(parameter)}\\b',
      multiLine: true,
    );
    if (declared.hasMatch(source)) return null;

    return (
      reason:
          '$caller would call `$signature` from $path, which does not define '
          'it, so the Dart build would fail.',
      remedy: 'Add it to $path, for example:\n\n$example',
    );
  }
}
