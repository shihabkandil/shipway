import 'dart:io';

import 'package:path/path.dart' as p;

import '../managed/lock_file.dart';
import 'release_target.dart';

/// Why a destination's lane cannot run, and the one thing that fixes it.
class MissingLane {
  const MissingLane({
    required this.target,
    required this.what,
    required this.fix,
  });

  final ReleaseTarget target;
  final String what;
  final String fix;
}

/// Which lanes a Fastfile declares, read without running it.
///
/// Whether a lane exists used to be left to fastlane, which reports
/// `Could not find lane` only after Ruby, bundler and every gem have loaded,
/// and names nothing that would have added the lane. Asking first costs one
/// file read.
abstract final class FastfileLanes {
  /// Where a platform's Fastfile lives, relative to the project root.
  static String pathFor(String platform) => '$platform/fastlane/Fastfile';

  /// The lanes in [source] that can be run from the command line.
  ///
  /// A commented-out lane is not one, and neither is a `private_lane`.
  static Set<String> publicIn(String source) => <String>{
    for (final match in _lane.allMatches(source)) match.group(1)!,
  };

  static final RegExp _lane = RegExp(
    r'^[ \t]*lane[ \t]+:([A-Za-z_][A-Za-z0-9_]*)',
    multiLine: true,
  );

  /// Why [target]'s lane cannot run in the project at [root], or null when it
  /// is there.
  ///
  /// The fix depends on who owns the Fastfile. One shipway wrote only needs
  /// regenerating; one that was the project's own must not be replaced
  /// without somebody seeing that it will be.
  static Future<MissingLane?> check(String root, ReleaseTarget target) async {
    final path = pathFor(target.platform);
    final file = File(p.join(root, path));

    if (!file.existsSync()) {
      return MissingLane(
        target: target,
        what: 'There is no $path, so there is no `${target.lane}` lane to run.',
        fix: 'Run `shipway generate fastlane` to write it.',
      );
    }

    if (publicIn(await file.readAsString()).contains(target.lane)) return null;

    final lock = await LockFile.load(root);
    if (lock.ownershipOf(path) == Ownership.unmanaged) {
      return MissingLane(
        target: target,
        what:
            '$path is your project\'s own and has no `${target.lane}` lane '
            'for targets.${target.id}.',
        fix:
            'Add a `${target.lane}` lane to it, or run `shipway adopt $path` '
            'to replace it with the lanes shipway generates — adopt shows the '
            'difference first.',
      );
    }
    return MissingLane(
      target: target,
      what:
          '$path has no `${target.lane}` lane. It was generated before '
          'targets.${target.id} was configured.',
      fix: 'Run `shipway generate fastlane`.',
    );
  }
}
