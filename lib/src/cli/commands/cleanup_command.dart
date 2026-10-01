import 'dart:io';

import 'package:args/command_runner.dart';

import '../../secrets/secret_materialiser.dart';
import '../exit_codes.dart';
import '../run_context.dart';

/// `shipway cleanup` — removes credential files a release left behind.
///
/// `shipway release` removes what it writes itself, whether the lane passed,
/// failed or was cancelled. This is for the one ending it cannot handle: the
/// process killed outright, with no chance to run anything. A workflow on a
/// machine that keeps running calls it in an `if: always()` step, so the
/// keystore and `key.properties` from a killed job are not still there for the
/// next one to find.
///
/// Removes only what shipway can prove is its own — run directories named for
/// this checkout, and a `key.properties` carrying its marker — and succeeds
/// when there is nothing to remove, which is the usual case.
class CleanupCommand extends Command<int> {
  CleanupCommand(this._contextProvider);

  final ContextProvider _contextProvider;

  @override
  String get name => 'cleanup';

  @override
  String get description =>
      'Remove credential files left behind by a release that was killed.';

  @override
  Future<int> run() async {
    final context = _contextProvider();
    final logger = context.logger;

    final removed = <String>{
      // Both places a run directory can be: the one this job was given, and
      // the system's, in case the release ran without the runner's variable.
      for (final base in <String>{
        SecretMaterialiser.baseDirectoryFor(context.processEnvironment),
        Directory.systemTemp.path,
      })
        ...SecretMaterialiser.sweep(
          projectRoot: context.projectRoot,
          baseDirectory: base,
        ),
    };

    if (removed.isEmpty) {
      logger.info('Nothing to clean up.');
    } else {
      logger.info('Removed:');
      for (final path in removed) {
        logger.info('  $path');
      }
    }
    return ShipwayExit.success;
  }
}
