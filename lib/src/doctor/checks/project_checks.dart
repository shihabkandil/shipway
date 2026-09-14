import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/config/pipeline_references.dart';
import '../check.dart';
import '../platform_deadlines.dart';
import '../tool_version.dart';

/// Which Gradle DSL the project uses.
///
/// Informational, but load-bearing: every Android reader and writer has two
/// dialects, and knowing which one is in play is the first thing they ask.
class GradleDslCheck extends Check {
  @override
  String get id => 'gradle_dsl';

  @override
  String get title => 'Gradle DSL';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    if (!context.hasProject) {
      return const CheckResult.skip('Not inside a Flutter project.');
    }
    final kts = File(
      p.join(context.projectRoot, 'android/app/build.gradle.kts'),
    );
    final groovy = File(
      p.join(context.projectRoot, 'android/app/build.gradle'),
    );
    if (kts.existsSync()) {
      return const CheckResult.ok('Kotlin (build.gradle.kts)');
    }
    if (groovy.existsSync()) {
      return const CheckResult.ok('Groovy (build.gradle)');
    }
    return const CheckResult.fail(
      'No android/app/build.gradle or build.gradle.kts found.',
      fixHint:
          'Is this a Flutter project root? Run shipway from the directory '
          'containing pubspec.yaml.',
    );
  }
}

/// The pbxproj `objectVersion`, which tells us how fragile mutation will be.
class PbxprojObjectVersionCheck extends Check {
  @override
  String get id => 'pbxproj_object_version';

  @override
  bool get needsMacOS => true;

  @override
  String get title => 'Xcode project format';

  /// The format shipway mutates confidently.
  static const int knownGood = 60;

  /// Xcode 16+ synchronized folders. Readable, but mutation is riskier.
  static const int synchronizedFolders = 70;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    if (!context.hasIos) return const CheckResult.skip('No ios/ directory.');
    final pbxproj = File(
      p.join(context.projectRoot, 'ios/Runner.xcodeproj/project.pbxproj'),
    );
    if (!pbxproj.existsSync()) {
      return const CheckResult.warn(
        'ios/Runner.xcodeproj/project.pbxproj not found.',
        fixHint:
            'shipway cannot read or write iOS build configurations '
            'without it.',
      );
    }
    final match = RegExp(
      r'objectVersion\s*=\s*(\d+)',
    ).firstMatch(await pbxproj.readAsString());
    if (match == null) {
      return const CheckResult.warn(
        'Could not read objectVersion from project.pbxproj.',
      );
    }
    final version = int.parse(match.group(1)!);
    if (version <= knownGood) {
      return CheckResult.ok('objectVersion $version');
    }
    if (version >= synchronizedFolders) {
      return CheckResult.warn(
        'objectVersion $version — this project uses Xcode 16+ synchronized '
        'folders.',
        fixHint:
            'shipway can read it, but writing build configurations is '
            'more fragile. Every mutation is backed up to .shipway/backups/ '
            'first.',
        docsUrl: 'https://rubygems.org/gems/xcodeproj',
      );
    }
    return CheckResult.ok('objectVersion $version');
  }
}

/// The project's Gradle wrapper version.
///
/// Flutter refuses to build below its minimum, and the resulting error names a
/// Gradle version rather than anything a user would search for. It also gates
/// `shipway import --deep`, which needs a project that configures.
class GradleWrapperCheck extends Check {
  @override
  String get id => 'gradle_wrapper';

  @override
  String get title => 'Gradle wrapper';

  static const String propertiesPath =
      'android/gradle/wrapper/gradle-wrapper.properties';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    if (!context.hasProject) {
      return const CheckResult.skip('Not inside a Flutter project.');
    }
    final file = File(p.join(context.projectRoot, propertiesPath));
    if (!file.existsSync()) {
      return const CheckResult.warn(
        'No $propertiesPath found.',
        fixHint:
            'Run `flutter build apk --config-only` once to generate the '
            'Gradle wrapper.',
      );
    }

    final version = readWrapperVersion(await file.readAsString());
    if (version == null) {
      return const CheckResult.warn(
        'Could not read a Gradle version from the wrapper properties.',
      );
    }

    final floor = PlatformDeadlines.gradleWrapper;
    final minimum = ToolVersion.tryParse(floor.minimum)!;
    if (version >= minimum) return CheckResult.ok('$version', version: version);

    return CheckResult.warn(
      '$version, but Flutter requires $minimum or later.',
      version: version,
      fixHint:
          'Run `./gradlew wrapper --gradle-version $minimum` in android/, '
          'or edit distributionUrl in $propertiesPath. Until then Flutter will '
          'refuse to build, and `shipway import --deep` cannot run.',
      docsUrl: floor.sourceUrl,
    );
  }

  /// Pulls the version out of `distributionUrl`.
  ///
  /// The colon is backslash-escaped in a properties file, and the version may
  /// be two- or three-component (`8.14` and `9.3.1` are both real).
  static ToolVersion? readWrapperVersion(String properties) {
    for (final line in properties.split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('distributionUrl')) continue;
      final match = RegExp(r'gradle-(\d+(?:\.\d+){1,2})-').firstMatch(trimmed);
      if (match != null) return ToolVersion.tryParse(match.group(1)!);
    }
    return null;
  }
}

/// Google Play's `targetSdk` floor.
class PlayTargetSdkCheck extends Check {
  @override
  String get id => 'play_target_sdk';

  @override
  String get title => 'Play target API level';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    if (!context.hasProject) {
      return const CheckResult.skip('Not inside a Flutter project.');
    }
    final deadline = PlatformDeadlines.playTargetApi36;
    final required = PlatformDeadlines.playTargetSdk;

