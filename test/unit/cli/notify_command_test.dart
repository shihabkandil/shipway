import 'package:mason_logger/mason_logger.dart';
import 'package:shipway/src/cli/exit_codes.dart';
import 'package:shipway/src/cli/notifications.dart';
import 'package:shipway/src/cli/shipway_command_runner.dart';
import 'package:shipway/src/core/env/host_platform.dart';
import 'package:shipway/src/core/io/http_poster.dart';
import 'package:test/test.dart';

import '../../support/fastlane_toolchain.dart';
import '../../support/fixture_project.dart';
import '../../support/recording_http_poster.dart';
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

  String get output => lines.join('\n');
}

const String _webhook = 'https://hooks.slack.com/services/T0/B0/xyz';

String _config({String notify = '', String pipelines = ''}) =>
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
      prod:
        suffix: ""
    targets:
      play:
        track: internal
notify:
  slack_webhook_ref: SLACK_WEBHOOK
$notify
$pipelines
''';

void main() {
  late FixtureProject project;
  late _CapturingLogger logger;
  late RecordingProcessRunner runner;
  late RecordingHttpPoster http;
  late Map<String, String> environment;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    project
      ..write('shipway.yaml', _config())
      ..write('pubspec.yaml', 'name: acme_app\nversion: 2.4.0+31\n')
      ..write('.env', 'PLAY_SERVICE_ACCOUNT_JSON_PATH=play.json\n')
      ..write('play.json', '{}')
      ..write('android/fastlane/Fastfile', 'lane :play do\nend\n');
    logger = _CapturingLogger();
    runner = RecordingProcessRunner();
    stubFastlaneToolchain(runner);
    http = RecordingHttpPoster();
    environment = <String, String>{'SLACK_WEBHOOK': _webhook};
  });

  Future<int> run(List<String> args) => ShipwayCommandRunner(
    logger: logger,
    runner: runner,
    http: http,
    environment: environment,
    workingDirectory: project.path,
    host: HostPlatform.macos,
  ).run(<String>['--env=persistent', ...args]);

  group('notify test', () {
    test('sends one message, marked as a test', () async {
      final code = await run(<String>['notify', 'test']);

      expect(code, ShipwayExit.success, reason: logger.output);
      expect(http.posts.single.url.toString(), _webhook);
      expect(http.posts.single.json['text'], contains('(test)'));
      expect(logger.output, contains('through the webhook'));
    });

    test('--dry-run shows the message and sends nothing', () async {
      final code = await run(<String>[
        'notify',
        'test',
        '--event',
        'success',
        '--dry-run',
      ]);

      expect(code, ShipwayExit.success);
      expect(http.posts, isEmpty);
      expect(logger.output, contains('"text": "acme_app: *beta (test)*'));
      expect(logger.output, contains('#2EB67D'));
    });

    test('is built from the config\'s own pipeline', () async {
      project.write(
        'shipway.yaml',
        _config(
          pipelines: '''
pipelines:
  nightly:
    - test
    - release: { flavor: prod, target: play }
