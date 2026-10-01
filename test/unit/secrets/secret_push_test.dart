import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipway/src/core/config/config_loader.dart';
import 'package:shipway/src/core/env/host_platform.dart';
import 'package:shipway/src/core/env/run_environment.dart';
import 'package:shipway/src/core/io/redactor.dart';
import 'package:shipway/src/secrets/repository_secrets.dart';
import 'package:shipway/src/secrets/secret_push.dart';
import 'package:shipway/src/secrets/secret_resolver.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

const String _config = '''
version: 1
project:
  name: acme_app
apps:
  main:
    path: .
    flavors:
      dev:
        suffix: ".dev"
        firebase:
          distribution:
            service_account_ref: FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH
    signing:
      android:
        keystore_ref: ANDROID_KEYSTORE_BASE64
        key_properties:
          store_password_ref: ANDROID_STORE_PASSWORD
          key_password_ref: ANDROID_KEY_PASSWORD
    targets:
      firebase: {}
''';

void main() {
  late FixtureProject project;
  late RecordingProcessRunner runner;
  late Redactor redactor;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    runner = RecordingProcessRunner();
    redactor = Redactor();
  });

  SecretPush pushWith(Map<String, String> environment) => SecretPush(
    resolver: SecretResolver(
      environment: RunEnvironment.workstation,
      projectRoot: project.path,
      runner: runner,
      redactor: redactor,
      processEnvironment: environment,
      host: HostPlatform.linux,
    ),
    redactor: redactor,
    projectRoot: project.path,
  );

  final secrets = RepositorySecrets.of(ConfigLoader.parse(_config));

  Future<PushEntry> entry(SecretPush push, String name) async =>
      (await push.plan(secrets)).firstWhere((e) => e.name == name);

  group('what is sent', () {
    test(
      'a path variable becomes the file content under the CI name',
      () async {
        // The mapping the field report got wrong by hand: _PATH locally, no
        // _PATH in the repository, and the content rather than the path.
        project.write('keys/dev.json', '{"client_email":"dev@acme"}\n');
        final push = pushWith(<String, String>{
          'FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH': 'keys/dev.json',
        });

        final dev = await entry(push, 'FIREBASE_DEV_SERVICE_ACCOUNT_JSON');

        expect(dev.localName, 'FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH');
        // Raw, not base64: the workflow writes it with `echo "$X" > file`.
        expect(await push.valueFor(dev), '{"client_email":"dev@acme"}');
      },
    );

    test('a keystore held as base64 is sent as it is', () async {
      final push = pushWith(<String, String>{
        'ANDROID_KEYSTORE_BASE64': 'a2V5c3RvcmUtYnl0ZXM=',
      });

      expect(
        await push.valueFor(await entry(push, 'ANDROID_KEYSTORE_BASE64')),
        'a2V5c3RvcmUtYnl0ZXM=',
      );
    });

    test('a keystore still named by path is encoded from its bytes', () async {
      // The workflow does `base64 --decode`. Encoding here, from bytes and
      // unwrapped, is what makes that decode to the same file.
      final bytes = <int>[0xfe, 0xed, 0xfe, 0xed, 0x00, 0x01, 0xff];
      File(p.join(project.path, 'upload.jks')).writeAsBytesSync(bytes);
      final push = pushWith(<String, String>{
        'ANDROID_KEYSTORE_BASE64': 'upload.jks',
      });

      final value = await push.valueFor(
        await entry(push, 'ANDROID_KEYSTORE_BASE64'),
      );

      expect(base64.decode(value!), bytes);
      expect(value, isNot(contains('\n')));
    });

    test('an ordinary value is sent unchanged, and registered', () async {
      final push = pushWith(<String, String>{
        'ANDROID_STORE_PASSWORD': 'hunter2-store',
      });

      final value = await push.valueFor(
        await entry(push, 'ANDROID_STORE_PASSWORD'),
      );

      expect(value, 'hunter2-store');
      expect(redactor.redact('gh said hunter2-store'), 'gh said ***');
    });
  });

  group('the plan', () {
    test('names what is missing by the name to set here', () async {
      final push = pushWith(<String, String>{});

      final dev = await entry(push, 'FIREBASE_DEV_SERVICE_ACCOUNT_JSON');

      expect(dev.resolved, isFalse);
      expect(dev.origin, contains('FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH'));
    });

    test('a path naming no file does not resolve', () async {
      final push = pushWith(<String, String>{
        'FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH': 'nope.json',
      });

      final dev = await entry(push, 'FIREBASE_DEV_SERVICE_ACCOUNT_JSON');

      expect(dev.resolved, isFalse);
      expect(dev.origin, contains('nope.json'));
    });
  });

  group('gh', () {
    final gh = GitHubCli(
      runner: RecordingProcessRunner(),
      workingDirectory: '.',
    );

    test('receives the value on stdin and never as an argument', () async {
      final ghRunner = RecordingProcessRunner();
      final cli = GitHubCli(runner: ghRunner, workingDirectory: project.path);
      final push = pushWith(<String, String>{
        'ANDROID_STORE_PASSWORD': 'hunter2-store',
      });

      final outcomes = await push.push(
        await push.plan(secrets),
        gh: cli,
        repository: 'acme/app',
      );

      expect(outcomes.single.ok, isTrue);
      final invocation = ghRunner.invocations.single;
      expect(invocation.arguments, <String>[
        'secret',
        'set',
        'ANDROID_STORE_PASSWORD',
        '--repo',
        'acme/app',
      ]);
      expect(invocation.stdin, 'hunter2-store');
      expect(invocation.commandLine, isNot(contains('hunter2')));
    });

    test('a refusal is reported and the rest still go', () async {
      final ghRunner = RecordingProcessRunner()
        ..stub(
          'secret set ANDROID_KEY_PASSWORD',
          exitCode: 1,
          stderr: 'HTTP 403: Resource not accessible by integration',
        );
      final cli = GitHubCli(runner: ghRunner, workingDirectory: project.path);
      final push = pushWith(<String, String>{
        'ANDROID_KEY_PASSWORD': 'key-password',
        'ANDROID_STORE_PASSWORD': 'store-password',
      });

      final outcomes = await push.push(
        await push.plan(secrets),
        gh: cli,
        repository: 'acme/app',
      );

      expect(outcomes, hasLength(2));
      expect(outcomes.first.ok, isFalse);
      expect(outcomes.first.error, contains('403'));
      expect(outcomes.last.ok, isTrue);
    });

    test('absent is told apart from signed out', () async {
      final absent = GitHubCli(
        runner: RecordingProcessRunner()..stub('gh --version', exitCode: 127),
        workingDirectory: '.',
      );
      final signedOut = GitHubCli(
        runner: RecordingProcessRunner()
          ..stub(
            'gh auth status',
            exitCode: 1,
            stderr: 'You are not logged into any GitHub hosts.',
          ),
        workingDirectory: '.',
      );

      await expectLater(
        absent.requireReady(),
        throwsA(
          isA<GitHubCliFailure>().having(
            (f) => f.fixHint,
            'fixHint',
            contains('cli.github.com'),
          ),
        ),
      );
      await expectLater(
        signedOut.requireReady(),
        throwsA(
          isA<GitHubCliFailure>().having(
            (f) => f.fixHint,
            'fixHint',
            contains('gh auth login'),
          ),
        ),
      );
      await expectLater(gh.requireReady(), completes);
    });

    test('reads the repository from gh, or says to pass --repo', () async {
      final known = GitHubCli(
        runner: RecordingProcessRunner()
          ..stub('gh repo view', stdout: '{"nameWithOwner":"acme/app"}'),
        workingDirectory: '.',
      );

      expect(await known.currentRepository(), 'acme/app');
      await expectLater(
        gh.currentRepository(),
        throwsA(
          isA<GitHubCliFailure>().having(
            (f) => f.fixHint,
            'fixHint',
            contains('--repo'),
          ),
        ),
      );
    });
  });
}
