import 'dart:io';

import 'package:shipway/src/core/config/shipway_config.dart';
import 'package:shipway/src/core/env/run_environment.dart';
import 'package:shipway/src/core/model/android_model.dart';
import 'package:shipway/src/core/secrets/secret_names.dart';
import 'package:shipway/src/generators/generated_file.dart';
import 'package:shipway/src/generators/workflow_generator.dart';
import 'package:shipway/src/secrets/secret_requirements.dart';
import 'package:shipway/src/version.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

ResolvedApp app({
  String? matchGitUrl = 'https://github.com/acme/certs.git',
  String? iosTeamId = 'ABCDE12345',
  AndroidSigningConfig? androidSigning = const AndroidSigningConfig(
    keystoreRef: 'ANDROID_KEYSTORE_BASE64',
    keyProperties: KeyPropertiesConfig(
      storePasswordRef: 'ANDROID_STORE_PASSWORD',
      keyPasswordRef: 'ANDROID_KEY_PASSWORD',
    ),
  ),
  PlayTarget? play = const PlayTarget(),
  FirebaseTarget? firebase = const FirebaseTarget(
    androidAppIdRef: 'FB_ANDROID_APP_ID',
  ),
  bool flavors = true,
}) => ResolvedApp(
  appId: 'main',
  projectName: 'acme_app',
  androidApplicationId: 'com.acme.app',
  iosBundleId: 'com.acme.app',
  gradleDsl: GradleDsl.kotlin,
  iosTeamId: iosTeamId,
  matchGitUrl: matchGitUrl,
  ascApiKey: const AscApiKeyConfig(
    keyIdRef: 'ASC_KEY_ID',
    issuerIdRef: 'ASC_ISSUER_ID',
    p8Ref: 'ASC_KEY_P8_BASE64',
  ),
  androidSigning: androidSigning,
  play: play,
  firebase: firebase,
  flavors: !flavors
      ? const <ResolvedFlavor>[]
      : const <ResolvedFlavor>[
          ResolvedFlavor(
            name: 'dev',
            suffix: '.dev',
            entrypoint: 'lib/main_dev.dart',
            dimension: 'environment',
            iosBundleId: 'com.acme.app.dev',
            androidApplicationId: 'com.acme.app.dev',
          ),
          ResolvedFlavor(
            name: 'prod',
            suffix: '',
            entrypoint: 'lib/main_prod.dart',
            dimension: 'environment',
            iosBundleId: 'com.acme.app',
            androidApplicationId: 'com.acme.app',
          ),
        ],
);

String render(ResolvedApp resolved) =>
    const WorkflowGenerator().render(resolved).single.contents;

YamlMap parse(ResolvedApp resolved) => loadYaml(render(resolved)) as YamlMap;

YamlMap job(ResolvedApp resolved, String name) =>
    (parse(resolved)['jobs'] as YamlMap)[name] as YamlMap;

List<String> stepNames(YamlMap job) => <String>[
  for (final step in job['steps'] as YamlList)
    ((step as YamlMap)['name'] ?? step['uses']).toString(),
];

/// The `dart pub global activate` lines, which are what a runner actually
/// executes — the surrounding comment mentions the flag too.
List<String> activateCommands(String workflow) => <String>[
  for (final line in workflow.split('\n'))
    if (line.contains('dart pub global activate')) line.trim(),
];

