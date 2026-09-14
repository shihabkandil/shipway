import 'package:shipway/src/core/config/config_loader.dart';
import 'package:shipway/src/core/config/shipway_config.dart';
import 'package:shipway/src/core/model/android_model.dart';
import 'package:shipway/src/generators/resolve_app.dart';
import 'package:shipway/src/generators/workflow_generator.dart';
import 'package:shipway/src/secrets/repository_secrets.dart';
import 'package:shipway/src/secrets/secret_export.dart';
import 'package:test/test.dart';

const String _config = '''
version: 1
project:
  name: acme_app
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
      play:
        track: internal
      firebase:
        android_app_id_ref: FB_ANDROID_APP_ID
''';

/// The repository secrets the generated workflow actually references.
Set<String> workflowSecrets(ShipwayConfig config) {
  final app = ResolveApp.resolve(config, gradleDsl: GradleDsl.kotlin);
  final rendered = const WorkflowGenerator().render(app).single.contents;
  return <String>{
    for (final match in RegExp(
      r'secrets\.([A-Za-z0-9_]+)',
    ).allMatches(rendered))
      match.group(1)!,
  };
}

const String _androidOnly = '''
version: 1
project:
  name: acme_app
apps:
  main:
    path: .
    flavors:
      prod:
        suffix: ""
    signing:
      android:
        keystore_ref: ANDROID_KEYSTORE_BASE64
        key_properties:
          store_password_ref: ANDROID_STORE_PASSWORD
          key_password_ref: ANDROID_KEY_PASSWORD
    targets:
      play:
        track: internal
''';

void main() {
  final config = ConfigLoader.parse(_config);

  test('everything export names is a secret the workflow reads', () {
    // The whole point of export is that following it leaves you with a working
    // pipeline. A name here the workflow never reads is a value someone typed
    // into GitHub for nothing; the reverse is a build that fails at the step
    // the checklist promised to cover.
    final exported = RepositorySecrets.of(config).map((s) => s.name).toSet();

    expect(exported, workflowSecrets(config));
  });

  test('a path-valued variable exports as the secret that supplies it', () {
    // You cannot put a file path in GitHub. The workflow writes the file from a
    // secret and points the variable at it, so the name to set is the content
    // one — which nobody works out from a failure message.
    final exported = RepositorySecrets.of(config).map((s) => s.name);

    expect(exported, contains('FIREBASE_SERVICE_ACCOUNT_JSON'));
    expect(exported, isNot(contains('FIREBASE_SERVICE_ACCOUNT_JSON_PATH')));
  });

  test('it describes the runner, not the machine it runs on', () {
    // Derived for CI whatever this machine is: the workstation list omits the
    // match credential a runner cannot clone without, and adds an interactive
    // Apple ID nobody should put in a repository.
    final exported = RepositorySecrets.of(config).map((s) => s.name);

    expect(exported, contains('MATCH_GIT_BASIC_AUTHORIZATION'));
    expect(exported, isNot(contains('FASTLANE_APPLE_ID')));
  });

  group('the rendered script', () {
    test('gh set lines carry no values', () {
      final rendered = SecretExport.render(
        RepositorySecrets.of(config),
        format: ExportFormat.gh,
      );

      for (final line in rendered.split('\n')) {
        if (!line.startsWith('gh secret set')) continue;
        expect(
          line.split(' '),
          hasLength(4),
          reason: 'a value on the command line would reach the shell history',
        );
      }
    });

    test('every name appears in every format', () {
      final secrets = RepositorySecrets.of(config);
      for (final format in ExportFormat.values) {
        final rendered = SecretExport.render(secrets, format: format);
        for (final secret in secrets) {
          expect(
            rendered,
            contains(secret.name),
            reason: '${secret.name} missing from ${format.name}',
          );
        }
      }
    });

    test('a config needing nothing says so rather than emitting an empty '
        'script', () {
      final rendered = SecretExport.render(
        const <RepositorySecret>[],
        format: ExportFormat.gh,
      );

      expect(rendered, contains('no repository secrets'));
      expect(rendered, isNot(contains('gh secret set')));
    });
  });

  group('a config that ships no iOS app', () {
    final androidOnly = ConfigLoader.parse(_androidOnly);

    test('is not asked for an Apple team id', () {
      // `app.ios` is absent from plainly-iOS configs too, so it cannot be what
      // decides this; arranging no signing and no Apple destination is.
      final exported = RepositorySecrets.of(androidOnly).map((s) => s.name);

      expect(exported, isNot(contains('DEVELOPER_PORTAL_TEAM_ID')));
      expect(exported, contains('ANDROID_KEYSTORE_BASE64'));
    });

    test('gets no iOS job, and export still matches the workflow', () {
      final app = ResolveApp.resolve(androidOnly, gradleDsl: GradleDsl.kotlin);
      final rendered = const WorkflowGenerator().render(app).single.contents;

      expect(rendered, isNot(contains('runs-on: macos')));
      expect(
        RepositorySecrets.of(androidOnly).map((s) => s.name).toSet(),
        workflowSecrets(androidOnly),
      );
    });
  });

  test('a flavor\'s own Firebase account reaches the workflow too', () {
    final perFlavor = ConfigLoader.parse('''
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
          distribution:
            service_account_ref: FIREBASE_DEV_SERVICE_ACCOUNT_JSON_PATH
            android_app_id_ref: FB_DEV_APP_ID
      prod:
        suffix: ""
    targets:
      firebase:
        groups: [qa]
''');
    final exported = RepositorySecrets.of(perFlavor).map((s) => s.name).toSet();

    expect(exported, workflowSecrets(perFlavor));
    // The content secret for a path the config named itself.
    expect(exported, contains('FIREBASE_DEV_SERVICE_ACCOUNT_JSON'));
    expect(exported, contains('FIREBASE_SERVICE_ACCOUNT_JSON'));
    expect(exported, contains('FB_DEV_APP_ID'));
  });
}
