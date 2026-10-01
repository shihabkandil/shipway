import 'dart:io';

import 'package:shipway/src/core/config/shipway_config.dart';
import 'package:shipway/src/core/env/run_environment.dart';
import 'package:shipway/src/core/model/android_model.dart';
import 'package:shipway/src/core/secrets/secret_names.dart';
import 'package:shipway/src/core/toolchain/fastlane_pins.dart';
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
  bool shipsIos = true,
  CiRunner ciRunner = CiRunner.hosted,
}) => ResolvedApp(
  shipsIos: shipsIos,
  ciRunner: ciRunner,
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

String render(
  ResolvedApp resolved, {
  WorkflowPins pins = const WorkflowPins(),
}) => WorkflowGenerator(pins: pins).render(resolved).single.contents;

YamlMap parse(ResolvedApp resolved) => loadYaml(render(resolved)) as YamlMap;

ResolvedApp selfHosted({String? matchGitUrl}) => app(
  ciRunner: CiRunner.selfHosted,
  matchGitUrl: matchGitUrl ?? 'https://github.com/acme/certs.git',
);

YamlMap inputs(ResolvedApp resolved) =>
    ((parse(resolved)['on'] as YamlMap)['workflow_dispatch']
            as YamlMap)['inputs']
        as YamlMap;

/// Every key anywhere in [node], however deeply nested.
Iterable<String> allKeys(Object? node) sync* {
  if (node is YamlMap) {
    for (final entry in node.entries) {
      yield entry.key.toString();
      yield* allKeys(entry.value);
    }
  } else if (node is YamlList) {
    for (final item in node) {
      yield* allKeys(item);
    }
  }
}

/// Every `uses:` in a job, without its version.
List<String> actionsOf(YamlMap job) => <String>[
  for (final step in job['steps'] as YamlList)
    if ((step as YamlMap)['uses'] case final String uses) uses.split('@').first,
];

/// The `run:` of the step called [name].
String runOf(YamlMap job, String name) =>
    ((job['steps'] as YamlList).firstWhere(
              (step) => (step as YamlMap)['name'] == name,
            )
            as YamlMap)['run']
        as String;

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

    test('no step writes a credential file — shipway release does', () {
      // A file a YAML step writes is a file a YAML step has to remember to
      // remove, on every path out of the job. `shipway release` writes them
      // and removes them in a `finally`, so the workflow has nothing to forget.
      for (final resolved in <ResolvedApp>[app(), selfHosted()]) {
        final rendered = render(resolved);
        expect(rendered, isNot(contains('base64 --decode')));
        expect(rendered, isNot(contains('> "\$GITHUB_WORKSPACE')));
        expect(
          stepNames(job(resolved, 'android')),
          isNot(contains(startsWith('Materialise'))),
        );
      }
    });

    test('the keystore and its passwords are passed for shipway to use', () {
      final env = job(app(), 'android')['env'] as YamlMap;
      expect(
        env.keys,
        containsAll(<String>[
          'ANDROID_KEYSTORE_BASE64',
          'ANDROID_STORE_PASSWORD',
          'ANDROID_KEY_PASSWORD',
        ]),
      );
    });

    test('a keystore with no named passwords still gets two', () {
      // key.properties cannot be built without them, and the names are the
      // ones `shipway release` falls back to.
      final env =
          job(
                app(
                  androidSigning: const AndroidSigningConfig(
                    keystoreRef: 'ANDROID_KEYSTORE_BASE64',
                  ),
                ),
                'android',
              )['env']
              as YamlMap;
      expect(env.keys, contains(SecretNames.androidStorePasswordDefault));
      expect(env.keys, contains(SecretNames.androidKeyPasswordDefault));
    });

    test('path-valued service accounts travel as their content', () {
      // A repository can hold a file's content, not a path to it. The content
      // secret is what is passed; the path variable is set by shipway to the
      // file it writes, so setting it here as well would point at nothing.
      final env = job(app(), 'android')['env'] as YamlMap;
      expect(env.keys, contains(SecretNames.playServiceAccountJson));
      expect(env.keys, contains(SecretNames.firebaseServiceAccountJson));
      expect(env.keys, isNot(contains(SecretNames.playServiceAccountPath)));
      expect(env.keys, isNot(contains(SecretNames.firebaseServiceAccountPath)));
    });

    test('nothing is passed when nothing is configured', () {
      final android = job(
        app(androidSigning: null, play: null, firebase: null),
        'android',
      );
      // A comment, so the key parses as null rather than as a map.
      expect(android['env'], isNull);
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
    ).where((r) => r.isRequired);

    for (final requirement in required) {
      // A path is satisfied on a runner by the secret holding its content.
      final name = requirement.isPath
          ? SecretNames.contentSecretFor(requirement.name)
          : requirement.name;
      expect(
        rendered,
        contains('$name: '),
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
      expect(env.keys, isNot(contains(SecretNames.playServiceAccountJson)));
    });

    test('otherwise the content secret is passed for shipway to write', () {
      final env = job(app(), 'android')['env'] as YamlMap;

      expect(env.keys, contains(SecretNames.playServiceAccountJson));
    });
  });

  group('what a job runs', () {
    test('shipway release, not fastlane', () {
      // The pre-flight, the failure summary, the credential files and the
      // Gradle limits all live in `shipway release`. A workflow calling
      // fastlane directly gets none of them.
      for (final resolved in <ResolvedApp>[app(), selfHosted()]) {
        final rendered = render(resolved);
        expect(rendered, isNot(contains('bundle exec fastlane')));
        expect(
          runOf(job(resolved, 'ios'), 'Build and upload'),
          startsWith(
            r'shipway release ios --flavor ${{ inputs.flavor }} '
            '--target testflight',
          ),
        );
        expect(
          runOf(job(resolved, 'android'), 'Build and upload'),
          startsWith(
            r'shipway release android --flavor ${{ inputs.flavor }} '
            '--target play',
          ),
        );
      }
    });

    test('a project shipping only to Firebase releases to firebase', () {
      // Releasing to Play there fails at a Play credential the project was
      // never going to have.
      expect(
        runOf(job(app(play: null), 'android'), 'Build and upload'),
        contains('--target firebase'),
      );
    });

    test('each job checks only its own platform\'s credentials', () {
      // An Android job that fails because MATCH_PASSWORD is not in its env is
      // a pre-flight reporting a problem the job does not have.
      expect(
        runOf(job(app(), 'ios'), 'Check credentials'),
        'shipway secrets check --env ci --platform ios',
      );
      expect(
        runOf(job(app(), 'android'), 'Check credentials'),
        'shipway secrets check --env ci --platform android',
      );
    });

    test('the Ruby installed is one fastlane still supports', () {
      // Not the Gemfile's floor, which is the oldest Ruby the gems install
      // on. fastlane warns below 3.3, and a runner has no reason to be there.
      final rendered = render(app());
      expect(rendered, contains("ruby-version: '${FastlanePins.ciRuby}'"));
      final version = FastlanePins.ciRuby.split('.').map(int.parse).toList();
      expect(version[0] > 3 || (version[0] == 3 && version[1] >= 3), isTrue);
    });
  });

  group('releasing one platform', () {
    test('each platform is an input, on by default', () {
      for (final resolved in <ResolvedApp>[app(), selfHosted()]) {
        final declared = inputs(resolved);
        for (final platform in <String>['ios', 'android']) {
          final input = declared[platform] as YamlMap;
          expect(input['type'], 'boolean');
          expect(input['default'], isTrue);
        }
      }
    });

    test('each job runs only when its input is ticked', () {
      for (final resolved in <ResolvedApp>[app(), selfHosted()]) {
        expect(job(resolved, 'ios')['if'], r'${{ inputs.ios }}');
        expect(job(resolved, 'android')['if'], r'${{ inputs.android }}');
      }
    });

    test('a project with no iOS job has no iOS input', () {
      // A checkbox that gates nothing is a question with no answer.
      final resolved = app(shipsIos: false);
      expect(inputs(resolved).keys, isNot(contains('ios')));
      expect(inputs(resolved).keys, contains('android'));
      expect((parse(resolved)['jobs'] as YamlMap).keys, <String>['android']);
    });
  });

  group('a hosted runner', () {
    test('is told it is disposable', () {
      final rendered = render(app());
      expect(rendered, contains('--env ci'));
      expect(rendered, isNot(contains('--env persistent')));
      expect(WorkflowGenerator.runnerOf(rendered), CiRunner.hosted);
    });

    test('installs its toolchain and caches it', () {
      // A clean machine has nothing, and is thrown away afterwards: both the
      // installing and the caching are right here.
      final ios = job(app(), 'ios');
      expect(ios['runs-on'], 'macos-15');
      expect(
        actionsOf(ios),
        containsAll(<String>['subosito/flutter-action', 'ruby/setup-ruby']),
      );
      expect(allKeys(ios), containsAll(<String>['cache', 'bundler-cache']));
    });

    test('has no cleanup step, because the machine is the cleanup', () {
      expect(
        stepNames(job(app(), 'android')),
        isNot(contains(contains('Remove'))),
      );
    });
  });

  group('a self-hosted runner', () {
    test('is valid YAML with both jobs', () {
      final jobs = parse(selfHosted())['jobs'] as YamlMap;
      expect(jobs.keys, <String>['ios', 'android']);
    });

    test('is told it is persistent', () {
      final rendered = render(selfHosted());
      expect(rendered, contains('--env persistent'));
      expect(rendered, isNot(contains('--env ci')));
      expect(
        runOf(job(selfHosted(), 'ios'), 'Check credentials'),
        'shipway secrets check --env persistent --platform ios',
      );
      expect(WorkflowGenerator.runnerOf(rendered), CiRunner.selfHosted);
    });

    test('runs on self-hosted labels', () {
      expect(job(selfHosted(), 'ios')['runs-on'], <String>[
        'self-hosted',
        'macOS',
      ]);
      expect(job(selfHosted(), 'android')['runs-on'], contains('self-hosted'));
    });

    test('has no action-level cache anywhere', () {
      // What a job caches on a machine that keeps running is there for the
      // next job, and `bundler-cache` leaves a .bundle/config behind that
      // points every later `bundle` at vendor/bundle.
      final keys = allKeys(parse(selfHosted())).toSet();
      expect(keys, isNot(contains('cache')));
      expect(keys, isNot(contains('bundler-cache')));
      expect(keys.where((k) => k.contains('cache')), isEmpty);
    });

    test('uses no setup action that assumes a clean machine', () {
      for (final name in <String>['ios', 'android']) {
        expect(actionsOf(job(selfHosted(), name)), <String>[
          'actions/checkout',
        ]);
      }
    });

    test('puts pub executables on PATH itself', () {
      // flutter-action did that. Without it, the step after the install fails
      // on `shipway: command not found`.
      expect(
        runOf(job(selfHosted(), 'ios'), 'Install shipway'),
        contains(r'>> "$GITHUB_PATH"'),
      );
    });

    test('cleans up whatever happened, by calling shipway', () {
      for (final name in <String>['ios', 'android']) {
        final steps = job(selfHosted(), name)['steps'] as YamlList;
        final last = steps.last as YamlMap;
        expect(last['if'], 'always()');
        expect(last['run'], 'shipway cleanup');
      }
    });

    test('does not append to known_hosts on every run', () {
      // That file belongs to the machine, and a line added per job is a file
      // that only grows.
      final resolved = selfHosted(matchGitUrl: 'git@github.com:acme/certs.git');
      expect(
        stepNames(job(resolved, 'ios')),
        isNot(contains('Authorise the certificates repository')),
      );
      final env = job(resolved, 'ios')['env'] as YamlMap;
      expect(env.keys, contains(SecretNames.matchGitPrivateKey));
    });

    test('reads the same secrets a hosted one does', () {
      // The runner changes how a machine is prepared, never what a release
      // needs.
      Set<String> secrets(ResolvedApp resolved) => <String>{
        for (final match in RegExp(
          r'secrets\.([A-Za-z0-9_]+)',
        ).allMatches(render(resolved)))
          match.group(1)!,
      };
      expect(secrets(selfHosted()), secrets(app()));
    });
  });

  group('pinned toolchain versions', () {
    const pins = WorkflowPins(flutterVersion: '3.35.4', xcodeVersion: '16.2');

    test('nothing is pinned unless a version is handed over', () {
      final rendered = render(app());
      expect(rendered, isNot(contains('flutter-version')));
      expect(rendered, isNot(contains('DEVELOPER_DIR')));
    });

    test('a hosted runner installs the pinned Flutter', () {
      final rendered = render(app(), pins: pins);
      final parsed = loadYaml(rendered) as YamlMap;
      for (final name in <String>['ios', 'android']) {
        final flutter =
            (((parsed['jobs'] as YamlMap)[name] as YamlMap)['steps']
                        as YamlList)
                    .firstWhere(
                      (step) => ((step as YamlMap)['uses'] ?? '')
                          .toString()
                          .startsWith('subosito/flutter-action'),
                    )
                as YamlMap;
        expect((flutter['with'] as YamlMap)['flutter-version'], '3.35.4');
      }
    });

    test('Xcode is selected for the job, not for the machine', () {
      // `xcode-select` would change it for every job after this one.
      final rendered = render(app(), pins: pins);
      final ios =
          ((loadYaml(rendered) as YamlMap)['jobs'] as YamlMap)['ios']
              as YamlMap;
      expect(
        (ios['env'] as YamlMap)['DEVELOPER_DIR'],
        '/Applications/Xcode_16.2.app/Contents/Developer',
      );
      expect(rendered, isNot(contains('xcode-select')));
    });

    test('a self-hosted runner is told the Xcode, and keeps its own', () {
      // Where Xcode lives on that machine is unknown; a wrong path would
      // fail every build.
      final rendered = render(selfHosted(), pins: pins);
      final ios =
          ((loadYaml(rendered) as YamlMap)['jobs'] as YamlMap)['ios']
              as YamlMap;
      expect((ios['env'] as YamlMap).containsKey('DEVELOPER_DIR'), isFalse);
      expect(rendered, contains('last released with Xcode 16.2'));
      expect(rendered, isNot(contains('xcode-select')));
    });

    test('a self-hosted runner is told the Flutter, and installs nothing', () {
      final rendered = render(selfHosted(), pins: pins);
      expect(rendered, contains('3.35.4'));
      expect(rendered, isNot(contains('flutter-action')));
      expect(loadYaml(rendered), isA<YamlMap>());
    });
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
