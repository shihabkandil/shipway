import 'dart:io';

import 'package:path/path.dart' as p;

/// `pod install --repo-update`, the fix for a CocoaPods spec repo that is
/// older than the project's `Podfile.lock`.
///
/// A long-lived build machine is where this happens: the lock file moves with
/// the repository and the spec repo moves only when somebody refreshes it.
/// The fix is mechanical and safe to repeat, so `shipway release` applies it
/// once rather than failing a release on it.
abstract final class PodRepoUpdate {
  static const List<String> _install = <String>['install', '--repo-update'];

  /// The command to run in `ios/` under [projectRoot].
  ///
  /// Through the bundle when the project bundles CocoaPods, so the version
  /// that refreshes the repo is the one the build then uses; a different
  /// `pod` on `PATH` would rewrite `Podfile.lock`'s `COCOAPODS:` line.
  static ({String executable, List<String> arguments}) command(
    String projectRoot,
  ) => bundlesCocoapods(projectRoot)
      ? (executable: 'bundle', arguments: <String>['exec', 'pod', ..._install])
      : (executable: 'pod', arguments: _install);

  /// Whether `ios/Gemfile` or its lock names the `cocoapods` gem.
  ///
  /// The lock is read as well because fastlane's `cocoapods` action is often
  /// satisfied by a gem another one pulled in.
  static bool bundlesCocoapods(String projectRoot) {
    final gemfile = File(p.join(projectRoot, 'ios', 'Gemfile'));
    if (!gemfile.existsSync()) return false;
    if (_gemLine.hasMatch(gemfile.readAsStringSync())) return true;

    final lock = File(p.join(projectRoot, 'ios', 'Gemfile.lock'));
    return lock.existsSync() && _lockLine.hasMatch(lock.readAsStringSync());
  }

  static final RegExp _gemLine = RegExp(
    r'''^\s*gem\s+["']cocoapods["']''',
    multiLine: true,
  );
  static final RegExp _lockLine = RegExp(r'^\s+cocoapods \(', multiLine: true);
}
