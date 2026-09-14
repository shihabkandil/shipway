import 'dart:io';

import 'package:shipway/src/core/config/config_loader.dart';
import 'package:shipway/src/core/env/host_platform.dart';
import 'package:shipway/src/doctor/check.dart';
import 'package:shipway/src/doctor/checks/fastlane_checks.dart';
import 'package:shipway/src/doctor/checks/project_checks.dart';
import 'package:shipway/src/doctor/checks/tool_checks.dart';
import 'package:shipway/src/doctor/doctor.dart';
import 'package:shipway/src/doctor/platform_deadlines.dart';
import 'package:test/test.dart';

import '../../support/recording_process_runner.dart';

/// Output from the machine this was developed on. Reused as the "healthy"
/// baseline so a regression shows up as a diff against a real environment.
void stubHealthyMachine(RecordingProcessRunner runner) {
  runner
    ..stub(
      'flutter --version',
      stdout:
          'Flutter 3.47.2 • channel stable • '
          'https://github.com/flutter/flutter.git\n'
          'Tools • Dart 3.13.2 • DevTools 2.60.0',
    )
    ..stub(
      'dart --version',
      stdout: 'Dart SDK version: 3.13.2 (stable) on "macos_arm64"',
    )
    ..stub('xcodebuild -version', stdout: 'Xcode 26.6\nBuild version 17F113')
    ..stub('pod --version', stdout: '1.17.0')
    ..stub(
      'ruby --version',
      stdout: 'ruby 3.4.1p18 (2025-02-18 revision 53f5fc4236) [arm64-darwin23]',
    )
    ..stub('bundle --version', stdout: 'Bundler version 2.6.3')
    ..stub('fastlane --version', stdout: 'fastlane 2.238.0')
    ..stub('gem list xcodeproj', stdout: 'xcodeproj (1.28.1, 1.27.0)')
    ..stub('java -version', stderr: 'openjdk version "21.0.4" 2024-07-16')
    ..stub(
      'security list-keychains',
      stdout: '    "/Users/x/Library/Keychains/login.keychain-db"',
    )
    ..stub('firebase --version', stdout: '15.28.1')
    ..stub('flutterfire --version', stdout: '1.3.1');
}

/// A minimal Flutter-shaped project on disk, so the file-reading checks have
/// something real to look at.
Future<Directory> makeProject({
  String gradleDsl = 'kts',
  int? targetSdk = 36,
  bool ios = true,
  int objectVersion = 60,
  String gradleWrapper = '8.14',
}) async {
  final dir = await Directory.systemTemp.createTemp('shipway_doctor');
  File('${dir.path}/pubspec.yaml').writeAsStringSync('name: demo\n');
  Directory('${dir.path}/android/app').createSync(recursive: true);
  final gradleName = gradleDsl == 'kts' ? 'build.gradle.kts' : 'build.gradle';
  File('${dir.path}/android/app/$gradleName').writeAsStringSync('''
android {
    defaultConfig {
        ${targetSdk == null ? '' : 'targetSdk = $targetSdk'}
    }
}
''');
  final wrapperProperties = File(
    '${dir.path}/android/gradle/wrapper/gradle-wrapper.properties',
  )..parent.createSync(recursive: true);
  wrapperProperties.writeAsStringSync(
    r'distributionUrl=https\://services.gradle.org/distributions/'
    'gradle-$gradleWrapper-all.zip\n',
  );

  if (ios) {
    Directory('${dir.path}/ios/Runner.xcodeproj').createSync(recursive: true);
    File(
      '${dir.path}/ios/Runner.xcodeproj/project.pbxproj',
    ).writeAsStringSync('{ objectVersion = $objectVersion; }');
  }
  return dir;
}

DoctorContext contextFor(
  RecordingProcessRunner runner,
  Directory project, {
  String? configYaml,
  DateTime? now,
  // Pinned rather than taken from the machine running the tests: the healthy
  // baseline below is a Mac, and it should stay one wherever this suite runs.
  HostPlatform host = HostPlatform.macos,
}) => DoctorContext(
  runner: runner,
  projectRoot: project.path,
  config: configYaml == null ? null : ConfigLoader.parse(configYaml),
  now: now ?? DateTime.utc(2026, 9, 8),
  host: host,
);

