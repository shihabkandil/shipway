import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/fastlane/fastfile_lanes.dart';
import '../../core/fastlane/release_target.dart';
import '../../core/toolchain/fastlane_pins.dart';
import '../check.dart';

/// Whether the `fastlane` on PATH will actually run the bundled gems.
///
/// Homebrew installs `fastlane` as a *shell script* that overrides `GEM_HOME`
/// and `GEM_PATH` and prepends its own Ruby to `PATH` before exec'ing the real
/// binary. It therefore discards everything bundler set up, and
/// `bundle exec fastlane` silently runs a different fastlane against a
/// different gem set. The failure surfaces as
/// `Could not find <gem> in locally installed gems`, which reads like a corrupt
/// bundle and sends people off reinstalling gems for an afternoon.
///
/// The plan's rule — always `bundle exec fastlane` — is necessary but not
/// sufficient, so this check exists to say so before a release does.
class FastlaneShimCheck extends Check {
  @override
  String get id => 'fastlane-shim';

  @override
  String get title => 'fastlane on PATH';

  /// Markers a Homebrew-style wrapper leaves in its script.
  static const List<String> shimMarkers = <String>[
    'FASTLANE_INSTALLED_VIA_HOMEBREW',
    'FASTLANE_GEM_HOME',
  ];

  /// True when [contents] is a wrapper that would displace bundler's gem home.
  ///
  /// Pure, so the interesting case can be tested without installing Homebrew.
  static bool isShim(String contents) {
    if (!contents.startsWith('#!')) return false;
    final firstLine = contents.split('\n').first;
    final isScript =
        firstLine.contains('sh') ||
        firstLine.contains('bash') ||
        firstLine.contains('zsh');
    if (!isScript) return false;
    return shimMarkers.any(contents.contains) ||
        (contents.contains('GEM_HOME=') && contents.contains('exec '));
  }

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final directory = context.fastlaneDirectory;
    if (directory == null) {
      return const CheckResult.skip('No ios/ or android/ directory.');
    }

    final which = await context.runner.run('which', const <String>['fastlane']);
    if (which.notFound || !which.ok || which.stdout.trim().isEmpty) {
      // Not an error: the generated Gemfile is what supplies fastlane, and a
      // machine with none on PATH is in better shape than one with the wrong
      // one on PATH.
      return const CheckResult.ok(
        'No global fastlane; the bundled one will be used.',
      );
    }

    final path = which.stdout.trim().split('\n').first;
    final file = File(path);
    if (!file.existsSync()) {
      return CheckResult.ok('fastlane at $path');
    }

    String contents;
    try {
      contents = file.readAsStringSync();
    } on FileSystemException {
      // A real compiled binary, which is fine.
      return CheckResult.ok('fastlane at $path');
    }

    if (!isShim(contents)) {
      return CheckResult.ok('fastlane at $path');
    }

    return CheckResult.warn(
      'The fastlane at $path is a wrapper script that overrides GEM_HOME, so '
      '`bundle exec fastlane` will not use the version your Gemfile pins.',
      fixHint:
          'Run it through a binstub instead: `cd $directory && bundle '
          'binstubs fastlane` then `./bin/fastlane <lane>`.',
    );
  }
}

/// Whether the pinned gems can actually be resolved on this Ruby.
///
/// The three pins shipway writes — fastlane, the Firebase plugin, and the Ruby
/// floor — have to stay mutually satisfiable. When they are not, `bundle
/// install` does not degrade: it fails version solving outright, before
/// anything has been installed.
class GemfileSolvableCheck extends Check {
  @override
  String get id => 'gemfile-pins';

  @override
  String get title => 'Generated Gemfile pins';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    // The bundle that matters is the one a lane here would actually install:
    // ios/ where iOS can be built, android/ otherwise. Checking the iOS Gemfile
    // on a Linux machine reports on a bundle nothing there can run.
    final directory = context.fastlaneDirectory;
    if (directory == null) {
      return const CheckResult.skip('No ios/ or android/ directory.');
    }
    final gemfile = File(p.join(context.projectRoot, directory, 'Gemfile'));
    if (!gemfile.existsSync()) {
      return CheckResult.skip(
        'No $directory/Gemfile yet; run `shipway generate fastlane`.',
      );
    }

    final result = await context.runner.run('ruby', const <String>[
      '-e',
      'print RUBY_VERSION',
    ]);
    if (result.notFound || !result.ok) {
      return const CheckResult.fail(
        'Ruby is not available, so the generated Gemfile cannot be installed.',
        fixHint: 'Install Ruby ${FastlanePins.rubyFloor} or newer.',
      );
    }

    final running = result.stdout.trim();
    final floor = FastlanePins.rubyFloor;
    if (_isBelow(running, floor)) {
      return CheckResult.fail(
        'Ruby $running is below the $floor the generated Gemfile requires.',
        fixHint: 'Upgrade Ruby to $floor or newer; fastlane prefers 3.3.',
      );
    }

    return CheckResult.ok(
      'Ruby $running satisfies the generated Gemfile '
      '(fastlane ${FastlanePins.fastlane}).',
    );
  }

  /// Compares dotted version strings numerically, shortest-safe.
  static bool _isBelow(String version, String floor) {
    List<int> parts(String v) => <int>[
      for (final part in v.split('.')) int.tryParse(part) ?? 0,
    ];
    final a = parts(version);
    final b = parts(floor);
    for (var i = 0; i < b.length; i++) {
      final left = i < a.length ? a[i] : 0;
      if (left != b[i]) return left < b[i];
    }
    return false;
  }
}

/// Whether every destination `shipway.yaml` configures has a lane to run.
///
/// A target with no lane is configured on paper only. `shipway release` stops
/// on it before building, but a lane run by hand or from CI finds out from
/// fastlane, which names the missing lane and nothing that would add it.
class ReleaseLanesCheck extends Check {
  @override
  String get id => 'fastlane-lanes';

  @override
  String get title => 'Release lanes';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final config = context.config;
    final app = config?.appOrNull(null);
    if (app == null) {
      return const CheckResult.skip('No shipway.yaml to read targets from.');
    }

    final targets = <ReleaseTarget>[
      for (final target in ReleaseTarget.values)
        if (target.isConfiguredIn(app)) target,
    ];
    if (targets.isEmpty) {
      return const CheckResult.skip('No targets configured.');
    }

    final missing = <MissingLane>[];
    for (final target in targets) {
      final problem = await FastfileLanes.check(context.projectRoot, target);
      if (problem != null) missing.add(problem);
    }

    if (missing.isEmpty) {
      final names = targets.map((t) => t.id).join(', ');
      return CheckResult.ok(
        targets.length == 1 ? '$names has a lane.' : '$names each have a lane.',
      );
    }
    return CheckResult.fail(
      missing.map((m) => m.what).join(' '),
      fixHint: <String>{for (final m in missing) m.fix}.join(' '),
    );
  }
}
