import 'package:mason_logger/mason_logger.dart';
import 'package:shipway/src/cli/exit_codes.dart';
import 'package:shipway/src/cli/shipway_command_runner.dart';
import 'package:shipway/src/core/env/host_platform.dart';
import 'package:test/test.dart';

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
    ios:
      bundle_id: com.acme.app
    signing:
      ios:
        team_id: ABCDE12345
        match_git_url: https://github.com/acme/certs.git
        api_key:
          key_id_ref: ASC_KEY_ID
          issuer_id_ref: ASC_ISSUER_ID
          p8_ref: ASC_KEY_P8_BASE64
    flavors:
      dev:
        suffix: .dev
      prod:
        suffix: ""
    targets:
      testflight:
        groups: [internal]
      play:
        track: internal
''';

/// A Fastfile declaring [lanes], which is all the pre-flight reads.
String _fastfile(String platform, String first, String second) =>
    'platform :$platform do\n'
    '  lane :$first do\n  end\n'
    '  lane :$second do\n  end\n'
    'end\n';

void main() {
  late FixtureProject project;
  late _CapturingLogger logger;
  late RecordingProcessRunner runner;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    // Lanes for every target, so each test reaches what it is about. What
    // happens without one is a group of its own.
    project
      ..write('shipway.yaml', _config)
      ..write('ios/fastlane/Fastfile', _fastfile('ios', 'beta', 'release'))
      ..write(
        'android/fastlane/Fastfile',
        _fastfile('android', 'play', 'firebase'),
      );
    logger = _CapturingLogger();
    runner = RecordingProcessRunner();
  });

  Future<int> run(List<String> args, {HostPlatform? host}) =>
      ShipwayCommandRunner(
        logger: logger,
        runner: runner,
        workingDirectory: project.path,
        host: host ?? HostPlatform.macos,
      ).run(<String>[
        '--config=${project.path}/shipway.yaml',
        '--env=persistent',
        ...args,
      ]);

  /// Satisfies the credentials a target needs, so a test can reach the plan.
  void credentials() => project.write('.env', '''
