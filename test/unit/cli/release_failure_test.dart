import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:shipway/src/cli/exit_codes.dart';
import 'package:shipway/src/cli/shipway_command_runner.dart';
import 'package:shipway/src/core/env/host_platform.dart';
import 'package:shipway/src/core/toolchain/bundled_fastlane.dart';
import 'package:test/test.dart';

import '../../support/fastlane_toolchain.dart';
import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

/// Keeps how each line was logged, because the point of several tests here is
/// which lines are errors and which are not.
class _LevelLogger extends Logger {
  final List<({String level, String text})> entries =
      <({String level, String text})>[];

  void _add(String level, String? message) =>
      entries.add((level: level, text: message ?? ''));

  @override
  void info(String? message, {LogStyle? style}) => _add('info', message);

  @override
  void err(String? message, {LogStyle? style}) => _add('err', message);

  @override
  void warn(String? message, {String tag = 'WARN', LogStyle? style}) =>
      _add('warn', message);

  @override
  void detail(String? message, {LogStyle? style}) => _add('detail', message);

  @override
  void write(String? message) => _add('info', message);

  String get output => entries.map((e) => e.text).join('\n');

  List<String> at(String level) => <String>[
    for (final entry in entries)
      if (entry.level == level) entry.text,
  ];

  /// The index of the first entry containing [needle]; fails if absent.
  int indexOf(String needle) {
    final index = entries.indexWhere((e) => e.text.contains(needle));
    if (index < 0) fail('Nothing logged contains "$needle":\n$output');
    return index;
  }
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

/// The log of the field report; see `failure_attribution_test.dart`.
List<String> _fieldReport() =>
    File('test/fixtures/lane_logs/ios_stale_pod_specs.log').readAsLinesSync();

const String _podInstall = 'pod install --repo-update';

/// Each index after the one before it: the order things were said in.
void expectInOrder(List<int> indices) =>
    expect(indices, orderedEquals(<int>[...indices]..sort()));

void main() {
  late FixtureProject project;
  late _LevelLogger logger;
  late RecordingProcessRunner runner;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    project
      ..write('shipway.yaml', _config)
      ..write('ios/fastlane/Fastfile', _fastfile('ios', 'beta', 'release'))
      ..write(
        'android/fastlane/Fastfile',
        _fastfile('android', 'play', 'firebase'),
      )
      ..write('play.json', '{}')
      ..write('.env', '''
MATCH_PASSWORD=x
ASC_KEY_ID=x
ASC_ISSUER_ID=x
ASC_KEY_P8_BASE64=x
MATCH_GIT_BASIC_AUTHORIZATION=x
PLAY_SERVICE_ACCOUNT_JSON_PATH=play.json
''');
    logger = _LevelLogger();
    runner = RecordingProcessRunner();
    stubFastlaneToolchain(runner);
  });

  Future<int> release(String platform, String target) =>
      ShipwayCommandRunner(
        logger: logger,
        runner: runner,
        workingDirectory: project.path,
        host: HostPlatform.macos,
      ).run(<String>[
        '--config=${project.path}/shipway.yaml',
        '--env=persistent',
        'release',
        platform,
        '--flavor',
        'dev',
        '--target',
        target,
        '--no-analyze',
      ]);

  List<RecordedInvocation> lanes() => <RecordedInvocation>[
    for (final invocation in runner.invocations)
      if (invocation.commandLine.contains(BundledFastlane.loader)) invocation,
  ];

  group('a failed lane', () {
    test('is summarised as step, error line, then what to do', () async {
      runner.stub(
        BundledFastlane.loader,
        exitCode: 1,
        lines: <String>[
          '[10:00:00]: --- Step: upload_to_play_store ---',
          '[10:00:01]: Google Api Error: Version code has already been used.',
          '',
          '[!] Google Api Error: Invalid request',
        ],
      );

      expect(await release('android', 'play'), ShipwayExit.environmentError);

      final failed = logger.indexOf('The play lane failed for dev (exit 1).');
      final step = logger.indexOf('Failed step: upload_to_play_store');
      final error = logger.entries.lastIndexWhere(
        (e) => e.text.contains('[!] Google Api Error: Invalid request'),
      );
      final summary = logger.indexOf('strictly increasing');
      final fix = logger.indexOf('Set versioning.strategy');
      expectInOrder(<int>[failed, step, error, summary, fix]);
    });

    test('nothing recognised is said plainly, with the output', () async {
      runner.stub(
        BundledFastlane.loader,
        exitCode: 1,
        lines: <String>[
          '[10:00:00]: --- Step: gradle ---',
          for (var i = 1; i <= 30; i++) '[10:00:01]: gradle line $i',
          '',
          '[!] Something nobody has seen before',
        ],
      );

      expect(await release('android', 'play'), ShipwayExit.environmentError);

      expect(logger.output, contains('does not recognise this failure'));
      // Only the lane failing is an error: nothing was guessed at.
      expect(logger.at('err'), <String>[
        'The play lane failed for dev (exit 1).',
      ]);
      // The last twenty lines of the step, shown a second time on purpose.
      bool replayed(int i) => logger.entries.any(
        (e) => e.text.startsWith('    ') && e.text.endsWith('gradle line $i'),
      );
      expect(replayed(30), isTrue);
      expect(replayed(11), isTrue);
      expect(replayed(10), isFalse);
    });

    test(
      'a warning is reported after the cause, and not as an error',
      () async {
        runner.stub(
          BundledFastlane.loader,
          exitCode: 1,
          lines: <String>[
            'WARNING: Support for your Ruby version (3.1.1) is going away.',
            '[10:00:00]: --- Step: upload_to_play_store ---',
            '[10:00:01]: Google Api Error: Version code has already been used.',
            '',
            '[!] Google Api Error: Invalid request',
          ],
        );

        await release('android', 'play');

        final cause = logger.indexOf('strictly increasing');
        final heading = logger.indexOf('Warnings — not why this failed:');
        final warning = logger.indexOf('near end of support');
        expectInOrder(<int>[cause, heading, warning]);
        expect(logger.entries[warning].level, 'warn');
        expect(logger.at('err').join('\n'), isNot(contains('Ruby')));
      },
    );

    test('runs with the update check, and its changelog, turned off', () async {
      runner.stub(BundledFastlane.loader);

      await release('android', 'play');

      final environment = lanes().single.environment!;
      expect(environment['FASTLANE_SKIP_UPDATE_CHECK'], '1');
      // Alongside the credentials, not instead of them.
      expect(
        environment['PLAY_SERVICE_ACCOUNT_JSON_PATH'],
        endsWith('play.json'),
      );
    });
  });

  group('the field report', testOn: 'mac-os', () {
    test('blames the spec repo, never the API key', () async {
      runner
        ..stub(BundledFastlane.loader, exitCode: 1, lines: _fieldReport())
        ..stub(_podInstall, exitCode: 1, lines: <String>['network is down']);

      expect(await release('ios', 'testflight'), ShipwayExit.environmentError);

      expect(logger.output, contains('Failed step: cd /Users/runner/work/app'));
      expect(logger.output, contains('specs repository is older than'));
      expect(logger.output, isNot(contains('refused the API key')));
      expect(logger.at('err').join('\n'), isNot(contains('Ruby')));
      expect(logger.at('warn').join('\n'), contains('near end of support'));
    });

    test('refreshes the spec repo and runs the lane once more', () async {
      runner
        ..stub(BundledFastlane.loader, exitCode: 1, lines: _fieldReport())
        ..stub(_podInstall, lines: <String>['Pod installation complete!'])
        // What the refresh fixed: the lane passes from then on.
        ..onRun = (invocation) {
          if (invocation.commandLine.contains(_podInstall)) {
            runner.stub(BundledFastlane.loader, lines: <String>['Uploaded']);
          }
        };

      expect(await release('ios', 'testflight'), ShipwayExit.success);

      expect(lanes(), hasLength(2));
      final pod = runner.invocation(_podInstall);
      expect(pod.executable, 'pod');
      expect(pod.arguments, <String>['install', '--repo-update']);
      expect(pod.workingDirectory, endsWith('ios'));
      // Said out loud: a release that quietly ran twice is a surprise.
      expect(
        logger.at('warn').join('\n'),
        contains('Running `pod install --repo-update` in ios/'),
      );
      expect(logger.output, contains('Released dev to testflight.'));
      expect(logger.at('err'), isEmpty);
    });

    test('goes through the bundle when the Gemfile has CocoaPods', () async {
      project.write('ios/Gemfile', 'gem "fastlane"\ngem "cocoapods"\n');
      runner.stub(BundledFastlane.loader, exitCode: 1, lines: _fieldReport());

      await release('ios', 'testflight');

      final pod = runner.invocation(_podInstall);
      expect(pod.executable, 'bundle');
      expect(pod.arguments, <String>[
        'exec',
        'pod',
        'install',
        '--repo-update',
      ]);
    });

    test('retries once: a second failure is reported, not retried', () async {
      runner.stub(BundledFastlane.loader, exitCode: 1, lines: _fieldReport());

      expect(await release('ios', 'testflight'), ShipwayExit.environmentError);

      expect(lanes(), hasLength(2));
      expect(runner.invocation(_podInstall), isNotNull);
      expect(logger.output, contains('The beta lane failed for dev (exit 1).'));
      expect(logger.output, contains('specs repository is older than'));
    });

    test('a refresh that fails leaves the lane alone', () async {
      runner
        ..stub(BundledFastlane.loader, exitCode: 1, lines: _fieldReport())
        ..stub(_podInstall, exitCode: 1, lines: <String>['network is down']);

      await release('ios', 'testflight');

      expect(lanes(), hasLength(1));
      expect(logger.at('warn').join('\n'), contains('not run again'));
    });
  });

  test('no other failure is retried', () async {
    runner.stub(
      BundledFastlane.loader,
      exitCode: 1,
      lines: <String>['[!] Something went wrong'],
    );

    await release('android', 'play');

    expect(lanes(), hasLength(1));
    expect(runner.ran(_podInstall), isFalse);
  });
}
