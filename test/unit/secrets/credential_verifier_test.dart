import 'dart:convert';

import 'package:shipway/src/core/config/config_loader.dart';
import 'package:shipway/src/core/env/host_platform.dart';
import 'package:shipway/src/core/env/run_environment.dart';
import 'package:shipway/src/core/io/http_poster.dart';
import 'package:shipway/src/core/io/redactor.dart';
import 'package:shipway/src/secrets/credential_verifier.dart';
import 'package:shipway/src/secrets/secret_requirements.dart';
import 'package:shipway/src/secrets/secret_resolver.dart';
import 'package:test/test.dart';

import '../../support/fixture_project.dart';
import '../../support/recording_http_poster.dart';
import '../../support/recording_process_runner.dart';
import 'signing_keys.dart';

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
        team_id: ABCDE12345
        api_key:
          key_id_ref: ASC_KEY_ID
          issuer_id_ref: ASC_ISSUER_ID
          p8_ref: ASC_KEY_P8_BASE64
    targets:
      play:
        track: internal
      firebase:
        android_app_id_ref: FB_ANDROID_APP_ID
''';

String _serviceAccount({String? key}) => jsonEncode(<String, String>{
  'type': 'service_account',
  'client_email': 'ci@acme.iam.gserviceaccount.com',
  'private_key_id': 'abc123',
  'private_key': key ?? rsaPkcs8Pem,
});

Map<String, dynamic> _claims(String jwt) =>
    jsonDecode(
          utf8.decode(base64Url.decode(base64Url.normalize(jwt.split('.')[1]))),
        )
        as Map<String, dynamic>;

void main() {
  late FixtureProject project;
  late RecordingHttpPoster http;
  late Redactor redactor;

  setUp(() async {
    project = await FixtureProject.create();
    addTearDown(project.dispose);
    http = RecordingHttpPoster();
    redactor = Redactor();
  });

  Future<List<VerifyResult>> verify(
    Map<String, String> environment, {
    SecretScope scope = SecretScope.everything,
  }) => CredentialVerifier(
    resolver: SecretResolver(
      environment: RunEnvironment.ephemeralCi,
      projectRoot: project.path,
      runner: RecordingProcessRunner(),
      redactor: redactor,
      processEnvironment: environment,
      host: HostPlatform.linux,
    ),
    http: http,
    redactor: redactor,
    projectRoot: project.path,
    clock: () => DateTime.utc(2026, 10, 1, 12),
  ).verify(ConfigLoader.parse(_config), scope: scope);

  VerifyResult named(List<VerifyResult> results, String credential) =>
      results.firstWhere((r) => r.credential == credential);

  group('App Store Connect', () {
    const scope = SecretScope(platform: 'ios');
    final key = <String, String>{
      'ASC_KEY_ID': 'KEY123',
      'ASC_ISSUER_ID': '69a6de7f-0000-47e3-e053-5b8c7c11a4d1',
      'ASC_KEY_P8_BASE64': base64.encode(utf8.encode(ecPkcs8Pem)),
    };

    test(
      'a 200 is a valid key, asked for with a signed bearer token',
      () async {
        http.replies.add(const HttpReply(statusCode: 200, body: '{"data":[]}'));

        final result = named(
          await verify(key, scope: scope),
          'App Store Connect API key',
        );

        expect(result.outcome, VerifyOutcome.ok);
        final request = http.requests.single;
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://api.appstoreconnect.apple.com/v1/apps?limit=1',
        );
        final token = request.headers!['Authorization']!.substring(
          'Bearer '.length,
        );
        final claims = _claims(token);
        expect(claims['iss'], '69a6de7f-0000-47e3-e053-5b8c7c11a4d1');
        expect(claims['aud'], 'appstoreconnect-v1');
        // Apple refuses anything living longer than twenty minutes.
        expect(
          (claims['exp'] as int) - (claims['iat'] as int),
          lessThan(20 * 60),
        );
        final header =
            jsonDecode(
                  utf8.decode(
                    base64Url.decode(base64Url.normalize(token.split('.')[0])),
                  ),
                )
                as Map<String, dynamic>;
        expect(header['alg'], 'ES256');
        expect(header['kid'], 'KEY123');
        expect(redactor.redact('sent $token'), isNot(contains(token)));
      },
    );

    test('a 401 is a rejected key, with the reason Apple gave', () async {
      http.replies.add(
        const HttpReply(
          statusCode: 401,
          body:
              '{"errors":[{"status":"401","code":"NOT_AUTHORIZED",'
              '"title":"Authentication credentials are missing or invalid.",'
              '"detail":"Provide a properly configured and signed bearer '
              'token"}]}',
        ),
      );

      final result = named(
        await verify(key, scope: scope),
        'App Store Connect API key',
      );

      expect(result.outcome, VerifyOutcome.rejected);
      expect(result.outcome.fails, isTrue);
      expect(result.detail, contains('NOT_AUTHORIZED'));
      expect(result.detail, contains('properly configured'));
    });

    test('a 403 is a valid key that must not be rotated', () async {
      // The report this exists for: three good secrets replaced because a
      // failure looked like a bad key.
      http.replies.add(
        const HttpReply(
          statusCode: 403,
          body: '{"errors":[{"code":"FORBIDDEN_ERROR","detail":"No access"}]}',
        ),
      );

      final result = named(
        await verify(key, scope: scope),
        'App Store Connect API key',
      );

      expect(result.outcome, VerifyOutcome.limited);
      expect(result.outcome.fails, isFalse);
      expect(result.detail, contains('valid'));
    });

    test('no network is "could not check", and not a failure', () async {
      http.replies.add(const HttpPostException('could not reach apple'));

      final result = named(
        await verify(key, scope: scope),
        'App Store Connect API key',
      );

      expect(result.outcome, VerifyOutcome.unreachable);
      expect(result.outcome.fails, isFalse);
    });

    test('a server error says nothing about the key', () async {
      http.replies.add(const HttpReply(statusCode: 503, body: ''));

      final result = named(
        await verify(key, scope: scope),
        'App Store Connect API key',
      );

      expect(result.outcome, VerifyOutcome.unreachable);
    });

    test('a raw PEM is accepted as well as base64 of one', () async {
      http.replies.add(const HttpReply(statusCode: 200, body: '{}'));

      final result = named(
        await verify(<String, String>{
          ...key,
          'ASC_KEY_P8_BASE64': ecPkcs8Pem,
        }, scope: scope),
        'App Store Connect API key',
      );

      expect(result.outcome, VerifyOutcome.ok);
    });

    test('a value that is no key is rejected without a request', () async {
      final result = named(
        await verify(<String, String>{
          ...key,
          'ASC_KEY_P8_BASE64': 'bm90IGEga2V5',
        }, scope: scope),
        'App Store Connect API key',
      );

      expect(result.outcome, VerifyOutcome.rejected);
      expect(result.detail, contains('ASC_KEY_P8_BASE64'));
      expect(http.requests, isEmpty);
    });

    test('a missing part is not checked, and says which', () async {
      final result = named(
        await verify(<String, String>{'ASC_KEY_ID': 'KEY123'}, scope: scope),
        'App Store Connect API key',
      );

      expect(result.outcome, VerifyOutcome.skipped);
      expect(result.detail, contains('ASC_ISSUER_ID'));
      expect(http.requests, isEmpty);
    });
  });

  group('Google service accounts', () {
    const firebase = SecretScope(platform: 'android', target: 'firebase');

    test('a token means the key is live', () async {
      project.write('firebase.json', _serviceAccount());
      http.replies.add(
        const HttpReply(
          statusCode: 200,
          body: '{"access_token":"ya29.live-token-value","expires_in":3599}',
        ),
      );

      final result = (await verify(<String, String>{
        'FIREBASE_SERVICE_ACCOUNT_JSON_PATH': 'firebase.json',
      }, scope: firebase)).single;

      expect(result.credential, 'Firebase service account');
      expect(result.outcome, VerifyOutcome.ok);
      expect(result.detail, contains('ci@acme.iam.gserviceaccount.com'));
      // Never printed, and masked if anything else were to.
      expect(result.detail, isNot(contains('ya29')));
      expect(redactor.redact('ya29.live-token-value'), isNot(contains('ya29')));

      final request = http.requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://oauth2.googleapis.com/token');
      expect(
        request.fields!['grant_type'],
        'urn:ietf:params:oauth:grant-type:jwt-bearer',
      );
      final claims = _claims(request.fields!['assertion']!);
      expect(claims['iss'], 'ci@acme.iam.gserviceaccount.com');
      expect(claims['aud'], 'https://oauth2.googleapis.com/token');
      expect(claims['scope'], contains('cloud-platform'));
    });

    test('invalid_grant is a rejected key, with Google\'s reason', () async {
      project.write('firebase.json', _serviceAccount());
      http.replies.add(
        const HttpReply(
          statusCode: 400,
          body:
              '{"error":"invalid_grant",'
              '"error_description":"Invalid JWT Signature."}',
        ),
      );

      final result = (await verify(<String, String>{
        'FIREBASE_SERVICE_ACCOUNT_JSON_PATH': 'firebase.json',
      }, scope: firebase)).single;

      expect(result.outcome, VerifyOutcome.rejected);
      expect(result.detail, contains('Invalid JWT Signature.'));
    });

    test('a 503 or no network cannot fail the check', () async {
      project.write('firebase.json', _serviceAccount());
      http.replies
        ..add(const HttpReply(statusCode: 503, body: 'unavailable'))
        ..add(const HttpPostException('could not reach oauth2.googleapis.com'));

      for (var i = 0; i < 2; i++) {
        final result = (await verify(<String, String>{
          'FIREBASE_SERVICE_ACCOUNT_JSON_PATH': 'firebase.json',
        }, scope: firebase)).single;
        expect(result.outcome, VerifyOutcome.unreachable);
        expect(result.outcome.fails, isFalse);
      }
    });

    test('the assertion goes to Google whatever the file says', () async {
      // A signed assertion is a credential. `token_uri` is a field in a file
      // someone handed over, and must not get to say where it is sent.
      project.write(
        'firebase.json',
        jsonEncode(<String, String>{
          'client_email': 'ci@acme.iam.gserviceaccount.com',
          'private_key': rsaPkcs8Pem,
          'token_uri': 'https://evil.example/token',
        }),
      );
      http.replies.add(
        const HttpReply(statusCode: 200, body: '{"access_token":"ya29.x"}'),
      );

      await verify(<String, String>{
        'FIREBASE_SERVICE_ACCOUNT_JSON_PATH': 'firebase.json',
      }, scope: firebase);

      expect(http.requests.single.url.host, 'oauth2.googleapis.com');
    });

    test('a file that is not a key is rejected without a request', () async {
      project.write('firebase.json', '{"project_id":"acme"}');

      final result = (await verify(<String, String>{
        'FIREBASE_SERVICE_ACCOUNT_JSON_PATH': 'firebase.json',
      }, scope: firebase)).single;

      expect(result.outcome, VerifyOutcome.rejected);
      expect(result.detail, contains('private_key'));
      expect(http.requests, isEmpty);
    });

    test('Play uses its own variable and the androidpublisher scope', () async {
      project.write('play.json', _serviceAccount());
      http.replies.add(
        const HttpReply(statusCode: 200, body: '{"access_token":"ya29.y"}'),
      );

      final result = (await verify(<String, String>{
        'PLAY_SERVICE_ACCOUNT_JSON_PATH': 'play.json',
      }, scope: const SecretScope(target: 'play'))).single;

      expect(result.credential, 'Play service account');
      expect(result.outcome, VerifyOutcome.ok);
      expect(
        _claims(http.requests.single.fields!['assertion']!)['scope'],
        contains('androidpublisher'),
      );
    });
  });

  group('match', () {
    const scope = SecretScope(platform: 'ios');

    test('says where repository access is checked instead', () async {
      final result = named(
        await verify(<String, String>{}, scope: scope),
        'match',
      );

      expect(result.outcome, VerifyOutcome.skipped);
      expect(result.detail, contains('`shipway release` pre-flight'));
      expect(http.requests, isEmpty);
    });

    test('a basic authorization that is not user:token is rejected', () async {
      final result = named(
        await verify(<String, String>{
          'MATCH_GIT_BASIC_AUTHORIZATION': 'ghp_a_bare_token',
        }, scope: scope),
        'match',
      );

      expect(result.outcome, VerifyOutcome.rejected);
      expect(result.detail, contains('user:token'));
    });

    test('a well-formed one passes on to the pre-flight', () async {
      final result = named(
        await verify(<String, String>{
          'MATCH_GIT_BASIC_AUTHORIZATION': base64.encode(
            utf8.encode('someone:ghp_token'),
          ),
        }, scope: scope),
        'match',
      );

      expect(result.outcome, VerifyOutcome.skipped);
    });
  });

  group('scope', () {
    test('an iOS check asks nothing of Google', () async {
      final results = await verify(
        <String, String>{},
        scope: const SecretScope(platform: 'ios'),
      );

      expect(results.map((r) => r.credential), <String>[
        'App Store Connect API key',
        'match',
      ]);
    });

    test('an Android check asks nothing of Apple', () async {
      final results = await verify(
        <String, String>{},
        scope: const SecretScope(platform: 'android'),
      );

      expect(results.map((r) => r.credential), <String>[
        'Play service account',
        'Firebase service account',
      ]);
    });
  });
}
