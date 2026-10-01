import 'dart:convert';

import 'package:mason_logger/mason_logger.dart';
import 'package:shipway/src/cli/exit_codes.dart';
import 'package:shipway/src/cli/shipway_command_runner.dart';
import 'package:shipway/src/core/env/host_platform.dart';
import 'package:shipway/src/core/toolchain/bundled_fastlane.dart';
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

String _config(String matchUrl) =>
    '''
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
        match_git_url: $matchUrl
        api_key:
          key_id_ref: ASC_KEY_ID
          issuer_id_ref: ASC_ISSUER_ID
          p8_ref: ASC_KEY_P8_BASE64
    flavors:
      dev:
        suffix: .dev
    targets:
      testflight:
        groups: [internal]
      play:
        track: internal
''';

String _fastfile(String platform, String first, String second) =>
    'platform :$platform do\n'
    '  lane :$first do\n  end\n'
    '  lane :$second do\n  end\n'
    'end\n';

const String _https = 'https://github.com/acme/certs.git';
const String _ssh = 'git@github.com:acme/certs.git';

/// Everything an Apple release needs except the match repository credential.
const String _apple = '''
MATCH_PASSWORD=hunter2hunter2
ASC_KEY_ID=ABCDEFGHIJ
ASC_ISSUER_ID=00000000-0000
ASC_KEY_P8_BASE64=bm90LWEta2V5
PLAY_SERVICE_ACCOUNT_JSON_PATH=play.json
''';

const String _basic = 'MATCH_GIT_BASIC_AUTHORIZATION=Y2k6Z2hwX25vdFJlYWw=\n';
const String _key = 'MATCH_GIT_PRIVATE_KEY=/runner/keys/match_deploy\n';

