import 'package:shipway/src/core/config/shipway_config.dart';
import 'package:shipway/src/core/env/run_environment.dart';
import 'package:shipway/src/core/model/android_model.dart';
import 'package:shipway/src/core/secrets/secret_names.dart';
import 'package:shipway/src/generators/android_fastfile_generator.dart';
import 'package:shipway/src/generators/fastfile_generator.dart';
import 'package:shipway/src/generators/generated_file.dart';
import 'package:shipway/src/secrets/secret_requirements.dart';
import 'package:test/test.dart';

ShipwayConfig configFrom(Map<String, dynamic> apps) =>
    ShipwayConfig.fromJson(<String, dynamic>{
      'version': 1,
      'project': <String, dynamic>{'name': 'acme_app'},
      'apps': apps,
    });

/// A config exercising every source of a requirement.
ShipwayConfig get full => configFrom(<String, dynamic>{
  'main': <String, dynamic>{
    'ios': <String, dynamic>{'bundle_id': 'com.acme.app'},
    'android': <String, dynamic>{'application_id': 'com.acme.app'},
    'signing': <String, dynamic>{
      'ios': <String, dynamic>{
        'match_git_url': 'git@github.com:acme/certs.git',
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
      'firebase': <String, dynamic>{'android_app_id_ref': 'FB_ANDROID_APP_ID'},
    },
  },
});

List<SecretRequirement> requirementsFor(
  ShipwayConfig config, {
  RunEnvironment environment = RunEnvironment.workstation,
}) => SecretRequirements.of(config, environment: environment);

Set<String> namesOf(List<SecretRequirement> requirements) =>
    requirements.map((r) => r.name).toSet();

/// Whether [rendered] reads the variable [name], as opposed to merely
/// containing those characters.
///
/// A plain substring test is wrong here and quietly so: `PLAY_SERVICE_ACCOUNT_
/// JSON` is a prefix of `PLAY_SERVICE_ACCOUNT_JSON_PATH`, so one name being
/// present would vouch for another that is not.
bool mentions(String rendered, String name) => RegExp(
  '(?<![A-Za-z0-9_])${RegExp.escape(name)}(?![A-Za-z0-9_])',
).hasMatch(rendered);

void main() {
  group('what a config implies', () {
    test('every *_ref becomes a requirement', () {
      final names = namesOf(requirementsFor(full));
      expect(
        names,
        containsAll(<String>[
          'ASC_KEY_ID',
          'ASC_ISSUER_ID',
          'ASC_KEY_P8_BASE64',
          'ANDROID_KEYSTORE_BASE64',
          'ANDROID_STORE_PASSWORD',
          'ANDROID_KEY_PASSWORD',
          'FB_ANDROID_APP_ID',
        ]),
      );
    });

    test('a match repo requires its passphrase', () {
      expect(
        namesOf(requirementsFor(full)),
        contains(SecretNames.matchPassword),
      );
      // No repo, nothing to decrypt.
      final withoutMatch = configFrom(<String, dynamic>{
        'main': <String, dynamic>{
          'ios': <String, dynamic>{'bundle_id': 'com.acme.app'},
        },
      });
      expect(
        namesOf(requirementsFor(withoutMatch)),
        isNot(contains(SecretNames.matchPassword)),
      );
    });

    test('a configured team id makes the variable optional, not required', () {
      final required = requirementsFor(
        full,
      ).firstWhere((r) => r.name == SecretNames.developerPortalTeamId);
      expect(required.isRequired, isFalse);

      final noTeam = configFrom(<String, dynamic>{
        'main': <String, dynamic>{
          'ios': <String, dynamic>{'bundle_id': 'com.acme.app'},
        },
      });
      expect(
        requirementsFor(noTeam)
            .firstWhere((r) => r.name == SecretNames.developerPortalTeamId)
            .isRequired,
        isTrue,
        reason: 'nothing left to fall back on',
      );
    });

    test('a config declaring nothing needs nothing', () {
      final bare = configFrom(<String, dynamic>{'main': null});
      expect(requirementsFor(bare).where((r) => r.isRequired), isEmpty);
    });

    test('service-account variables are checked as paths', () {
      final play = requirementsFor(
        full,
      ).firstWhere((r) => r.name == SecretNames.playServiceAccountPath);
      expect(play.isPath, isTrue);
    });

    test('every requirement says what wants it', () {
      // The report answers "why do I need this?" without anyone having to
      // read the generator.
      for (final requirement in requirementsFor(full)) {
        expect(
          requirement.wantedBy.trim(),
          isNotEmpty,
          reason: requirement.name,
        );
      }
    });

    test('required entries sort before optional ones', () {
      final requirements = requirementsFor(full);
      final firstOptional = requirements.indexWhere((r) => !r.isRequired);
      final lastRequired = requirements.lastIndexWhere((r) => r.isRequired);
      expect(lastRequired, lessThan(firstOptional));
    });
  });

  group('the environment changes what is needed', () {
    test('interactive-login variables are workstation-only', () {
      expect(namesOf(requirementsFor(full)), contains(SecretNames.appleId));
      // A runner must never take the interactive path, so offering the
      // variable there would be misleading.
      expect(
        namesOf(requirementsFor(full, environment: RunEnvironment.ephemeralCi)),
        isNot(contains(SecretNames.appleId)),
      );
    });

    test('a keychain password is wanted exactly where a keychain is made', () {
      expect(
        namesOf(requirementsFor(full)),
        isNot(contains(SecretNames.keychainPassword)),
      );
      expect(
        namesOf(
          requirementsFor(full, environment: RunEnvironment.persistentRunner),
        ),
        contains(SecretNames.keychainPassword),
      );
    });
  });

  group('the pre-flight and the lanes agree', () {
    // The property that makes `secrets check` worth running: a check that
    // verifies MATCH_PASSWORD while the lane reads MATCH_PASSPHRASE is worse
    // than no check, because it reports green and the build still fails.
    ResolvedApp resolved() => ResolvedApp(
      appId: 'main',
      projectName: 'acme_app',
      androidApplicationId: 'com.acme.app',
      iosBundleId: 'com.acme.app',
      gradleDsl: GradleDsl.kotlin,
      iosTeamId: 'ABCDE12345',
      matchGitUrl: 'git@github.com:acme/certs.git',
      ascApiKey: const AscApiKeyConfig(
        keyIdRef: 'ASC_KEY_ID',
        issuerIdRef: 'ASC_ISSUER_ID',
        p8Ref: 'ASC_KEY_P8_BASE64',
      ),
      play: const PlayTarget(),
      firebase: const FirebaseTarget(androidAppIdRef: 'FB_ANDROID_APP_ID'),
      flavors: const <ResolvedFlavor>[
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

    String lanes() {
      final app = resolved();
      return <String>[
        for (final file in const IosFastfileGenerator().render(app))
          file.contents,
        for (final file in const AndroidFastfileGenerator().render(app))
          file.contents,
      ].join('\n');
    }

    test('every name the lanes read is one the check knows about', () {
      final known = namesOf(
        requirementsFor(full, environment: RunEnvironment.persistentRunner),
      );
      final rendered = lanes();

      for (final name in SecretNames.all) {
        if (!mentions(rendered, name)) continue;
        expect(
          known,
          contains(name),
          reason: '$name is read by a lane but never checked',
        );
      }
    });

    test('the required ones actually appear in the rendered lanes', () {
      final rendered = lanes();
      for (final name in const <String>[
        'ASC_KEY_ID',
        'ASC_ISSUER_ID',
        'ASC_KEY_P8_BASE64',
        'FB_ANDROID_APP_ID',
        SecretNames.matchPassword,
        SecretNames.playServiceAccountPath,
        SecretNames.firebaseServiceAccountPath,
      ]) {
        expect(
          mentions(rendered, name),
          isTrue,
          reason: '$name is checked for nothing',
        );
      }
    });
  });

  group('Firebase credentials per flavor', () {
    ShipwayConfig twoProjects() => configFrom(<String, dynamic>{
      'main': <String, dynamic>{
        'android': <String, dynamic>{'application_id': 'com.acme.app'},
        'flavors': <String, dynamic>{
          'dev': <String, dynamic>{
            'suffix': '.dev',
            'firebase': <String, dynamic>{
              'distribution': <String, dynamic>{
                'service_account_ref': 'FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH',
              },
            },
          },
          'prod': <String, dynamic>{
            'suffix': '',
            'firebase': <String, dynamic>{
              'distribution': <String, dynamic>{
                'service_account_ref':
                    'FIREBASE_PROD_SERVICE_ACCOUNT_JSON_PATH',
                'android_app_id_ref': 'FB_PROD_APP_ID',
              },
            },
          },
        },
        'targets': <String, dynamic>{
          'firebase': <String, dynamic>{
            'groups': <String>['qa'],
          },
        },
      },
    });

    test('shipping one flavor asks for that flavor\'s account only', () {
      final names = namesOf(
        SecretRequirements.of(
          twoProjects(),
          environment: RunEnvironment.workstation,
          flavor: 'dev',
        ),
      );
      expect(names, contains('FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH'));
      expect(names, isNot(contains('FIREBASE_PROD_SERVICE_ACCOUNT_JSON_PATH')));
      expect(names, isNot(contains('FB_PROD_APP_ID')));
      // Nothing uses the default here, so nothing may demand it.
      expect(names, isNot(contains(SecretNames.firebaseServiceAccountPath)));
    });

    test('with no flavor given, every flavor\'s', () {
      expect(
        namesOf(requirementsFor(twoProjects())),
        containsAll(<String>[
          'FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH',
          'FIREBASE_PROD_SERVICE_ACCOUNT_JSON_PATH',
          'FB_PROD_APP_ID',
        ]),
      );
    });

    test('an account is checked as a path and says where it came from', () {
      final dev = requirementsFor(
        twoProjects(),
      ).firstWhere((r) => r.name == 'FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH');
      expect(dev.isPath, isTrue);
      expect(
        dev.wantedBy,
        'flavors.dev.firebase.distribution.service_account_ref',
      );
    });
  });
}