MATCH_PASSWORD=x
ASC_KEY_ID=x
ASC_ISSUER_ID=x
ASC_KEY_P8_BASE64=x
MATCH_GIT_BASIC_AUTHORIZATION=x
PLAY_SERVICE_ACCOUNT_JSON_PATH=play.json
''');

  group('saying what you meant', () {
    test('no platform names the two that exist', () async {
      expect(await run(<String>['release']), ShipwayExit.userError);
      expect(logger.output, contains('ios'));
      expect(logger.output, contains('android'));
    });

    test('no target lists the ones for that platform', () async {
      final code = await run(<String>['release', 'android']);
      expect(code, ShipwayExit.userError);
      // Only the Android ones: offering testflight here is noise.
      expect(logger.output, contains('play'));
      expect(logger.output, isNot(contains('testflight')));
    });

    test('a target from the other platform says which to run', () async {
      final code = await run(<String>[
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'testflight',
      ]);
      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('shipway release ios'));
    });

    test('an unknown flavor lists the real ones', () async {
      final code = await run(<String>[
        'release',
        'android',
        '--flavor',
        'nope',
        '--target',
        'play',
      ]);
      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('dev, prod'));
    });
  });

  group('what it refuses before doing anything slow', () {
    test('a target the config never configured', () async {
      // Naming the key is the difference between a fix and a search.
      final code = await run(<String>[
        'release',
        'ios',
        '--flavor',
        'dev',
        '--target',
        'appstore',
      ]);
      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('targets.appstore'));
    });

    test('a rollout outside the range supply accepts', () async {
      final code = await run(<String>[
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'play',
        '--rollout',
        '2',
      ]);
      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('fraction'));
    });

    test('flags that belong to another target', () async {
      for (final flag in const <List<String>>[
        <String>['--rollout', '0.1'],
        <String>['--track', 'beta'],
      ]) {
        logger.lines.clear();
        final code = await run(<String>[
          'release',
          'ios',
          '--flavor',
          'dev',
          '--target',
          'testflight',
          ...flag,
        ]);
        expect(code, ShipwayExit.userError, reason: flag.join(' '));
        expect(logger.output, contains('play target only'));
      }
    });

    test('nothing is run when validation fails', () async {
      await run(<String>[
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'play',
        '--rollout',
        '2',
      ]);
      expect(runner.invocations, isEmpty);
    });
  });

  group('the credential pre-flight', () {
    test('asks only for what this destination needs', () async {
      // Demanding an App Store Connect key before a Play upload is noise, and
      // noise in a pre-flight is how people learn to ignore it.
      final code = await run(<String>[
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'play',
      ]);

      expect(code, ShipwayExit.environmentError);
      expect(logger.output, contains('PLAY_SERVICE_ACCOUNT_JSON_PATH'));
      expect(logger.output, isNot(contains('ASC_KEY_ID')));
      expect(logger.output, isNot(contains('MATCH_PASSWORD')));
    });

    test('and the Apple destinations ask for the Apple ones', () async {
      final code = await run(<String>[
        'release',
        'ios',
        '--flavor',
        'dev',
        '--target',
        'testflight',
      ]);

      expect(code, ShipwayExit.environmentError);
      expect(logger.output, contains('MATCH_PASSWORD'));
      expect(logger.output, isNot(contains('PLAY_SERVICE_ACCOUNT')));
    });

    test('nothing is run when a credential is missing', () async {
      await run(<String>[
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'play',
      ]);
      expect(runner.invocations, isEmpty);
    });
  });

  group('the plan', () {
    setUp(() {
      credentials();
      project.write('play.json', '{}');
    });

    test('shows where the build is going', () async {
      final code = await run(<String>[
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'play',
        '--dry-run',
      ]);

      expect(code, ShipwayExit.success);
      expect(logger.output, contains('com.acme.app.dev'));
      expect(logger.output, contains('internal'));
    });

    test('shows the status supply will derive from a rollout', () async {
      // This used to be a validation error. Showing the derived value is what
      // replaced refusing it.
      await run(<String>[
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'play',
        '--rollout',
        '0.1',
        '--dry-run',
      ]);
      expect(logger.output, contains('inProgress'));

      logger.lines.clear();
      await run(<String>[
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'play',
        '--rollout',
        '1',
        '--dry-run',
      ]);
      expect(logger.output, contains('completed'));
    });

    test('a dry run uploads nothing', () async {
      await run(<String>[
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'play',
        '--dry-run',
      ]);
      expect(runner.invocations, isEmpty);
      expect(logger.output, contains('Nothing was uploaded'));
    });
  });

  group('running the lane', () {
    setUp(() {
      credentials();
      project.write('play.json', '{}');
      runner.stub('bundle exec fastlane');
    });

    test('runs the generated lane through bundler', () async {
      final code = await run(<String>[
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'play',
      ]);

      expect(code, ShipwayExit.success);
      final invocation = runner.invocation('fastlane');
      // Through bundler, so the pinned fastlane is the one that runs.
      expect(invocation.executable, 'bundle');
      expect(
        invocation.arguments,
        containsAllInOrder(<String>['exec', 'fastlane', 'android', 'play']),
      );
      expect(invocation.arguments, contains('flavor:dev'));
    });

    test('passes only the options that were given', () async {
      await run(<String>[
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'play',
        '--rollout',
        '0.25',
      ]);
      final arguments = runner.invocation('fastlane').arguments;
      expect(arguments, contains('rollout:0.25'));
      expect(arguments.where((a) => a.startsWith('track:')), isEmpty);
    });

    test('runs from the platform directory', () async {
      await run(<String>[
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'play',
      ]);
      expect(
        runner.invocation('fastlane').workingDirectory,
        endsWith('android'),
      );
    });

    test('a failure is explained, not just echoed', () async {
      runner.stub(
        'bundle exec fastlane',
        exitCode: 1,
        stdout: 'Google Api Error: Version code has already been used.',
      );

      final code = await run(<String>[
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'play',
      ]);

      expect(code, ShipwayExit.environmentError);
      // The store's own message names nothing to change; the diagnosis does.
      expect(logger.output, contains('strictly increasing'));
      expect(logger.output, contains('remote'));
    });

    test('a success is read too', () async {
      // An upload can succeed and still be rejected in processing.
      runner.stub(
        'bundle exec fastlane',
        stdout: 'WARNING: Support for your Ruby version (3.1.1) is going away.',
      );

      final code = await run(<String>[
        'release',
        'android',
        '--flavor',
        'dev',
        '--target',
        'play',
      ]);

      expect(code, ShipwayExit.success);
      expect(logger.output, contains('Ruby'));
    });
  });
}
