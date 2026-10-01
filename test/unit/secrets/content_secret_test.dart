import 'package:shipway/src/core/env/host_platform.dart';
import 'package:shipway/src/core/env/run_environment.dart';
import 'package:shipway/src/core/io/redactor.dart';
import 'package:shipway/src/secrets/secret_requirements.dart';
import 'package:shipway/src/secrets/secret_resolver.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_process_runner.dart';

const SecretRequirement _path = SecretRequirement(
  name: 'PLAY_SERVICE_ACCOUNT_JSON_PATH',
  need: Need.required,
  wantedBy: 'the play lane',
  isPath: true,
);

const SecretRequirement _plain = SecretRequirement(
  name: 'MATCH_PASSWORD',
  need: Need.required,
  wantedBy: 'the certificates lane',
);

/// A path-valued variable on a runner is supplied as the file's content, and
/// `shipway release` writes the file. The pre-flight has to agree, or the
/// generated workflow's own `secrets check` step fails every job.
void main() {
  late FixtureProject project;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
  });

  SecretResolver resolver(
    RunEnvironment environment,
    Map<String, String> processEnvironment,
  ) => SecretResolver(
    environment: environment,
    projectRoot: project.path,
    runner: RecordingProcessRunner(defaultResponse: null)
      ..stub('security', exitCode: 44),
    redactor: Redactor(),
    processEnvironment: processEnvironment,
    host: HostPlatform.macos,
  );

  const content = <String, String>{'PLAY_SERVICE_ACCOUNT_JSON': '{}'};

  for (final environment in <RunEnvironment>[
    RunEnvironment.ephemeralCi,
    RunEnvironment.persistentRunner,
  ]) {
    test(
      'the content secret satisfies the path on ${environment.flagName}',
      () async {
        final status = await resolver(environment, content).status(_path);

        expect(status.blocks, isFalse);
        expect(status.source, SecretSource.environment);
        // Says which variable it actually found, since it is not the one asked
        // about.
        expect(status.detail, contains('PLAY_SERVICE_ACCOUNT_JSON'));
      },
    );
  }

  test(
    'a path naming a missing file is still satisfied by the content',
    () async {
      final status = await resolver(
        RunEnvironment.ephemeralCi,
        <String, String>{
          ...content,
          'PLAY_SERVICE_ACCOUNT_JSON_PATH': 'gone.json',
        },
      ).status(_path);
      expect(status.blocks, isFalse);
    },
  );

  test('a real file is still reported as the file', () async {
    project.write('play.json', '{}');
    final status = await resolver(RunEnvironment.ephemeralCi, <String, String>{
      ...content,
      'PLAY_SERVICE_ACCOUNT_JSON_PATH': 'play.json',
    }).status(_path);
    expect(status.detail, 'environment');
  });

  test('with neither, it is still missing', () async {
    final status = await resolver(
      RunEnvironment.ephemeralCi,
      const <String, String>{},
    ).status(_path);
    expect(status.blocks, isTrue);
    expect(status.source, SecretSource.absent);
  });

  test('not on a workstation, where nothing writes the file', () async {
    // There the lane would be handed a path to nothing, and the pre-flight
    // would have said it was fine.
    final status = await resolver(
      RunEnvironment.workstation,
      content,
    ).status(_path);
    expect(status.blocks, isTrue);
  });

  test('a variable that is not a path gets no such fallback', () async {
    final status = await resolver(
      RunEnvironment.ephemeralCi,
      const <String, String>{'MATCH_PASSWORD_CONTENT': 'x'},
    ).status(_plain);
    expect(status.blocks, isTrue);
  });

  test('the value read for the path is not the content', () async {
    // `read` hands back what the lane is given. Returning JSON where a path
    // is expected would be passed straight to `File.open`.
    final value = await resolver(
      RunEnvironment.ephemeralCi,
      content,
    ).read('PLAY_SERVICE_ACCOUNT_JSON_PATH');
    expect(value, isNull);
  });
}