    final declared = await _readTargetSdk(context.projectRoot);
    if (declared == null) {
      // Flutter's default template inherits targetSdk from the Flutter Gradle
      // plugin, so an absent literal is normal rather than wrong.
      return CheckResult.warn(
        'No literal targetSdk found; it is inherited from the Flutter Gradle '
        'plugin.',
        fixHint:
            'Play requires API $required from '
            '${_date(deadline.enforcedFrom)}. Confirm with '
            '`./gradlew :app:properties | grep targetSdk`, or set it '
            'explicitly.',
        docsUrl: deadline.sourceUrl,
      );
    }
    if (declared >= required) {
      return CheckResult.ok('targetSdk $declared');
    }
    return CheckResult.warn(
      'targetSdk $declared, but Play requires $required.',
      fixHint:
          'Enforced from ${_date(deadline.enforcedFrom)}'
          '${deadline.extendedTo != null ? ' (extended from '
                    '${_date(deadline.effective)})' : ''}. '
          'Set `targetSdk = $required` in android/app/build.gradle[.kts].',
      docsUrl: deadline.sourceUrl,
    );
  }

  /// Reads a literal `targetSdk` / `targetSdkVersion` from either Gradle DSL.
  static Future<int?> _readTargetSdk(String root) async {
    for (final name in const ['build.gradle.kts', 'build.gradle']) {
      final file = File(p.join(root, 'android/app', name));
      if (!file.existsSync()) continue;
      final match = RegExp(
        r'targetSdk(?:Version)?\s*(?:=|\s)\s*(\d+)',
      ).firstMatch(await file.readAsString());
      if (match != null) return int.parse(match.group(1)!);
    }
    return null;
  }

  static String _date(DateTime date) =>
      '${date.year}-${_two(date.month)}-${_two(date.day)}';

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// Whether the OS keychain is reachable, since every secret ends up there.
class KeychainCheck extends Check {
  @override
  String get id => 'keychain';

  @override
  String get title => 'Keychain';

  /// `security` is macOS's, and so is everything that would be stored in it.
  @override
  bool get needsMacOS => true;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final result = await context.runner.run('security', const <String>[
      'list-keychains',
    ]);
    if (result.notFound) {
      return const CheckResult.fail(
        '`security` is not available.',
        fixHint: 'It ships with macOS; check your PATH.',
      );
    }
    if (!result.ok) {
      return CheckResult.fail(
        '`security list-keychains` failed: ${result.output.split('\n').first}',
      );
    }
    // An orphaned shipway keychain means a previous run crashed before its
    // cleanup block. Harmless, but it accumulates and it is ours to tidy.
    if (result.output.contains('shipway.keychain')) {
      return const CheckResult.warn(
        'A leftover shipway.keychain is in the search list.',
        fixHint:
            'Run `shipway setup doctor-keychain` to clean up after a '
            'crashed run.',
      );
    }
    final count = result.output
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .length;
    return CheckResult.ok(
      '$count keychain${count == 1 ? '' : 's'} in search list',
    );
  }
}

/// Firebase tooling, needed only when the config asks for it.
class FirebaseToolingCheck extends Check {
  FirebaseToolingCheck({required this.executable, required this.name});

  /// `firebase` or `flutterfire`.
  final String executable;
  final String name;

  @override
  String get id => executable;

  @override
  String get title => name;

  @override
  Future<CheckResult> run(DoctorContext context) async {
    if (!_projectUsesFirebase(context)) {
      return const CheckResult.skip('No firebase configuration declared.');
    }
    final result = await context.runner.run(executable, const <String>[
      '--version',
    ]);
    if (result.notFound || !result.ok) {
      return CheckResult.warn(
        '`$executable` is not installed or not on PATH.',
        fixHint: executable == 'flutterfire'
            ? 'Run `dart pub global activate flutterfire_cli`. Needed to '
                  'generate per-flavor Firebase options.'
            : 'Install the Firebase CLI: `npm i -g firebase-tools`.',
        docsUrl: 'https://firebase.google.com/docs/cli',
      );
    }
    return CheckResult.ok(result.output.trim().split('\n').last);
  }

  /// True when the config declares Firebase, or the project already carries
  /// Firebase config files.
  static bool _projectUsesFirebase(DoctorContext context) {
    final config = context.config;
    if (config != null) {
      for (final app in config.apps.values) {
        if (app.targets.firebase != null) return true;
        if (app.flavors.values.any((f) => f.firebase != null)) return true;
      }
    }
    return File(p.join(context.projectRoot, 'firebase.json')).existsSync() ||
        File(
          p.join(context.projectRoot, 'android/app/google-services.json'),
        ).existsSync();
  }
}

/// Whether every pipeline names flavors and targets the config has.
///
/// The same check `shipway run` makes before its first step, asked of every
/// pipeline at once. A config still loads with a typo in a pipeline — one
/// broken pipeline must not stop `shipway release` — so this is where it shows
/// up before somebody runs the pipeline.
class PipelinesCheck extends Check {
  @override
  String get id => 'pipelines';

  @override
  String get title => 'Pipelines';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final config = context.config;
    if (config == null) {
      return const CheckResult.skip('No shipway.yaml to read pipelines from.');
    }
    if (config.pipelines.isEmpty) {
      return const CheckResult.skip('No pipelines declared.');
    }

    final problems = PipelineReferences.check(config);
    if (problems.isEmpty) {
      final count = config.pipelines.length;
      return CheckResult.ok(
        '$count pipeline${count == 1 ? '' : 's'}, naming only flavors and '
        'targets this config has.',
      );
    }
    return CheckResult.fail(
      problems.map((problem) => problem.what).join(' '),
      fixHint: <String>{for (final problem in problems) problem.hint}.join(' '),
    );
  }
}
