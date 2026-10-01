import 'dart:convert';

import 'package:mason_logger/mason_logger.dart';
import 'package:shipway/src/cli/exit_codes.dart';
import 'package:shipway/src/cli/shipway_command_runner.dart';
import 'package:shipway/src/core/env/host_platform.dart';
import 'package:shipway/src/core/io/http_poster.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_http_poster.dart';
import '../../support/recording_process_runner.dart';
import '../secrets/signing_keys.dart';

/// Captures what the CLI printed.
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

  /// What a person at the keyboard would answer. Null means nobody should
  /// have been asked, and asking fails the test.
  bool? answer;
  final List<String> questions = <String>[];

  @override
  bool confirm(String? message, {bool defaultValue = false}) {
    questions.add(message ?? '');
    final reply = answer;
    if (reply == null) throw StateError('Prompted unexpectedly: $message');
    return reply;
  }

  String get output => lines.join('\n');
}

/// Both platforms, so that scoping has something to leave out.
const String _bothPlatforms = '''
version: 1
project:
  name: demo_app
apps:
  main:
    path: .
    flavors:
      prod:
        suffix: ""
    signing:
      ios:
        match_git_url: https://github.com/acme/certs.git
        team_id: ABCDE12345
        api_key:
          key_id_ref: ASC_KEY_ID
          issuer_id_ref: ASC_ISSUER_ID
          p8_ref: ASC_KEY_P8_BASE64
      android:
        keystore_ref: ANDROID_KEYSTORE_BASE64
        key_properties:
          store_password_ref: ANDROID_STORE_PASSWORD
          key_password_ref: ANDROID_KEY_PASSWORD
    targets:
      testflight: {}
      firebase: {}
''';

const Map<String, String> _iosSecrets = <String, String>{
  'ASC_KEY_ID': 'KEY123',
  'ASC_ISSUER_ID': 'issuer-uuid',
  'ASC_KEY_P8_BASE64': 'cDgtY29udGVudHM=',
  'MATCH_PASSWORD': 'match-passphrase',
  'MATCH_GIT_BASIC_AUTHORIZATION': 'c29tZW9uZTpnaHBfdG9rZW4=',
};

const String _config = '''
version: 1
project:
  name: demo_app
apps:
  main:
    path: .
    flavors:
      prod:
        suffix: ""
    signing:
      ios:
        match_git_url: https://github.com/acme/certs.git
        team_id: ABCDE12345
        api_key:
          key_id_ref: ASC_KEY_ID
          issuer_id_ref: ASC_ISSUER_ID
          p8_ref: ASC_KEY_P8_BASE64
''';

/// Models an empty login keychain that fills up as values are added.
///
/// The recording runner answers everything with success by default, which
/// means `find-generic-password` reports every name as already stored — so a
/// test of storing would silently exercise the skip path instead.
void emptyKeychain(RecordingProcessRunner runner) {
  runner
    ..stub('find-generic-password', exitCode: 44)
    ..onRun = (invocation) {
      if (!invocation.commandLine.contains('add-generic-password')) return;
      final arguments = invocation.arguments;
      final name = arguments[arguments.indexOf('-a') + 1];
      runner.stub('-a $name');
    };
}