void main() {
  test('it is valid YAML with the jobs a release needs', () {
    // Generated YAML that does not parse is worse than none: GitHub reports it
    // as a repository-level error with no line number a reader can act on.
    final jobs = parse(app())['jobs'] as YamlMap;
    expect(jobs.keys, containsAll(<String>['ios', 'android']));
  });

  test('the flavor choices come from the config', () {
    final input =
        ((parse(app())['on'] as YamlMap)['workflow_dispatch']
                as YamlMap)['inputs']
            as YamlMap;
    expect((input['flavor'] as YamlMap)['options'], <String>['dev', 'prod']);
  });

  test('releases are serialised', () {
    // Two uploads racing produce two builds claiming one version, and the
    // store rejects the second as a duplicate.
    final concurrency = parse(app())['concurrency'] as YamlMap;
    expect(concurrency['cancel-in-progress'], isFalse);
  });

  group('getting signing material onto a runner', () {
    test('an HTTPS match repo asks for basic authorisation', () {
      // match treats the two mechanisms as mutually exclusive and silently
      // ignores the wrong one, so the choice is made from the URL rather than
      // left to the reader.
      final env = job(app(), 'ios')['env'] as YamlMap;
      expect(env.keys, contains(SecretNames.matchGitBasicAuthorization));
      expect(env.keys, isNot(contains(SecretNames.matchGitPrivateKey)));
    });

    test('an SSH match repo asks for a private key instead', () {
      final env =
          job(app(matchGitUrl: 'git@github.com:acme/certs.git'), 'ios')['env']
              as YamlMap;
      expect(env.keys, contains(SecretNames.matchGitPrivateKey));
      expect(env.keys, isNot(contains(SecretNames.matchGitBasicAuthorization)));
    });

    test('the keystore and key.properties are rebuilt from the secret', () {
      // A checkout has neither: the keystore is binary and git-ignored, and
      // key.properties holds passwords. Without this the build fails inside
      // Gradle on a null signing config.
      final android = job(app(), 'android');
      expect(stepNames(android), contains('Materialise the signing key'));

      final rendered = render(app());
      expect(rendered, contains('base64 --decode'));
      expect(rendered, contains('key.properties'));
      // Absolute, because storeFile resolves relative to android/app and a
      // relative path silently misses.
      expect(rendered, contains(r'storeFile=$GITHUB_WORKSPACE'));
    });

    test('path-valued service accounts are written to real files', () {
      final steps = stepNames(job(app(), 'android'));
      expect(steps, contains('Materialise the Play service account'));
      expect(steps, contains('Materialise the Firebase service account'));
    });

    test('nothing is materialised when nothing is configured', () {
      final steps = stepNames(
        job(app(androidSigning: null, play: null, firebase: null), 'android'),
      );
      expect(steps, isNot(contains('Materialise the signing key')));
      expect(steps, isNot(contains('Materialise the Play service account')));
    });
  });

  group('what goes in env', () {
    test('a known team id is written plainly, not hidden as a secret', () {
      // It is printed in every build log. A repository secret that hides
      // nothing is theatre.
      final env = job(app(), 'ios')['env'] as YamlMap;
      expect(env[SecretNames.developerPortalTeamId], 'ABCDE12345');
    });

    test('an unknown team id falls back to a secret', () {
      final env = job(app(iosTeamId: null), 'ios')['env'] as YamlMap;
      expect(
        env[SecretNames.developerPortalTeamId],
        contains('secrets.${SecretNames.developerPortalTeamId}'),
      );
    });
  });

  test('the pre-flight cannot demand something the workflow never sets', () {
    // The property that makes this generated rather than copied from a README.
    // A workflow whose own `secrets check` step fails is worse than no
    // workflow: it looks configured and refuses to run.
    final resolved = app();
    final rendered = render(resolved);

    final config = ShipwayConfig.fromJson(<String, dynamic>{
      'version': 1,
      'project': <String, dynamic>{'name': 'acme_app'},
      'apps': <String, dynamic>{
        'main': <String, dynamic>{
          'ios': <String, dynamic>{'bundle_id': 'com.acme.app'},
          'android': <String, dynamic>{'application_id': 'com.acme.app'},
          'signing': <String, dynamic>{
            'ios': <String, dynamic>{
              'match_git_url': 'https://github.com/acme/certs.git',
              'team_id': 'ABCDE12345',
              'api_key': <String, dynamic>{
                'key_id_ref': 'ASC_KEY_ID',
                'issuer_id_ref': 'ASC_ISSUER_ID',
                'p8_ref': 'ASC_KEY_P8_BASE64',
              },
            },
            'android': <String, dynamic>{
              'keystore_ref': 'ANDROID_KEYSTORE_BASE64',
              'key_properties': <String, dynamic>{
                'store_password_ref': 'ANDROID_STORE_PASSWORD',
                'key_password_ref': 'ANDROID_KEY_PASSWORD',
              },
            },
          },
          'targets': <String, dynamic>{
            'play': <String, dynamic>{'track': 'internal'},
            'firebase': <String, dynamic>{
              'android_app_id_ref': 'FB_ANDROID_APP_ID',
            },
          },
        },
      },
    });

    final required = SecretRequirements.of(
      config,
      environment: RunEnvironment.ephemeralCi,
    ).where((r) => r.isRequired).map((r) => r.name);

    for (final name in required) {
      expect(
        rendered,
        contains(name),
        reason: '$name is required on CI but the workflow never provides it',
      );
    }
  });

  group('installing shipway on the runner', () {
    test('both jobs install it from the package own repository', () {
      final commands = activateCommands(render(app()));
      expect(
        commands,
        hasLength(2),
        reason: 'both jobs run shipway, so both have to install it',
      );
      expect(commands, everyElement(contains(packageRepository)));
    });

    test('the repository it names is the one pubspec declares', () {
      // Two places have to agree, and the one a runner uses is the one nobody
      // looks at until it 404s in somebody else's repository.
      final pubspec =
          loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
      expect(packageRepository, pubspec['repository']);
    });

    test('the version it pins is the one pubspec declares', () {
      final pubspec =
          loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
      expect(packageVersion, pubspec['version']);
    });

    test('a beta is tagged, only a dev build is not', () {
      // A beta is published and tagged; treating every pre-release as
      // untagged would leave a beta's workflows tracking the default branch.
      expect(packageVersion.endsWith('-dev'), packageGitRef == null);
    });

    test('a released version is pinned to its tag, a dev build is not', () {
      // Installing the default branch means a workflow can break on a morning
      // nobody touched this repository; naming a tag that does not exist means
      // it breaks immediately. Neither is acceptable, so which one is emitted
      // follows the version.
      final rendered = render(app());
      final ref = packageGitRef;
      if (ref == null) {
        expect(
          activateCommands(rendered),
          everyElement(isNot(contains('--git-ref'))),
        );
        expect(rendered, contains('development build'));
      } else {
        expect(
          activateCommands(rendered),
          everyElement(contains('--git-ref $ref')),
        );
      }
    });
  });

  group('a Play service account named by the config', () {
    test('travels as a repository secret, with no file to write', () {
      // The lane reads the JSON itself here, so materialising a file would
      // write one nothing opens and demand a secret nobody set.
      final resolved = app(
        play: const PlayTarget(serviceAccountRef: 'PLAY_JSON'),
      );
      final env = job(resolved, 'android')['env'] as YamlMap;

      expect(env.keys, contains('PLAY_JSON'));
      expect(env.keys, isNot(contains(SecretNames.playServiceAccountPath)));
      expect(
        stepNames(job(resolved, 'android')),
        isNot(contains('Materialise the Play service account')),
      );
    });

    test('otherwise the path convention writes the file', () {
      final env = job(app(), 'android')['env'] as YamlMap;

      expect(env.keys, contains(SecretNames.playServiceAccountPath));
      expect(
        stepNames(job(app(), 'android')),
        contains('Materialise the Play service account'),
      );
    });
  });

  test('a project shipping only to Firebase runs the firebase lane', () {
    // Running the play lane there fails at a Play credential the project was
    // never going to have.
    expect(
      render(app(play: null)),
      contains('bundle exec fastlane android firebase'),
    );
    expect(render(app()), contains('bundle exec fastlane android play'));
  });

  test('a project with no flavors gets no workflow', () {
    expect(const WorkflowGenerator().render(app(flavors: false)), isEmpty);
  });

  test('it is create-once and never swept', () {
    // By the second run it is somebody's pipeline.
    final file = const WorkflowGenerator().render(app()).single;
    expect(file.createOnly, isTrue);
    expect(const WorkflowGenerator().owns(WorkflowGenerator.path), isFalse);
  });
}
