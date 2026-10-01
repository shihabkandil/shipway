import 'package:shipway/src/core/config/config_loader.dart';
import 'package:shipway/src/core/env/run_environment.dart';
import 'package:shipway/src/core/secrets/secret_names.dart';
import 'package:shipway/src/secrets/repository_secrets.dart';
import 'package:shipway/src/secrets/secret_requirements.dart';
import 'package:test/test.dart';

const String _config = '''
version: 1
project:
  name: acme_app
notify:
  slack_webhook_ref: SLACK_WEBHOOK_URL
apps:
  main:
    path: .
    flavors:
      prod:
        suffix: ""
    signing:
      ios:
        match_git_url: https://github.com/acme/certs.git
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
      play:
        track: internal
      firebase:
        android_app_id_ref: FB_ANDROID_APP_ID
''';

void main() {
  final config = ConfigLoader.parse(_config);

  List<SecretRequirement> scoped({String? platform, String? target}) =>
      SecretRequirements.of(
        config,
        environment: RunEnvironment.ephemeralCi,
        scope: SecretScope.parse(platform: platform, target: target),
      );

  Set<String> required(List<SecretRequirement> requirements) => <String>{
    for (final r in requirements)
      if (r.isRequired) r.name,
  };

  group('an iOS job', () {
    test('requires the App Store Connect key and the match credentials', () {
      expect(required(scoped(platform: 'ios')), <String>{
        'ASC_KEY_ID',
        'ASC_ISSUER_ID',
        'ASC_KEY_P8_BASE64',
        SecretNames.matchPassword,
        SecretNames.matchGitBasicAuthorization,
        SecretNames.developerPortalTeamId,
      });
    });

    test('never mentions an Android credential, required or not', () {
      // The job is not handed them, so listing them as missing is the noise
      // that gets a pre-flight deleted from a workflow.
      final names = scoped(platform: 'ios').map((r) => r.name);

      expect(names, isNot(contains('ANDROID_KEYSTORE_BASE64')));
      expect(names, isNot(contains('ANDROID_STORE_PASSWORD')));
      expect(names, isNot(contains(SecretNames.playServiceAccountPath)));
      expect(names, isNot(contains(SecretNames.firebaseServiceAccountPath)));
      expect(names, isNot(contains('FB_ANDROID_APP_ID')));
    });

    test('keeps the keychain password, which is tied to no destination', () {
      final keychain = scoped(
        platform: 'ios',
      ).firstWhere((r) => r.name == SecretNames.keychainPassword);

      expect(keychain.platform, 'ios');
      expect(keychain.isRequired, isFalse);
    });
  });

  group('an Android job', () {
    test('for firebase requires the keystore and the Firebase account', () {
      expect(
        required(scoped(platform: 'android', target: 'firebase')),
        <String>{
          'ANDROID_KEYSTORE_BASE64',
          'ANDROID_STORE_PASSWORD',
          'ANDROID_KEY_PASSWORD',
          SecretNames.firebaseServiceAccountPath,
          'FB_ANDROID_APP_ID',
        },
      );
    });

    test('never mentions an Apple credential', () {
      final names = scoped(platform: 'android').map((r) => r.name);

      expect(names, isNot(contains('ASC_KEY_ID')));
      expect(names, isNot(contains(SecretNames.matchPassword)));
      expect(names, isNot(contains(SecretNames.developerPortalTeamId)));
      expect(names, isNot(contains(SecretNames.keychainPassword)));
    });

    test('a target alone implies its platform', () {
      expect(
        scoped(target: 'play').map((r) => r.name),
        isNot(contains(SecretNames.keychainPassword)),
      );
      expect(
        required(scoped(target: 'play')),
        contains(SecretNames.playServiceAccountPath),
      );
      expect(
        required(scoped(target: 'play')),
        isNot(contains(SecretNames.firebaseServiceAccountPath)),
      );
    });
  });

  test('what belongs to neither platform shows under both, still optional', () {
    for (final platform in SecretScope.platforms) {
      final slack = scoped(
        platform: platform,
      ).firstWhere((r) => r.name == 'SLACK_WEBHOOK_URL');
      expect(slack.platform, isNull);
      expect(slack.isRequired, isFalse, reason: platform);
    }
  });

  test('with no scope the list is what it always was', () {
    final everything = SecretRequirements.of(
      config,
      environment: RunEnvironment.ephemeralCi,
    ).map((r) => r.name).toSet();

    expect(everything, <String>{
      ...scoped(platform: 'ios').map((r) => r.name),
      ...scoped(platform: 'android').map((r) => r.name),
    }, reason: 'the two platforms partition the list, sharing what is common');
  });

  group('a contradictory scope', () {
    test('a target on the other platform is refused, naming both', () {
      expect(
        () => SecretScope.parse(platform: 'ios', target: 'play'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('play'), contains('Android'), contains('ios')),
          ),
        ),
      );
    });

    test('an unknown name is refused rather than matching nothing', () {
      expect(
        () => SecretScope.parse(platform: 'windows'),
        throwsFormatException,
      );
      expect(() => SecretScope.parse(target: 'huawei'), throwsFormatException);
    });
  });

  test('repository secrets follow the same scope', () {
    final ios = RepositorySecrets.of(
      config,
      scope: const SecretScope(platform: 'ios'),
    ).map((s) => s.name).toSet();
    final android = RepositorySecrets.of(
      config,
      scope: const SecretScope(platform: 'android'),
    ).map((s) => s.name).toSet();

    expect(ios, contains('ASC_KEY_P8_BASE64'));
    expect(ios.intersection(android), isEmpty);
    expect(android, contains(SecretNames.firebaseServiceAccountJson));
    expect(<String>{
      ...ios,
      ...android,
    }, RepositorySecrets.of(config).map((s) => s.name).toSet());
  });
}
