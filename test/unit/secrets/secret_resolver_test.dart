import 'package:shipway/src/core/env/host_platform.dart';
import 'package:shipway/src/core/env/run_environment.dart';
import 'package:shipway/src/core/io/redactor.dart';
import 'package:shipway/src/secrets/secret_requirements.dart';
import 'package:shipway/src/secrets/secret_resolver.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

const SecretRequirement plain = SecretRequirement(
  name: 'MATCH_PASSWORD',
  need: Need.required,
  wantedBy: 'the certificates lane',
);

const SecretRequirement asPath = SecretRequirement(
  name: 'PLAY_SERVICE_ACCOUNT_JSON_PATH',
  need: Need.required,
  wantedBy: 'the play lane',
  isPath: true,
);

void main() {
  late FixtureProject project;
  late RecordingProcessRunner runner;
  late Redactor redactor;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    redactor = Redactor();
    runner = RecordingProcessRunner();
  });

  SecretResolver resolver({
    RunEnvironment environment = RunEnvironment.workstation,
    Map<String, String> processEnvironment = const <String, String>{},
    String? flavor,
    // Pinned rather than inherited from the machine running the tests, so
    // these assertions mean the same thing on a Linux CI box as they do here.
    HostPlatform host = HostPlatform.macos,
  }) => SecretResolver(
    environment: environment,
    projectRoot: project.path,
    runner: runner,
    redactor: redactor,
    processEnvironment: processEnvironment,
    flavor: flavor,
    host: host,
  );

  group('the chain is a property of the environment', () {
    test('a workstation may reach a prompt', () {
      expect(
        resolver().chain,
        containsAllInOrder(<SecretSource>[
          SecretSource.environment,
          SecretSource.dotenv,
          SecretSource.keychain,
          SecretSource.prompt,
        ]),
      );
    });

    test('ephemeral CI reads the environment and nothing else', () {
      expect(
        resolver(environment: RunEnvironment.ephemeralCi).chain,
        <SecretSource>[SecretSource.environment],
      );
    });

    test('a machine with no security keychain is not offered one', () async {
      // The chain is printed to the user. Naming the keychain on Linux would
      // be advice to put a value somewhere nothing will ever read it.
      final linux = resolver(host: HostPlatform.linux);
      expect(linux.chain, isNot(contains(SecretSource.keychain)));
      expect(linux.chain, contains(SecretSource.prompt));

      // And the lookup agrees with what the chain claims: no `security` call.
      await linux.status(plain);
      expect(runner.ran('security'), isFalse);
    });

    test('a persistent runner never reaches the login keychain', () {
      // It may not be unlocked after a reboot, and depending on it is what
      // makes self-hosted builders fail in ways that look like signing bugs.
      final chain = resolver(
        environment: RunEnvironment.persistentRunner,
      ).chain;
      expect(chain, isNot(contains(SecretSource.keychain)));
      expect(chain, isNot(contains(SecretSource.prompt)));
    });
  });

  group('resolution', () {
    test('the environment wins over .env', () async {
      project.write('.env', 'MATCH_PASSWORD=from-file\n');
      final status = await resolver(
        processEnvironment: const <String, String>{
          'MATCH_PASSWORD': 'from-env',
        },
      ).status(plain);

      expect(status.source, SecretSource.environment);
      expect(status.blocks, isFalse);
    });

    test('.env is read when the environment is silent', () async {
      project.write('.env', 'MATCH_PASSWORD=from-file\n');
      final status = await resolver().status(plain);
      expect(status.source, SecretSource.dotenv);
      expect(status.detail, '.env');
    });

    test('a flavor selects its own file', () async {
      project.write('.env.dev', 'MATCH_PASSWORD=dev-value\n');
      final status = await resolver(flavor: 'dev').status(plain);
      expect(status.source, SecretSource.dotenv);
      expect(status.detail, '.env.dev');
    });

    test('.env is ignored on ephemeral CI even when present', () async {
      project.write('.env', 'MATCH_PASSWORD=from-file\n');
      final status = await resolver(
        environment: RunEnvironment.ephemeralCi,
      ).status(plain);

      expect(status.source, SecretSource.absent);
      expect(status.blocks, isTrue);
      expect(status.detail, contains('cannot prompt'));
    });

    test('an empty value counts as unset', () async {
      final status = await resolver(
        processEnvironment: const <String, String>{'MATCH_PASSWORD': '   '},
      ).status(plain);
      expect(status.source, SecretSource.absent);
    });

    test('an optional secret never blocks', () async {
      const optional = SecretRequirement(
        name: 'MATCH_GIT_BRANCH',
        need: Need.optional,
        wantedBy: 'the match repository',
      );
      final status = await resolver().status(optional);
      expect(status.source, SecretSource.absent);
      expect(status.blocks, isFalse);
    });
  });

  group('path-valued secrets', () {
    test('a path naming a file that is not there blocks', () async {
      // The same failure as being unset, only discovered twenty minutes into
      // a build instead of before it.
      final status = await resolver(
        processEnvironment: const <String, String>{
          'PLAY_SERVICE_ACCOUNT_JSON_PATH': 'play.json',
        },
      ).status(asPath);

      expect(status.source, SecretSource.missingFile);
      expect(status.blocks, isTrue);
      expect(status.detail, 'play.json');
    });

    test('a path that exists resolves', () async {
      project.write('play.json', '{}');
      final status = await resolver(
        processEnvironment: const <String, String>{
          'PLAY_SERVICE_ACCOUNT_JSON_PATH': 'play.json',
        },
      ).status(asPath);

      expect(status.source, SecretSource.environment);
      expect(status.blocks, isFalse);
    });
  });

  group('nothing leaks', () {
    test('a status carries a source, never a value', () async {
      project.write('.env', 'MATCH_PASSWORD=hunter2\n');
      final status = await resolver().status(plain);

      // The type is the guarantee: `secrets list` cannot print a credential
      // because it is never handed one.
      expect(status.detail, isNot(contains('hunter2')));
      expect(status.toString(), isNot(contains('hunter2')));
    });

    test('reading a value registers it with the redactor first', () async {
      project.write('.env', 'MATCH_PASSWORD=hunter2\n');
      final value = await resolver().read('MATCH_PASSWORD');

      expect(value, 'hunter2');
      expect(
        redactor.redact('the password is hunter2'),
        isNot(contains('hunter2')),
      );
    });
  });

  group('the .env parser', () {
    test('handles what these files actually contain', () {
      final values = SecretResolver.parseDotenv('''
# a comment
MATCH_PASSWORD=plain

export EXPORTED=yes
QUOTED="double"
SINGLE='single'
WITH_EQUALS=a=b=c
  SPACED  =  trimmed
''');

      expect(values['MATCH_PASSWORD'], 'plain');
      expect(values['EXPORTED'], 'yes');
      expect(values['QUOTED'], 'double');
      expect(values['SINGLE'], 'single');
      expect(values['WITH_EQUALS'], 'a=b=c');
      expect(values['SPACED'], 'trimmed');
    });

    test('ignores lines that are not assignments', () {
      final values = SecretResolver.parseDotenv('nonsense\n=novalue\n\n');
      expect(values, isEmpty);
    });
  });

  test('a flavor file layers over .env rather than replacing it', () async {
    // Shared values live in .env and the flavor's file only overrides. Reading
    // one or the other reported a variable missing that was set where people
    // actually keep it.
    project
      ..write('.env', 'MATCH_PASSWORD=shared\nMATCH_GIT_BRANCH=main\n')
      ..write('.env.dev', 'MATCH_PASSWORD=dev\n');
    final layered = resolver(flavor: 'dev');

    expect(await layered.read('MATCH_PASSWORD'), 'dev');
    expect((await layered.status(plain)).detail, '.env.dev');

    final shared = await layered.status(
      const SecretRequirement(
        name: 'MATCH_GIT_BRANCH',
        need: Need.required,
        wantedBy: 'the match repository',
      ),
    );
    expect(shared.source, SecretSource.dotenv);
    expect(shared.detail, '.env');
  });
}
