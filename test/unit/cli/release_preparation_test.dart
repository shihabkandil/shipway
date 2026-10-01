import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:shipway/src/cli/exit_codes.dart';
import 'package:shipway/src/cli/shipway_command_runner.dart';
import 'package:shipway/src/core/env/host_platform.dart';
import 'package:shipway/src/secrets/secret_materialiser.dart';
import 'package:test/test.dart';

import '../../support/fastlane_toolchain.dart';
import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

class _CapturingLogger extends Logger {
  final List<String> lines = <String>[];

  @override
  void info(String? message, {LogStyle? style}) => lines.add(message ?? '');

  @override
  void err(String? message, {LogStyle? style}) => lines.add(message ?? '');

  @override
  void warn(String? message, {String tag = 'WARN', LogStyle? style}) =>
      lines.add(message ?? '');

  @override
  void detail(String? message, {LogStyle? style}) => lines.add(message ?? '');

  @override
  void write(String? message) => lines.add(message ?? '');

  String get output => lines.join('\n');
}

const String _config = '''
version: 1
project:
  name: acme_app
apps:
  main:
    path: .
    android:
      application_id: com.acme.app
    signing:
      android:
        keystore_ref: ANDROID_KEYSTORE_BASE64
        key_properties:
          store_password_ref: ANDROID_STORE_PASSWORD
          key_password_ref: ANDROID_KEY_PASSWORD
    flavors:
      dev:
        suffix: .dev
    targets:
      play:
        track: internal
''';

const String _lane = 'android play flavor:dev';

