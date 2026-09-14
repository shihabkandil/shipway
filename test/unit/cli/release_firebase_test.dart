import 'dart:convert';

import 'package:mason_logger/mason_logger.dart';
import 'package:shipway/src/cli/exit_codes.dart';
import 'package:shipway/src/cli/shipway_command_runner.dart';
import 'package:shipway/src/core/env/host_platform.dart';
import 'package:shipway/src/core/managed/lock_file.dart';
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

/// The field report's shape: two flavors with their own application ids, and
/// Firebase configured with no app id variable at all.
String _config({String firebase = 'groups: [qa]'}) =>
    '''
version: 1
project:
  name: acme_app
apps:
  main:
    path: .
    android:
      application_id: com.acme.app
    flavors:
      dev:
        suffix: .dev
        firebase:
          android: android/app/src/dev/google-services.json
      prod:
        suffix: ""
    targets:
      firebase:
        $firebase
''';

Map<String, Object> _client(String packageName, String appId) =>
    <String, Object>{
      'client_info': <String, Object>{
        'mobilesdk_app_id': appId,
        'android_client_info': <String, Object>{'package_name': packageName},
      },
    };

void main() {
  late FixtureProject project;
  late _CapturingLogger logger;
  late RecordingProcessRunner runner;

  const fastfilePath = 'android/fastlane/Fastfile';

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    project
      ..write('shipway.yaml', _config())
      ..write(fastfilePath, 'lane :play do\nend\nlane :firebase do\nend\n')
      // Production first, the way Firebase writes the file: taking the first
      // entry would upload dev's build to prod's app.
      ..writeJson('android/app/src/dev/google-services.json', <String, Object>{
        'project_info': <String, Object>{'project_id': 'acme-dev'},
        'client': <Object>[
          _client('com.acme.app', '1:111:android:prod'),
          _client('com.acme.app.dev', '1:111:android:dev'),
        ],
      })
      ..write('.env', 'FIREBASE_SERVICE_ACCOUNT_JSON_PATH=firebase.json\n')
      ..write('firebase.json', '{}');
    logger = _CapturingLogger();
    runner = RecordingProcessRunner();
  });

  Future<int> run(List<String> args) =>
      ShipwayCommandRunner(
        logger: logger,
        runner: runner,
        workingDirectory: project.path,
        host: HostPlatform.macos,
        // Hermetic: a developer's own FIREBASE_* variables must not decide
        // whether these pass.
        environment: const <String, String>{},
      ).run(<String>[
        '--config=${project.path}/shipway.yaml',
        '--env=persistent',
        'release',
        'android',
        '--target',
        'firebase',
        ...args,
      ]);

  group('the lane has to exist', () {
    test('a project\'s own Fastfile without one stops everything', () async {
      project.write(fastfilePath, 'lane :play do\nend\n');

      final code = await run(<String>['--flavor', 'dev']);

      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('no `firebase` lane'));
      expect(logger.output, contains('shipway adopt $fastfilePath'));
      expect(runner.invocations, isEmpty);
    });

    test('one shipway generated only needs regenerating', () async {
      project.write(fastfilePath, 'lane :play do\nend\n');
      await (LockFile.empty()..record(
            const LockEntry(
              path: fastfilePath,
              ownership: Ownership.generated,
              mode: WriteMode.full,
            ),
          ))
          .save(project.path);

      final code = await run(<String>['--flavor', 'dev']);

      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('shipway generate fastlane'));
    });

    test('no Fastfile at all', () async {
      project.file(fastfilePath).deleteSync();

      final code = await run(<String>['--flavor', 'dev']);

      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('There is no $fastfilePath'));
    });
  });

  group('which app it uploads to', () {
    test('comes from the flavor\'s google-services.json, by package', () async {
      final code = await run(<String>['--flavor', 'dev', '--dry-run']);

      expect(code, ShipwayExit.success, reason: logger.output);
      expect(logger.output, contains('1:111:android:dev'));
      expect(logger.output, isNot(contains('1:111:android:prod')));
      expect(
        logger.output,
        contains('from android/app/src/dev/google-services.json'),
      );
    });

    test('and the lane is handed the id that was printed', () async {
      runner.stub('bundle exec fastlane');

      final code = await run(<String>['--flavor', 'dev', '--no-notify']);

      expect(code, ShipwayExit.success, reason: logger.output);
      expect(
        runner.invocation('fastlane').arguments,
        contains('app_id:1:111:android:dev'),
      );
    });

    test('a flavor with no google-services.json is refused', () async {
      final code = await run(<String>['--flavor', 'prod']);

      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('flavors.prod.firebase.android'));
      expect(logger.output, contains('android_app_id_ref'));
      expect(runner.invocations, isEmpty);
    });

    test('a file that does not list the flavor says what it does', () async {
      project.write(
        'android/app/src/dev/google-services.json',
        jsonEncode(<String, Object>{
          'client': <Object>[_client('com.acme.app', '1:111:android:prod')],
        }),
      );

      final code = await run(<String>['--flavor', 'dev']);

      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('no Android app for com.acme.app.dev'));
      expect(logger.output, contains('it lists com.acme.app'));
    });

    test('a configured app id variable replaces the file entirely', () async {
      project.write(
        'shipway.yaml',
        _config(firebase: 'android_app_id_ref: FB_ANDROID_APP_ID'),
      );

      // Required once named: an unset variable must not quietly fall back to
      // a different app.
      expect(
        await run(<String>['--flavor', 'prod', '--dry-run']),
        ShipwayExit.environmentError,
      );
      expect(logger.output, contains('FB_ANDROID_APP_ID'));

      logger.lines.clear();
      project.write(
        '.env',
        'FIREBASE_SERVICE_ACCOUNT_JSON_PATH=firebase.json\n'
            'FB_ANDROID_APP_ID=1:222:android:override\n',
      );
      // prod has no google-services.json, and does not need one now.
      expect(
        await run(<String>['--flavor', 'prod', '--dry-run']),
        ShipwayExit.success,
        reason: logger.output,
      );
      expect(logger.output, contains(r'from $FB_ANDROID_APP_ID'));
    });
  });

  test('no groups is said out loud rather than invented', () async {
    project.write('shipway.yaml', _config(firebase: 'changelog_from: git'));

    await run(<String>['--flavor', 'dev', '--dry-run']);

    expect(logger.output, contains('none — uploaded, not distributed'));
  });
}