''',
        ),
      );
      await run(<String>['notify', 'test', '--dry-run']);

      expect(logger.output, contains('nightly (test)'));
      expect(logger.output, contains('release prod → play'));
    });

    test('a secret that is not set is an environment problem', () async {
      environment.clear();
      final code = await run(<String>['notify', 'test']);

      expect(code, ShipwayExit.environmentError);
      expect(http.posts, isEmpty);
      expect(logger.output, contains('SLACK_WEBHOOK is not set here'));
    });

    test('a webhook variable that is not a URL says so', () async {
      environment['SLACK_WEBHOOK'] = '#releases';
      final code = await run(<String>['notify', 'test']);

      expect(code, ShipwayExit.environmentError);
      expect(logger.output, contains('not an https URL'));
    });

    test('the bot token wins when both are set', () async {
      project.write(
        'shipway.yaml',
        _config(
          notify:
              '  slack_bot_token_ref: SLACK_BOT_TOKEN\n'
              '  slack_channel: C0RELEASES',
        ),
      );
      environment['SLACK_BOT_TOKEN'] = 'xoxb-1';
      final code = await run(<String>['notify', 'test']);

      expect(code, ShipwayExit.success, reason: logger.output);
      expect(http.posts.single.url.host, 'slack.com');
      expect(http.posts.single.json['channel'], 'C0RELEASES');
    });

    test('and the webhook is used where the bot token is missing', () async {
      project.write(
        'shipway.yaml',
        _config(
          notify:
              '  slack_bot_token_ref: SLACK_BOT_TOKEN\n'
              '  slack_channel: C0RELEASES',
        ),
      );
      final code = await run(<String>['notify', 'test']);

      expect(code, ShipwayExit.success, reason: logger.output);
      expect(http.posts.single.url.toString(), _webhook);
    });
  });

  group('release', () {
    setUp(() {
      project.write('shipway.yaml', _config(notify: '  on: always'));
    });

    Future<int> release([List<String> extra = const <String>[]]) =>
        run(<String>[
          'release',
          'android',
          '--flavor',
          'prod',
          '--target',
          'play',
          ...extra,
        ]);

    test('reports the lane it ran, with the facts filled in', () async {
      runner.stub('rev-parse --abbrev-ref', stdout: 'main\n');
      runner.stub('rev-parse --short', stdout: '1a2b3c4\n');

      expect(await release(), ShipwayExit.success, reason: logger.output);

      final body = http.posts.single.json;
      expect(
        body['text'],
        matches(
          RegExp(r'^acme_app: \*release prod → play\* finished in \d+s$'),
        ),
      );
      final attachment = (body['attachments'] as List).single as Map;
      expect(attachment['text'], contains('✓ fastlane android play'));
      expect(attachment['footer'], startsWith('acme_app · main @ 1a2b3c4'));
    });

    test('a failed lane is reported as a failure', () async {
      runner.stub('Gem.bin_path', exitCode: 1, stderr: 'boom');

      expect(await release(), isNot(ShipwayExit.success));
      expect(
        http.posts.single.json['text'],
        contains('failed at fastlane android play'),
      );
    });

    test('--no-notify sends nothing', () async {
      await release(<String>['--no-notify']);
      expect(http.posts, isEmpty);
    });

    test('a dry run sends nothing', () async {
      await release(<String>['--dry-run']);
      expect(http.posts, isEmpty);
    });

    test('a Slack outage does not fail the release', () async {
      http.replies.add(const HttpReply(statusCode: 500, body: 'oops'));
      expect(await release(), ShipwayExit.success);
      expect(logger.output, contains('Slack answered HTTP 500'));
    });
  });

  group('run', () {
    test('a pipeline is one report, not one per release step', () async {
      project.write(
        'shipway.yaml',
        _config(
          notify: '  on: always',
          pipelines: '''
pipelines:
  beta:
    - analyze
    - release: { flavor: prod, target: play }
''',
        ),
      );

      final code = await run(<String>['run', 'beta']);

      expect(code, ShipwayExit.success, reason: logger.output);
      expect(http.posts, hasLength(1));
      expect(http.posts.single.json['text'], contains('*beta* finished'));
      final steps =
          ((http.posts.single.json['attachments'] as List).single
              as Map)['text'];
      expect(steps, contains('✓ analyze'));
      expect(steps, contains('✓ release prod → play'));
    });
  });

  group('facts', () {
    test('a CI run links to itself', () {
      expect(
        ciRunUrl(<String, String>{
          'GITHUB_SERVER_URL': 'https://github.com',
          'GITHUB_REPOSITORY': 'acme/app',
          'GITHUB_RUN_ID': '42',
        }),
        'https://github.com/acme/app/actions/runs/42',
      );
      expect(ciRunUrl(const <String, String>{}), isNull);
    });
  });
}