void main() {
  late FixtureProject project;
  late _CapturingLogger logger;
  late RecordingProcessRunner runner;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    project
      ..write('shipway.yaml', _config(_https))
      ..write('play.json', '{}')
      ..write('ios/fastlane/Fastfile', _fastfile('ios', 'beta', 'release'))
      ..write(
        'android/fastlane/Fastfile',
        _fastfile('android', 'play', 'firebase'),
      );
    logger = _CapturingLogger();
    runner = RecordingProcessRunner();
    stubFastlaneToolchain(runner);
  });

  Future<int> run(
    List<String> args, {
    String env = 'persistent',
    Map<String, String> processEnvironment = const <String, String>{},
  }) =>
      ShipwayCommandRunner(
        logger: logger,
        runner: runner,
        workingDirectory: project.path,
        host: HostPlatform.macos,
        environment: processEnvironment,
      ).run(<String>[
        '--config=${project.path}/shipway.yaml',
        '--env=$env',
        ...args,
      ]);

  const ios = <String>[
    'release',
    'ios',
    '--flavor',
    'dev',
    '--target',
    'testflight',
    '--dry-run',
  ];

  group('the match repository', () {
    test(
      'an HTTPS URL with only the SSH key stops, saying exactly that',
      () async {
        project.write('.env', '$_apple$_key');

        final code = await run(ios);

        expect(code, ShipwayExit.environmentError);
        expect(logger.output, contains('HTTPS'));
        expect(logger.output, contains('only MATCH_GIT_PRIVATE_KEY is set'));
        expect(logger.output, contains('--no-match-check'));
        // Decided from the URL; nobody was asked, and nothing slow started.
        expect(runner.invocations, isEmpty);
      },
    );

    test(
      'an SSH URL with only basic authorization stops the same way',
      () async {
        project
          ..write('shipway.yaml', _config(_ssh))
          ..write('.env', '$_apple$_basic');

        final code = await run(ios);

        expect(code, ShipwayExit.environmentError);
        expect(
          logger.output,
          contains('only MATCH_GIT_BASIC_AUTHORIZATION is set'),
        );
        expect(runner.invocations, isEmpty);
      },
    );

    test(
      'MATCH_GIT_URL is the URL judged, since it is the one cloned',
      () async {
        // The config says HTTPS and has its credential; the override is SSH.
        project.write('.env', '$_apple${_basic}MATCH_GIT_URL=$_ssh\n');

        final code = await run(ios);

        expect(code, ShipwayExit.environmentError);
        expect(logger.output, contains(_ssh));
        expect(
          logger.output,
          contains('only MATCH_GIT_BASIC_AUTHORIZATION is set'),
        );
      },
    );

    test(
      'is asked with the credential, before the entrypoint is analysed',
      () async {
        project
          ..write('.env', '$_apple$_basic')
          ..write('.dart_tool/package_config.json', '{}');

        final code = await run(ios);

        expect(code, ShipwayExit.success);
        final lines = runner.commandLines;
        final asked = lines.indexWhere((line) => line.contains('ls-remote'));
        final analysed = lines.indexWhere((line) => line.contains('analyze'));
        expect(asked, isNot(-1));
        expect(analysed, greaterThan(asked));
        expect(runner.invocation('ls-remote').arguments, contains(_https));
      },
    );

    test('a refusal stops the release before anything is built', () async {
      project.write('.env', '$_apple$_basic');
      runner.stub(
        'ls-remote',
        exitCode: 128,
        stderr: "fatal: Authentication failed for '$_https/'",
      );

      final code = await run(ios);

      expect(code, ShipwayExit.environmentError);
      expect(logger.output, contains('refused access'));
      expect(logger.output, contains('MATCH_GIT_BASIC_AUTHORIZATION'));
      // The credential itself is never part of what is said.
      expect(logger.output, isNot(contains('Y2k6Z2hwX25vdFJlYWw=')));
      expect(runner.ran('analyze'), isFalse);
      expect(runner.ran('RUBY_VERSION'), isFalse);
    });

    test('a network failure warns and carries on', () async {
      project.write('.env', '$_apple$_basic');
      runner.stub(
        'ls-remote',
        exitCode: 128,
        stderr:
            "fatal: unable to access '$_https/': Could not resolve host: "
            'github.com',
      );

      final code = await run(ios);

      expect(code, ShipwayExit.success);
      expect(logger.output, contains('Could not reach the match repository'));
      expect(logger.output, contains('Nothing was uploaded'));
    });

    test('--no-match-check asks nothing', () async {
      project.write('.env', '$_apple$_key');

      await run(<String>[...ios, '--no-match-check']);

      expect(runner.ran('ls-remote'), isFalse);
      // Left to the credential report, which still wants the HTTPS one.
      expect(logger.output, contains('MATCH_GIT_BASIC_AUTHORIZATION'));
      expect(logger.output, isNot(contains('only MATCH_GIT_PRIVATE_KEY')));
    });

    test('is not asked while another credential is still missing', () async {
      project.write('.env', _basic);

      final code = await run(ios);

      expect(code, ShipwayExit.environmentError);
      expect(logger.output, contains('MATCH_PASSWORD'));
      expect(runner.ran('ls-remote'), isFalse);
    });

    test('an Android release never asks', () async {
      project.write('.env', '$_apple$_key');

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
      expect(runner.ran('ls-remote'), isFalse);
    });
  });

  group('recording the toolchain', () {
    const android = <String>[
      'release',
      'android',
      '--flavor',
      'dev',
      '--target',
      'play',
    ];
    const lockPath = '.shipway/lock.json';

    setUp(() {
      project.write('.env', _apple);
      runner
        ..stub(BundledFastlane.loader)
        ..stub(
          'flutter --version --machine',
          stdout: jsonEncode(<String, String>{'frameworkVersion': '3.47.2'}),
        )
        ..stub('xcodebuild -version', stdout: 'Xcode 26.6\nBuild version 1');
    });

    Map<String, dynamic> lock() =>
        jsonDecode(project.read(lockPath)) as Map<String, dynamic>;

    test('a successful release from a workstation records Flutter', () async {
      final code = await run(android, env: 'workstation');

      expect(code, ShipwayExit.success);
      expect(lock()['toolchain'], <String, dynamic>{'flutter': '3.47.2'});
      // Xcode took no part in an Android build.
      expect(runner.ran('xcodebuild'), isFalse);
    });

    test(
      'a second release on the same toolchain leaves the file alone',
      () async {
        await run(android, env: 'workstation');
        final before = project.file(lockPath).lastModifiedSync();
        final contents = project.read(lockPath);
        logger.lines.clear();

        await run(android, env: 'workstation');

        expect(project.read(lockPath), contents);
        expect(project.file(lockPath).lastModifiedSync(), before);
        expect(logger.output, isNot(contains('Recorded this toolchain')));
      },
    );

    test('a dry run records nothing', () async {
      final code = await run(<String>[
        ...android,
        '--dry-run',
      ], env: 'workstation');
      expect(code, ShipwayExit.success);
      expect(project.exists(lockPath), isFalse);
    });

    test('a failed lane records nothing', () async {
      runner.stub(BundledFastlane.loader, exitCode: 1);
      final code = await run(android, env: 'workstation');
      expect(code, isNot(ShipwayExit.success));
      expect(project.exists(lockPath), isFalse);
    });

    test('a runner does not rewrite a committed file', () async {
      final code = await run(android);
      expect(code, ShipwayExit.success);
      expect(project.exists(lockPath), isFalse);
      expect(runner.ran('flutter --version'), isFalse);
    });
  });
}