void main() {
  late FixtureProject project;
  late Directory runnerTemp;
  late _CapturingLogger logger;
  late RecordingProcessRunner runner;
  late Map<String, String> secrets;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    runnerTemp = await Directory.systemTemp.createTemp('shipway_runner_temp');
    addTearDown(() async {
      if (runnerTemp.existsSync()) await runnerTemp.delete(recursive: true);
    });
    project
      ..write('shipway.yaml', _config)
      ..write(
        'android/fastlane/Fastfile',
        'platform :android do\n  lane :play do\n  end\nend\n',
      );
    logger = _CapturingLogger();
    runner = RecordingProcessRunner();
    stubFastlaneToolchain(runner);
    runner.stub('sysctl -n hw.memsize', stdout: '17179869184');

    // What a runner holds: content, never paths.
    secrets = <String, String>{
      'RUNNER_TEMP': runnerTemp.path,
      'PLAY_SERVICE_ACCOUNT_JSON': '{"client_email":"ci@acme.iam"}',
      'ANDROID_KEYSTORE_BASE64': base64.encode(<int>[1, 2, 3, 4]),
      'ANDROID_STORE_PASSWORD': 'store-secret',
      'ANDROID_KEY_PASSWORD': 'key-secret',
    };
  });

  Future<int> release({
    String env = 'persistent',
    List<String> extra = const <String>[],
  }) =>
      ShipwayCommandRunner(
        logger: logger,
        runner: runner,
        workingDirectory: project.path,
        host: HostPlatform.macos,
        environment: secrets,
      ).run(<String>[
        '--config=${project.path}/shipway.yaml',
        '--env=$env',
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'play',
        '--no-analyze',
        ...extra,
      ]);

  List<String> leftBehind() => <String>[
    for (final entity in runnerTemp.listSync()) p.basename(entity.path),
    if (project.exists('android/key.properties')) 'android/key.properties',
  ];

  group('credential files on a build machine', () {
    test(
      'exist while the lane runs, and the lane is pointed at them',
      () async {
        String? accountDuringLane;
        String? propertiesDuringLane;
        runner.onRun = (invocation) {
          if (!invocation.commandLine.contains(_lane)) return;
          final path =
              invocation.environment!['PLAY_SERVICE_ACCOUNT_JSON_PATH']!;
          accountDuringLane = File(path).readAsStringSync();
          propertiesDuringLane = project.read('android/key.properties');
        };

        expect(await release(), ShipwayExit.success);

        expect(accountDuringLane, contains('ci@acme.iam'));
        expect(propertiesDuringLane, contains('storePassword=store-secret'));
      },
    );

    test('are gone when the release has finished', () async {
      expect(await release(), ShipwayExit.success);
      expect(leftBehind(), isEmpty);
    });

    test('are gone when the lane failed', () async {
      // The case the YAML never handled: a step that fails skips every step
      // after it, including the one that was going to tidy up.
      runner.stub(_lane, exitCode: 1, lines: <String>['boom']);

      expect(await release(), ShipwayExit.environmentError);
      expect(leftBehind(), isEmpty);
    });

    test('are gone after a dry run, which returns before the lane', () async {
      expect(await release(extra: <String>['--dry-run']), ShipwayExit.success);
      expect(runner.ran(_lane), isFalse);
      expect(leftBehind(), isEmpty);
    });

    test('are gone when the bundle turned out to be unusable', () async {
      runner.stub('RUBY_VERSION', exitCode: 1, stderr: 'Could not find rake');

      expect(await release(), ShipwayExit.environmentError);
      expect(runner.ran(_lane), isFalse);
      expect(leftBehind(), isEmpty);
    });

    test('a keystore that is not base64 stops the release, cleanly', () async {
      secrets['ANDROID_KEYSTORE_BASE64'] = 'not base64!';

      expect(await release(), ShipwayExit.environmentError);
      expect(logger.output, contains('ANDROID_KEYSTORE_BASE64 is not base64'));
      expect(runner.ran(_lane), isFalse);
      expect(leftBehind(), isEmpty);
    });

    test('work the same on a hosted runner', () async {
      // One code path, so the persistent case is exercised by every hosted
      // run rather than only on the machine where it matters.
      var existed = false;
      runner.onRun = (invocation) {
        if (!invocation.commandLine.contains(_lane)) return;
        existed = File(
          invocation.environment!['PLAY_SERVICE_ACCOUNT_JSON_PATH']!,
        ).existsSync();
      };

      expect(await release(env: 'ci'), ShipwayExit.success);
      expect(existed, isTrue);
      expect(leftBehind(), isEmpty);
    });

    test('never contain a value in what is printed', () async {
      await release();
      expect(logger.output, isNot(contains('store-secret')));
      expect(logger.output, isNot(contains('ci@acme.iam"')));
    });

    test('are not written on a workstation', () async {
      // A developer's machine has its own key files, and none of this is
      // shipway's to rearrange.
      project
        ..write('play.json', '{}')
        ..write('.env', '''
PLAY_SERVICE_ACCOUNT_JSON_PATH=play.json
ANDROID_KEYSTORE_BASE64=x
ANDROID_STORE_PASSWORD=x
ANDROID_KEY_PASSWORD=x
''');
      var propertiesDuringLane = true;
      runner.onRun = (invocation) {
        if (!invocation.commandLine.contains(_lane)) return;
        propertiesDuringLane = project.exists('android/key.properties');
      };

      expect(await release(env: 'workstation'), ShipwayExit.success);

      expect(propertiesDuringLane, isFalse);
      expect(runnerTemp.listSync(), isEmpty);
    });
  });

  group('the bundle on a build machine', () {
    setUp(() => project.write('android/Gemfile', 'gem "fastlane"\n'));

    test('is installed when it is not satisfied', () async {
      // With no cache action there is nothing else to do it.
      runner.stub('bundle check', exitCode: 1);

      expect(await release(), ShipwayExit.success);

      final commands = runner.commandLines;
      final install = commands.indexWhere(
        (c) => c.startsWith('bundle install'),
      );
      expect(install, isNot(-1));
      expect(
        runner.invocation('bundle install').workingDirectory,
        p.join(project.path, 'android'),
      );
      // Before the probe, which is what would otherwise report it missing.
      expect(
        install,
        lessThan(commands.indexWhere((c) => c.contains('RUBY_VERSION'))),
      );
    });

    test('is left alone when it is already there', () async {
      // The usual answer on a machine that keeps its gems, and it costs a
      // second rather than a resolve.
      expect(await release(), ShipwayExit.success);
      expect(runner.ran('bundle check'), isTrue);
      expect(runner.ran('bundle install'), isFalse);
    });

    test('a failed install stops the release and says why', () async {
      runner
        ..stub('bundle check', exitCode: 1)
        ..stub(
          'bundle install',
          exitCode: 5,
          lines: <String>['Could not find gem fastlane'],
        );

      expect(await release(), ShipwayExit.environmentError);
      expect(logger.output, contains('`bundle install` failed in android/'));
      expect(logger.output, contains('Could not find gem fastlane'));
      expect(runner.ran(_lane), isFalse);
      expect(leftBehind(), isEmpty);
    });

    test('is not touched on a workstation', () async {
      project
        ..write('play.json', '{}')
        ..write('.env', '''
PLAY_SERVICE_ACCOUNT_JSON_PATH=play.json
ANDROID_KEYSTORE_BASE64=x
ANDROID_STORE_PASSWORD=x
ANDROID_KEY_PASSWORD=x
''');
      runner.stub('bundle check', exitCode: 1);

      expect(await release(env: 'workstation'), ShipwayExit.success);
      expect(runner.ran('bundle check'), isFalse);
      expect(runner.ran('bundle install'), isFalse);
    });
  });

  group('Gradle on a build machine', () {
    test('is limited through the lane\'s environment, from the machine\'s '
        'memory', () async {
      expect(await release(), ShipwayExit.success);

      final options = runner.invocation(_lane).environment!['GRADLE_OPTS']!;
      // 16 GB machine: a 4 GB heap, not the 8 GB gradle.properties asks for.
      expect(options, contains('-Dorg.gradle.jvmargs="-Xmx4096m'));
      expect(options, contains('-Dorg.gradle.workers.max=4'));
      expect(options, contains('-Dorg.gradle.daemon=false'));
      expect(logger.output, contains('Gradle is limited to heap 4 GB'));
    });

    test('keeps what the runner already set', () async {
      secrets['GRADLE_OPTS'] = '-Dorg.gradle.caching=true';
      await release();
      expect(
        runner.invocation(_lane).environment!['GRADLE_OPTS'],
        endsWith(' -Dorg.gradle.caching=true'),
      );
    });

    test('falls back when the memory cannot be read', () async {
      runner.stub('sysctl', exitCode: 1);
      await release();
      expect(
        runner.invocation(_lane).environment!['GRADLE_OPTS'],
        contains('-Xmx2048m'),
      );
      expect(logger.output, contains('could not read'));
    });

    test('writes nothing to the shared Gradle home', () async {
      // ~/.gradle on a self-hosted runner is every project's. Asserted on the
      // only two ways shipway could reach it: a command, or a variable.
      await release();
      expect(runner.commandLines.where((c) => c.contains('.gradle')), isEmpty);
      expect(
        runner.invocation(_lane).environment!.keys,
        isNot(contains('GRADLE_USER_HOME')),
      );
    });

    test('is left to gradle.properties on a workstation', () async {
      project
        ..write('play.json', '{}')
        ..write('.env', '''
PLAY_SERVICE_ACCOUNT_JSON_PATH=play.json
ANDROID_KEYSTORE_BASE64=x
ANDROID_STORE_PASSWORD=x
ANDROID_KEY_PASSWORD=x
''');
      await release(env: 'workstation');
      expect(
        runner.invocation(_lane).environment!.keys,
        isNot(contains('GRADLE_OPTS')),
      );
      expect(runner.ran('sysctl'), isFalse);
    });
  });

  group('shipway cleanup', () {
    Future<int> cleanup() => ShipwayCommandRunner(
      logger: logger,
      runner: runner,
      workingDirectory: project.path,
      host: HostPlatform.macos,
      environment: secrets,
    ).run(<String>['cleanup']);

    test('removes what a killed release left', () async {
      // Stand in for the process dying mid-lane: written, never cleaned up.
      final killed = SecretMaterialiser(
        projectRoot: project.path,
        read: (name) async => secrets[name],
        baseDirectory: runnerTemp.path,
      );
      await killed.pathVariables(<String>['PLAY_SERVICE_ACCOUNT_JSON_PATH']);
      expect(leftBehind(), isNotEmpty);

      expect(await cleanup(), ShipwayExit.success);

      expect(leftBehind(), isEmpty);
      expect(logger.output, contains('Removed:'));
    });

    test('succeeds with nothing to do, which is the usual case', () async {
      // It runs under `if: always()`. A cleanup that fails a green job because
      // the job was tidy would be removed from the workflow within a week.
      expect(await cleanup(), ShipwayExit.success);
      expect(logger.output, contains('Nothing to clean up.'));
    });

    test('needs no config', () async {
      // The checkout may be the thing that failed.
      File(p.join(project.path, 'shipway.yaml')).deleteSync();
      expect(await cleanup(), ShipwayExit.success);
    });
  });
}