void main() {
  group('a healthy machine', () {
    test('passes every check', () async {
      final runner = RecordingProcessRunner();
      stubHealthyMachine(runner);
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));

      final report = await Doctor().run(contextFor(runner, project));

      expect(report.passed, isTrue);
      expect(report.count(CheckStatus.fail), 0);
      final failing = report
          .withStatus(CheckStatus.warn)
          .map((e) => '${e.check.id}: ${e.result.detail}');
      expect(failing, isEmpty, reason: 'unexpected warnings: $failing');
    });
  });

  group('this machine, which is the negative fixture', () {
    /// Ruby 3.1.1 and JDK 18 are deliberately not fixed locally: they are the
    /// only live proof that the warn path works.
    test('warns on Ruby 3.1 and JDK 18 but still passes overall', () async {
      final runner = RecordingProcessRunner();
      stubHealthyMachine(runner);
      runner
        ..stub(
          'ruby --version',
          stdout:
              'ruby 3.1.1p18 (2022-02-18 revision 53f5fc4236) '
              '[arm64-darwin23]',
        )
        ..stub(
          'java -version',
          stderr:
              'java version "18.0.2.1" 2022-08-18\n'
              'Java(TM) SE Runtime Environment (build 18.0.2.1+1-1)',
        );
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));

      final report = await Doctor().run(contextFor(runner, project));

      expect(report.passed, isTrue, reason: 'warnings must not block shipping');
      expect(
        report.withStatus(CheckStatus.warn).map((e) => e.check.id),
        containsAll(<String>['ruby', 'jdk']),
      );
      final ruby = report.entries.firstWhere((e) => e.check.id == 'ruby');
      expect(ruby.result.detail, contains('3.1.1'));
      expect(ruby.result.fixHint, contains('fastlane targets Ruby 3.3+'));
      final jdk = report.entries.firstWhere((e) => e.check.id == 'jdk');
      expect(jdk.result.fixHint, contains('--deep'));
    });
  });

  group('a broken environment fails with an actionable hint', () {
    test('Ruby 2.7 fails rather than warns', () async {
      final runner = RecordingProcessRunner();
      stubHealthyMachine(runner);
      runner.stub('ruby --version', stdout: 'ruby 2.7.6p219 (2022-04-12)');
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));

      final report = await Doctor().run(contextFor(runner, project));
      final ruby = report.entries.firstWhere((e) => e.check.id == 'ruby');

      expect(ruby.result.status, CheckStatus.fail);
      expect(ruby.result.detail, contains('2.7.6 found, 3.0.0 or later'));
      expect(ruby.result.fixHint, contains('rbenv'));
      expect(report.passed, isFalse);
    });

    test('xcodeproj 1.22 fails and names the Xcode 16 symptom', () async {
      final runner = RecordingProcessRunner();
      stubHealthyMachine(runner);
      runner.stub('gem list xcodeproj', stdout: 'xcodeproj (1.22.0)');
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));

      final report = await Doctor().run(contextFor(runner, project));
      final gem = report.entries.firstWhere(
        (e) => e.check.id == 'xcodeproj_gem',
      );

      expect(gem.result.status, CheckStatus.fail);
      expect(gem.result.fixHint, contains('gem update xcodeproj'));
      expect(
        gem.result.fixHint,
        contains('PBXFileSystemSynchronizedRootGroup'),
      );
      expect(report.passed, isFalse);
    });

    test(
      'an Xcode older than 26 fails, citing the store requirement',
      () async {
        final runner = RecordingProcessRunner();
        stubHealthyMachine(runner);
        runner.stub(
          'xcodebuild -version',
          stdout: 'Xcode 15.4\nBuild version 15F31d',
        );
        final project = await makeProject();
        addTearDown(() => project.delete(recursive: true));

        final report = await Doctor().run(contextFor(runner, project));
        final xcode = report.entries.firstWhere((e) => e.check.id == 'xcode');

        expect(xcode.result.status, CheckStatus.fail);
        expect(xcode.result.fixHint, contains('2026-04-28'));
      },
    );

    test('a missing tool fails with an install hint, not a crash', () async {
      final runner = RecordingProcessRunner();
      stubHealthyMachine(runner);
      runner.stub('fastlane --version', exitCode: 127, stderr: 'not found');
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));

      final report = await Doctor().run(contextFor(runner, project));
      final fastlane = report.entries.firstWhere(
        (e) => e.check.id == 'fastlane',
      );

      expect(fastlane.result.status, CheckStatus.fail);
      expect(fastlane.result.fixHint, contains('gem install fastlane'));
    });
  });

  group('project-shape checks', () {
    test('detects both Gradle DSLs', () async {
      final runner = RecordingProcessRunner();
      for (final entry in {'kts': 'Kotlin', 'groovy': 'Groovy'}.entries) {
        final project = await makeProject(gradleDsl: entry.key);
        addTearDown(() => project.delete(recursive: true));
        final result = await GradleDslCheck().run(contextFor(runner, project));
        expect(result.status, CheckStatus.ok);
        expect(result.detail, contains(entry.value));
      }
    });

    test('warns on objectVersion 70 without failing', () async {
      final runner = RecordingProcessRunner();
      final project = await makeProject(objectVersion: 70);
      addTearDown(() => project.delete(recursive: true));

      final result = await PbxprojObjectVersionCheck().run(
        contextFor(runner, project),
      );

      expect(result.status, CheckStatus.warn);
      expect(result.detail, contains('synchronized folders'));
      expect(result.fixHint, contains('.shipway/backups/'));
    });

    test('accepts objectVersion 60', () async {
      final runner = RecordingProcessRunner();
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));
      final result = await PbxprojObjectVersionCheck().run(
        contextFor(runner, project),
      );
      expect(result.status, CheckStatus.ok);
    });

    test('warns when the Gradle wrapper is below Flutter\'s minimum', () async {
      final runner = RecordingProcessRunner();
      final project = await makeProject(gradleWrapper: '8.12');
      addTearDown(() => project.delete(recursive: true));

      final result = await GradleWrapperCheck().run(
        contextFor(runner, project),
      );

      expect(result.status, CheckStatus.warn);
      expect(result.detail, contains('8.12.0'));
      expect(result.fixHint, contains('gradlew wrapper --gradle-version'));
      // It also explains the knock-on effect, which is otherwise baffling.
      expect(result.fixHint, contains('--deep'));
    });

    test('accepts a wrapper at or above the floor', () async {
      final runner = RecordingProcessRunner();
      for (final version in const <String>['8.14', '9.3.1']) {
        final project = await makeProject(gradleWrapper: version);
        addTearDown(() => project.delete(recursive: true));
        expect(
          (await GradleWrapperCheck().run(contextFor(runner, project))).status,
          CheckStatus.ok,
          reason: 'Gradle $version should pass',
        );
      }
    });

    test('reads the version past the escaped colon in a properties file', () {
      // A properties file escapes the colon, and the version may be two- or
      // three-component; both forms are real.
      expect(
        GradleWrapperCheck.readWrapperVersion(
          r'distributionUrl=https\://services.gradle.org/distributions/gradle-8.14-all.zip',
        ).toString(),
        '8.14.0',
      );
      expect(
        GradleWrapperCheck.readWrapperVersion(
          r'distributionUrl=https\://services.gradle.org/distributions/gradle-9.3.1-bin.zip',
        ).toString(),
        '9.3.1',
      );
      expect(GradleWrapperCheck.readWrapperVersion('nothing here'), isNull);
    });

    test('warns when targetSdk is below the Play floor', () async {
      final runner = RecordingProcessRunner();
      final project = await makeProject(targetSdk: 34);
      addTearDown(() => project.delete(recursive: true));

      final result = await PlayTargetSdkCheck().run(
        contextFor(runner, project),
      );

      expect(result.status, CheckStatus.warn);
      expect(result.detail, contains('targetSdk 34'));
      // The extension date, not the original, is what actually binds.
      expect(result.fixHint, contains('2026-11-01'));
    });

    test('accepts targetSdk at the floor', () async {
      final runner = RecordingProcessRunner();
      final project = await makeProject(targetSdk: 36);
      addTearDown(() => project.delete(recursive: true));
      expect(
        (await PlayTargetSdkCheck().run(contextFor(runner, project))).status,
        CheckStatus.ok,
      );
    });

    test('skips iOS checks when there is no ios/ directory', () async {
      final runner = RecordingProcessRunner();
      final project = await makeProject(ios: false);
      addTearDown(() => project.delete(recursive: true));
      expect(
        (await XcodeprojGemCheck().run(contextFor(runner, project))).status,
        CheckStatus.skip,
      );
    });

    test('reports a leftover shipway keychain', () async {
      final runner = RecordingProcessRunner()
        ..stub(
          'security list-keychains',
          stdout:
              '    "/Users/x/Library/Keychains/login.keychain-db"\n'
              '    "/Users/x/Library/Keychains/shipway.keychain-db"',
        );
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));

      final result = await KeychainCheck().run(contextFor(runner, project));
      if (Platform.isMacOS) {
        expect(result.status, CheckStatus.warn);
        expect(result.fixHint, contains('doctor-keychain'));
      } else {
        expect(result.status, CheckStatus.skip);
      }
    });
  });

  group('Flutter floor comes from the config when declared', () {
    test(
      'fails when the project asks for a newer Flutter than is installed',
      () async {
        final runner = RecordingProcessRunner();
        stubHealthyMachine(runner);
        final project = await makeProject();
        addTearDown(() => project.delete(recursive: true));

        final report = await Doctor(checks: [FlutterCheck()]).run(
          contextFor(
            runner,
            project,
            configYaml: '''
version: 1
project:
  name: demo
  flutter_min: "3.99.0"
apps:
  main:
''',
          ),
        );

        final flutter = report.entries.single;
        expect(flutter.result.status, CheckStatus.fail);
        expect(flutter.result.detail, contains('3.99.0 or later required'));
        expect(flutter.result.fixHint, contains('flutter_min'));
      },
    );
  });

  group('firebase checks activate on demand', () {
    test('skip without firebase config, run with it', () async {
      final runner = RecordingProcessRunner()
        ..stub('flutterfire --version', exitCode: 127, stderr: 'not found');
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));
      final check = FirebaseToolingCheck(
        executable: 'flutterfire',
        name: 'flutterfire',
      );

      expect(
        (await check.run(contextFor(runner, project))).status,
        CheckStatus.skip,
      );

      final withFirebase = await check.run(
        contextFor(
          runner,
          project,
          configYaml: '''
version: 1
project:
  name: demo
apps:
  main:
    targets:
      firebase:
        groups: [testers]
''',
        ),
      );
      expect(withFirebase.status, CheckStatus.warn);
      expect(withFirebase.fixHint, contains('flutterfire_cli'));
    });
  });

  group('release lanes', () {
    const config = '''
version: 1
project:
  name: demo
apps:
  main:
    android:
      application_id: com.acme.app
    flavors:
      dev:
        suffix: .dev
    targets:
      play:
        track: internal
      firebase:
        groups: [qa]
''';

    Future<CheckResult> checkWith(String? fastfile) async {
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));
      if (fastfile != null) {
        File('${project.path}/android/fastlane/Fastfile')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(fastfile);
      }
      return ReleaseLanesCheck().run(
        contextFor(RecordingProcessRunner(), project, configYaml: config),
      );
    }

    test('skip without a config to read targets from', () async {
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));
      final result = await ReleaseLanesCheck().run(
        contextFor(RecordingProcessRunner(), project),
      );
      expect(result.status, CheckStatus.skip);
    });

    test('a configured target with no lane fails, saying what to do', () async {
      // The report's first problem: targets.firebase was set and the Fastfile
      // had no way to get there, found only when a release ran.
      final result = await checkWith('lane :play do\nend\n');

      expect(result.status, CheckStatus.fail);
      expect(result.detail, contains('`firebase` lane'));
      expect(result.fixHint, contains('shipway adopt'));
    });

    test('every target with a lane passes', () async {
      final result = await checkWith(
        'lane :play do\nend\nlane :firebase do\nend\n',
      );
      expect(result.status, CheckStatus.ok);
      expect(result.detail, contains('play, firebase'));
    });
  });

  group('report', () {
    test('a crashing check degrades to a warning, not a lost report', () async {
      final report = await Doctor(
        checks: [_ExplodingCheck()],
      ).run(contextFor(RecordingProcessRunner(), await makeProject()));
      expect(report.entries.single.result.status, CheckStatus.warn);
      expect(report.entries.single.result.detail, contains('crashed'));
      expect(report.passed, isTrue);
    });

    test('JSON carries every documented field', () async {
      final runner = RecordingProcessRunner();
      stubHealthyMachine(runner);
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));

      final json = (await Doctor().run(contextFor(runner, project))).toJson();

      expect(json['passed'], isTrue);
      expect(json['summary'], isA<Map<String, int>>());
      expect(json['deadlineDataLastVerified'], isA<String>());
      expect(json['deadlineDataStale'], isFalse);
      final checks = json['checks'] as List<dynamic>;
      expect(checks, isNotEmpty);
      for (final entry in checks.cast<Map<String, dynamic>>()) {
        expect(entry['id'], isA<String>());
        expect(entry['title'], isA<String>());
        expect(entry['status'], isIn(<String>['ok', 'warn', 'fail', 'skip']));
        expect(entry['detail'], isA<String>());
      }
    });

    test('flags deadline data as stale once it ages out', () async {
      final runner = RecordingProcessRunner();
      stubHealthyMachine(runner);
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));

      final stale = PlatformDeadlines.lastVerified.add(
        const Duration(days: PlatformDeadlines.staleAfterDays + 1),
      );
      final json = (await Doctor().run(
        contextFor(runner, project, now: stale),
      )).toJson();
      expect(json['deadlineDataStale'], isTrue);
    });
  });

  group('a Linux machine building Android only', () {
    /// The whole point: none of Apple's tooling is there, and none of it being
    /// there is not a failure. A doctor that reports six failures for tools
    /// that were never going to exist tells someone their machine cannot ship
    /// an app it ships fine.
    Future<DoctorReport> linuxReport({
      void Function(RecordingProcessRunner)? stub,
    }) async {
      final runner = RecordingProcessRunner();
      stubHealthyMachine(runner);
      // Nothing Apple answers here.
      for (final command in const <String>[
        'xcodebuild -version',
        'pod --version',
        'gem list xcodeproj',
        'security list-keychains',
      ]) {
        runner.stub(command, exitCode: 127, stderr: 'command not found');
      }
      stub?.call(runner);
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));
      return Doctor().run(
        contextFor(runner, project, host: HostPlatform.linux),
      );
    }

    test('passes, with the Apple checks skipped rather than failed', () async {
      final report = await linuxReport();

      expect(report.passed, isTrue);
      final skipped = <String>[
        for (final entry in report.withStatus(CheckStatus.skip)) entry.check.id,
      ];
      expect(
        skipped,
        containsAll(<String>[
          'xcode',
          'cocoapods',
          'xcodeproj_gem',
          'pbxproj_object_version',
          'keychain',
        ]),
      );
    });

    test('does not run the tools it skipped', () async {
      // A skip that still shells out is a skip in the report only: it costs
      // the same time and can still fail in a way the report does not show.
      final runner = RecordingProcessRunner();
      stubHealthyMachine(runner);
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));

      await Doctor().run(contextFor(runner, project, host: HostPlatform.linux));

      expect(runner.ran('xcodebuild'), isFalse);
      expect(runner.ran('security'), isFalse);
    });

    test('the Android toolchain is still checked properly', () async {
      // Skipping iOS must not turn doctor into a no-op: a broken JDK on a
      // Linux builder is still the thing that stops a release.
      final report = await linuxReport(
        stub: (runner) =>
            runner.stub('java -version', exitCode: 127, stderr: 'not found'),
      );

      expect(report.passed, isFalse);
      final jdk = report.entries.firstWhere((e) => e.check.id == 'jdk');
      expect(jdk.result.status, CheckStatus.fail);
    });

    test('the report says which machine it describes', () async {
      // `passed` means something narrower here, and JSON has no other way to
      // say so.
      final json = (await linuxReport()).toJson();
      expect(json['host'], 'linux');
      expect(json['canBuildIos'], isFalse);
    });
  });

  group('the Gemfile checked is the one this machine would install', () {
    /// A Linux builder installs `android/Gemfile` and never touches
    /// `ios/Gemfile`. Reporting on the iOS one there describes a bundle
    /// nothing on that machine can run — and stays quiet about the one that
    /// will actually fail.
    Future<CheckResult> pinsCheck(HostPlatform host) async {
      final runner = RecordingProcessRunner();
      stubHealthyMachine(runner);
      runner.stub('ruby -e', stdout: '3.4.1');
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));
      File(
        '${project.path}/android/Gemfile',
      ).writeAsStringSync("source 'https://rubygems.org'\ngem 'fastlane'\n");

      final report = await Doctor(
        checks: <Check>[GemfileSolvableCheck()],
      ).run(contextFor(runner, project, host: host));
      return report.entries.single.result;
    }

    test('Linux reads android/Gemfile', () async {
      final result = await pinsCheck(HostPlatform.linux);
      expect(result.status, CheckStatus.ok);
    });

    test(
      'a Mac still asks about the iOS one, and says it is missing',
      () async {
        final result = await pinsCheck(HostPlatform.macos);
        expect(result.status, CheckStatus.skip);
        expect(result.detail, contains('ios/Gemfile'));
      },
    );
  });

  group('locked Android gems', () {
    String lock(String core) =>
        '''
GEM
  remote: https://rubygems.org/
  specs:
    fastlane (2.238.0)
      google-apis-core (>= 0.11.0, < 2.a)
    fastlane-plugin-firebase_app_distribution (0.10.1)
    google-apis-core ($core)
      faraday (~> 2.13)
''';

    Future<CheckResult> checkWith(
      String? lockContents, {
      String? config,
    }) async {
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));
      if (lockContents != null) {
        File(
          '${project.path}/android/Gemfile.lock',
        ).writeAsStringSync(lockContents);
      }
      return GemLockCheck().run(
        contextFor(RecordingProcessRunner(), project, configYaml: config),
      );
    }

    const firebaseConfig = '''
version: 1
project:
  name: demo
apps:
  main:
    targets:
      firebase:
        groups: [qa]
''';

    test('reads what was chosen, not what was required', () {
      final locked = GemLockCheck.lockedVersions(lock('0.18.0'));
      expect(locked['google-apis-core'], '0.18.0');
      expect(locked['fastlane'], '2.238.0');
    });

    test('the field report\'s lock fails where Firebase is shipped', () async {
      final result = await checkWith(lock('1.1.0'), config: firebaseConfig);
      expect(result.status, CheckStatus.fail);
      expect(result.detail, contains('google-apis-core 1.1.0'));
      expect(result.fixHint, contains('bundle update google-apis-core'));
    });

    test('and only warns where it is not', () async {
      expect((await checkWith(lock('1.1.0'))).status, CheckStatus.warn);
    });

    test('the known-good set passes', () async {
      expect(
        (await checkWith(lock('0.18.0'), config: firebaseConfig)).status,
        CheckStatus.ok,
      );
    });

    test('no lock file yet is not a problem to report', () async {
      expect((await checkWith(null)).status, CheckStatus.skip);
    });
  });

  group('pipelines', () {
    Future<CheckResult> checkWith(String pipelines) async {
      final project = await makeProject();
      addTearDown(() => project.delete(recursive: true));
      return PipelinesCheck().run(
        contextFor(
          RecordingProcessRunner(),
          project,
          configYaml:
              '''
version: 1
project:
  name: demo
apps:
  main:
    flavors:
      development:
        suffix: .dev
      production:
        suffix: ""
    targets:
      play:
        track: internal
$pipelines
''',
        ),
      );
    }

    test('a misspelt flavor fails, with the likely name', () async {
      final result = await checkWith(
        'pipelines:\n  beta:\n    - release: { flavor: prod, target: play }',
      );
      expect(result.status, CheckStatus.fail);
      expect(result.detail, contains('Did you mean `production`?'));
    });

    test('correct pipelines pass', () async {
      final result = await checkWith(
        'pipelines:\n  beta:\n    - release: { flavor: production, target: play }',
      );
      expect(result.status, CheckStatus.ok);
    });
  });
}

class _ExplodingCheck extends Check {
  @override
  String get id => 'boom';

  @override
  String get title => 'Boom';

  @override
  Future<CheckResult> run(DoctorContext context) async =>
      throw StateError('kaboom');
}