void main() {
  late FixtureProject project;
  late _CapturingLogger logger;
  late RecordingProcessRunner runner;
  late RecordingHttpPoster http;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    project.write('shipway.yaml', _config);
    logger = _CapturingLogger();
    runner = RecordingProcessRunner();
    http = RecordingHttpPoster();
  });

  Future<int> run(
    List<String> args, {
    HostPlatform? host,
    Map<String, String>? environment,
  }) => ShipwayCommandRunner(
    logger: logger,
    runner: runner,
    http: http,
    environment: environment,
    workingDirectory: project.path,
    host: host ?? HostPlatform.macos,
  ).run(<String>['--config=${project.path}/shipway.yaml', ...args]);

  group('set', () {
    test('takes the value from a file without it reaching a log', () async {
      project.write('key.txt', 'a-secret-value\n');

      final code = await run(<String>[
        'secrets',
        'set',
        'ASC_KEY_ID',
        '--from-file=key.txt',
      ]);

      expect(code, ShipwayExit.success);
      expect(logger.output, contains('Stored ASC_KEY_ID'));
      // The whole point: what was stored is never shown.
      expect(logger.output, isNot(contains('a-secret-value')));
      expect(
        runner.invocation('add-generic-password').stdin,
        'a-secret-value\na-secret-value\n',
        reason: 'the trailing newline is not part of the value',
      );
    });

    test('--base64 encodes the file, so the lane can decode it', () async {
      // Done here rather than told to the user because `base64` on Linux wraps
      // at 76 columns by default, and the wrapped form does not decode.
      project.write('key.txt', 'p8-contents');

      await run(<String>[
        'secrets',
        'set',
        'ASC_KEY_P8_BASE64',
        '--from-file=key.txt',
        '--base64',
      ]);

      expect(
        runner.invocation('add-generic-password').stdin,
        startsWith('cDgtY29udGVudHM='),
      );
    });

    test('says which credential when given none', () async {
      final code = await run(<String>['secrets', 'set']);

      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('ASC_KEY_ID'));
      expect(runner.invocations, isEmpty);
    });

    test('will not prompt where a prompt would hang', () async {
      // On a runner there is nobody to answer, and a hang burns the job
      // timeout while reporting nothing.
      final code = await run(<String>[
        '--env=ci',
        'secrets',
        'set',
        'ASC_KEY_ID',
      ]);

      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('--stdin'));
      expect(runner.invocations, isEmpty);
    });

    test(
      'off macOS it fails as an environment problem, not a mistake',
      () async {
        project.write('key.txt', 'value');

        final code = await run(<String>[
          'secrets',
          'set',
          'ASC_KEY_ID',
          '--from-file=key.txt',
        ], host: HostPlatform.linux);

        expect(code, ShipwayExit.environmentError);
        expect(logger.output, contains('.env'));
      },
    );
  });

  group('import', () {
    test('stores every assignment and leaves the file alone', () async {
      emptyKeychain(runner);
      project.write('.env', '''
# a comment
ASC_KEY_ID=key-id
export ASC_ISSUER_ID="issuer id"
''');

      final code = await run(<String>['secrets', 'import']);

      expect(code, ShipwayExit.success);
      expect(logger.output, contains('2 stored'));
      expect(project.exists('.env'), isTrue);
      // Copied, not moved — and the report has to say so, or somebody deletes
      // a file believing shipway already did.
      expect(logger.output, contains('unchanged'));
    });

    test('keeps what is already stored unless forced', () async {
      project.write('.env', 'ASC_KEY_ID=key-id\n');
      runner.stub('find-generic-password', stdout: 'present');

      await run(<String>['secrets', 'import']);

      expect(logger.output, contains('1 already there'));
      expect(runner.ran('add-generic-password'), isFalse);
    });

    test('a missing file is a user error, not a silent success', () async {
      final code = await run(<String>['secrets', 'import', '--from=.env.nope']);

      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('.env.nope'));
    });
  });

  group('export', () {
    test('emits names and never touches the keychain', () async {
      final code = await run(<String>['secrets', 'export']);

      expect(code, ShipwayExit.success);
      expect(logger.output, contains('gh secret set ASC_KEY_ID'));
      expect(runner.invocations, isEmpty);
    });

    test('a team id in the config is not asked for as a secret', () async {
      // It appears in every build log, so the workflow writes it plainly.
      // Asking for it as a repository secret would hide nothing and add a
      // step that can be got wrong.
      await run(<String>['secrets', 'export']);

      expect(logger.output, isNot(contains('DEVELOPER_PORTAL_TEAM_ID')));
    });
  });

  test('an unknown action names the ones that exist', () async {
    final code = await run(<String>['secrets', 'nonsense']);

    expect(code, ShipwayExit.userError);
    expect(logger.output, contains('export'));
  });

  group('scope', () {
    setUp(() => project.write('shipway.yaml', _bothPlatforms));

    test('an iOS job passes without a single Android credential', () async {
      // The whole point: this job is handed the Apple secrets and nothing
      // else, and must not fail for a keystore it was never going to get.
      final code = await run(<String>[
        'secrets',
        'check',
        '--env',
        'ci',
        '--platform',
        'ios',
      ], environment: _iosSecrets);

      expect(code, ShipwayExit.success, reason: logger.output);
      expect(logger.output, contains('Nothing is missing.'));
      expect(logger.output, contains('Scope: ios'));
      expect(logger.output, isNot(contains('ANDROID_')));
      expect(logger.output, isNot(contains('FIREBASE_')));
    });

    test('the same environment fails the unscoped check', () async {
      final code = await run(<String>[
        'secrets',
        'check',
        '--env',
        'ci',
      ], environment: _iosSecrets);

      expect(code, ShipwayExit.environmentError);
      expect(logger.output, contains('ANDROID_KEYSTORE_BASE64'));
    });

    test('an Android firebase job asks for nothing of Apple\'s', () async {
      project.write('firebase.json', '{}');

      final code = await run(
        <String>[
          'secrets',
          'check',
          '--env',
          'ci',
          '--platform',
          'android',
          '--target',
          'firebase',
        ],
        environment: <String, String>{
          'ANDROID_KEYSTORE_BASE64': 'a2V5c3RvcmU=',
          'ANDROID_STORE_PASSWORD': 'store-password',
          'ANDROID_KEY_PASSWORD': 'key-password',
          'FIREBASE_SERVICE_ACCOUNT_JSON_PATH': 'firebase.json',
        },
      );

      expect(code, ShipwayExit.success, reason: logger.output);
      expect(logger.output, isNot(contains('ASC_KEY_ID')));
      expect(logger.output, isNot(contains('MATCH_PASSWORD')));
    });

    test('a target on the other platform is a user error', () async {
      final code = await run(<String>[
        'secrets',
        'check',
        '--platform',
        'ios',
        '--target',
        'firebase',
      ]);

      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('firebase is an Android target'));
    });

    test('JSON carries the scope it was asked for', () async {
      await run(<String>[
        'secrets',
        'list',
        '--env',
        'ci',
        '--target',
        'testflight',
        '--json',
      ], environment: _iosSecrets);

      final report = jsonDecode(logger.output) as Map<String, dynamic>;
      expect(report['scope'], <String, dynamic>{
        'platform': 'ios',
        'target': 'testflight',
      });
      final secrets = (report['secrets'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(secrets.map((s) => s['platform']).toSet(), <String>{'ios'});
    });
  });

  group('check --verify', () {
    final environment = <String, String>{
      ..._iosSecrets,
      'ASC_KEY_P8_BASE64': base64.encode(utf8.encode(ecPkcs8Pem)),
    };
    final args = <String>[
      'secrets',
      'check',
      '--env',
      'ci',
      '--platform',
      'ios',
      '--verify',
    ];

    setUp(() => project.write('shipway.yaml', _bothPlatforms));

    test('a key the service accepts passes, and says so', () async {
      http.replies.add(const HttpReply(statusCode: 200, body: '{"data":[]}'));

      final code = await run(args, environment: environment);

      expect(code, ShipwayExit.success, reason: logger.output);
      expect(logger.output, contains('App Store Connect accepted the key'));
      // Match is named, with where its real check lives.
      expect(logger.output, contains('`shipway release` pre-flight'));
      expect(http.requests, hasLength(1), reason: 'one request per credential');
    });

    test('a rejected key fails the check with the service\'s reason', () async {
      http.replies.add(
        const HttpReply(
          statusCode: 401,
          body: '{"errors":[{"code":"NOT_AUTHORIZED","detail":"Bad token"}]}',
        ),
      );

      final code = await run(args, environment: environment);

      expect(code, ShipwayExit.environmentError);
      expect(logger.output, contains('NOT_AUTHORIZED'));
      expect(logger.output, contains('1 credential was rejected'));
    });

    test('no network does not fail a check that is otherwise green', () async {
      http.replies.add(
        const HttpPostException(
          'could not reach api.appstoreconnect.apple.com',
        ),
      );

      final code = await run(args, environment: environment);

      expect(code, ShipwayExit.success, reason: logger.output);
      expect(logger.output, contains('could not be checked'));
    });

    test('JSON reports each outcome', () async {
      http.replies.add(const HttpReply(statusCode: 200, body: '{}'));

      await run(<String>[...args, '--json'], environment: environment);

      final report = jsonDecode(logger.output) as Map<String, dynamic>;
      final verified = (report['verified'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(verified.map((v) => v['outcome']), <String>['ok', 'skipped']);
    });

    test('without the flag nothing touches the network', () async {
      await run(<String>[
        'secrets',
        'check',
        '--env',
        'ci',
        '--platform',
        'ios',
      ], environment: environment);

      expect(http.requests, isEmpty);
    });

    test('is refused on any other action', () async {
      final code = await run(<String>['secrets', 'list', '--verify']);

      expect(code, ShipwayExit.userError);
    });
  });

  group('push', () {
    const repository = '{"nameWithOwner":"acme/demo"}';

    setUp(() {
      project.write('shipway.yaml', _bothPlatforms);
      runner
        ..stub('find-generic-password', exitCode: 44)
        ..stub('gh repo view', stdout: repository);
    });

    List<RecordedInvocation> sets() => runner.invocations
        .where((i) => i.commandLine.startsWith('gh secret set'))
        .toList();

    test('shows the plan, asks, then sends each value on stdin', () async {
      logger.answer = true;

      final code = await run(<String>[
        'secrets',
        'push',
        '--platform',
        'ios',
      ], environment: _iosSecrets);

      expect(code, ShipwayExit.success, reason: logger.output);
      expect(logger.output, contains('→ acme/demo'));
      expect(logger.questions.single, contains('5 secrets on acme/demo'));
      expect(
        sets().map((i) => i.arguments[2]).toSet(),
        _iosSecrets.keys.toSet(),
      );
      for (final invocation in sets()) {
        expect(invocation.stdin, _iosSecrets[invocation.arguments[2]]);
        expect(
          invocation.arguments,
          containsAllInOrder(<String>['--repo', 'acme/demo']),
        );
      }
      // Not on a command line, and not in anything printed.
      for (final value in _iosSecrets.values) {
        expect(runner.commandLines.join('\n'), isNot(contains(value)));
        expect(logger.output, isNot(contains(value)));
      }
    });

    test('declining sends nothing', () async {
      logger.answer = false;

      final code = await run(<String>[
        'secrets',
        'push',
        '--platform',
        'ios',
      ], environment: _iosSecrets);

      expect(code, ShipwayExit.userError);
      expect(sets(), isEmpty);
      expect(logger.output, contains('Nothing was sent.'));
    });

    test('--yes does not ask', () async {
      final code = await run(<String>[
        'secrets',
        'push',
        '--platform',
        'ios',
        '--yes',
      ], environment: _iosSecrets);

      expect(code, ShipwayExit.success, reason: logger.output);
      expect(logger.questions, isEmpty);
      expect(sets(), hasLength(5));
    });

    test('where nobody can answer, --yes is required', () async {
      final code = await run(
        <String>['secrets', 'push', '--platform', 'ios'],
        environment: <String, String>{..._iosSecrets, 'CI': 'true'},
      );

      expect(code, ShipwayExit.userError);
      expect(logger.output, contains('--yes'));
      expect(logger.questions, isEmpty);
      expect(sets(), isEmpty);
    });

    test('--dry-run prints the plan and sends nothing', () async {
      final code = await run(<String>[
        'secrets',
        'push',
        '--platform',
        'ios',
        '--dry-run',
      ], environment: _iosSecrets);

      expect(code, ShipwayExit.success, reason: logger.output);
      expect(logger.output, contains('ASC_KEY_ID'));
      expect(logger.output, contains('Dry run'));
      expect(logger.questions, isEmpty);
      expect(sets(), isEmpty);
    });

    test('--repo names the destination without asking gh', () async {
      await run(<String>[
        'secrets',
        'push',
        '--platform',
        'ios',
        '--repo',
        'acme/other',
        '--yes',
      ], environment: _iosSecrets);

      expect(runner.ran('gh repo view'), isFalse);
      expect(sets().first.arguments, contains('acme/other'));
    });

    test('--env ci still reads this machine\'s .env', () async {
      // The spelling the field report reached for. `ci` is where the values
      // are going; reading only what a runner could see would find nothing
      // on the laptop this is run from.
      project.write(
        '.env',
        _iosSecrets.entries.map((e) => '${e.key}=${e.value}').join('\n'),
      );

      final code = await run(<String>[
        'secrets',
        'push',
        '--env',
        'ci',
        '--platform',
        'ios',
        '--yes',
      ], environment: <String, String>{});

      expect(code, ShipwayExit.success, reason: logger.output);
      expect(logger.output, contains('--env ci names the destination'));
      expect(sets(), hasLength(5));
    });

    test('a file secret is renamed and its content sent', () async {
      project.write('keys/firebase.json', '{"client_email":"ci@acme"}\n');

      await run(
        <String>['secrets', 'push', '--target', 'firebase', '--yes'],
        environment: <String, String>{
          'ANDROID_KEYSTORE_BASE64': 'a2V5c3RvcmU=',
          'ANDROID_STORE_PASSWORD': 'store-password',
          'ANDROID_KEY_PASSWORD': 'key-password',
          'FIREBASE_SERVICE_ACCOUNT_JSON_PATH': 'keys/firebase.json',
        },
      );

      final account = runner.invocation(
        'gh secret set FIREBASE_SERVICE_ACCOUNT_JSON ',
      );
      expect(account.stdin, '{"client_email":"ci@acme"}');
      expect(
        runner.ran('gh secret set FIREBASE_SERVICE_ACCOUNT_JSON_PATH'),
        isFalse,
      );
      expect(runner.ran('gh secret set ASC_KEY_ID'), isFalse);
    });

    test('what is missing is skipped by name, and fails the run', () async {
      final partial = Map<String, String>.of(_iosSecrets)
        ..remove('MATCH_PASSWORD');

      final code = await run(<String>[
        'secrets',
        'push',
        '--platform',
        'ios',
        '--yes',
      ], environment: partial);

      expect(code, ShipwayExit.environmentError);
      expect(sets(), hasLength(4), reason: 'the rest are still pushed');
      expect(
        logger.output,
        contains('MATCH_PASSWORD is not set on this machine'),
      );
      expect(
        logger.output,
        contains('do not resolve on this machine: MATCH_PASSWORD'),
      );
    });

    test('without gh it says to install it, before reading anything', () async {
      runner.stub('gh --version', exitCode: 127);

      final code = await run(<String>[
        'secrets',
        'push',
        '--yes',
      ], environment: _iosSecrets);

      expect(code, ShipwayExit.environmentError);
      expect(logger.output, contains('cli.github.com'));
      expect(sets(), isEmpty);
    });

    test('signed out of gh it says to sign in', () async {
      runner.stub(
        'gh auth status',
        exitCode: 1,
        stderr: 'You are not logged into any GitHub hosts.',
      );

      final code = await run(<String>[
        'secrets',
        'push',
        '--yes',
      ], environment: _iosSecrets);

      expect(code, ShipwayExit.environmentError);
      expect(logger.output, contains('gh auth login'));
      expect(sets(), isEmpty);
    });
  });
}
