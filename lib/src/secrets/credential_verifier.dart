import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/config/shipway_config.dart';
import '../core/io/http_poster.dart';
import '../core/io/redactor.dart';
import '../core/secrets/secret_names.dart';
import 'jwt_signer.dart';
import 'secret_requirements.dart';
import 'secret_resolver.dart';

/// What a service said about a credential.
enum VerifyOutcome {
  /// The service accepted it.
  ok,

  /// The service accepted the key but refused the request: it is live, and
  /// its role is too narrow. Rotating it would change nothing.
  limited,

  /// The service refused it, or it is not a key at all.
  rejected,

  /// No answer either way: no network, a timeout, a server error. Never a
  /// failure by itself — a check that could not run must not block a release
  /// that would have worked.
  unreachable,

  /// Not asked: a part is missing, or there is nothing cheap and safe to ask.
  skipped;

  /// Whether this should fail `check --verify`.
  bool get fails => this == VerifyOutcome.rejected;
}

/// The answer for one credential. Carries the service's reason and never the
/// credential.
class VerifyResult {
  const VerifyResult({
    required this.credential,
    required this.names,
    required this.outcome,
    required this.detail,
  });

  /// What it is, in words — "App Store Connect API key".
  final String credential;

  /// The variables it is made of.
  final List<String> names;

  final VerifyOutcome outcome;

  /// The service's reason, or what was not checked and where it is.
  final String detail;

  Map<String, Object?> toJson() => <String, Object?>{
    'credential': credential,
    'names': names,
    'outcome': outcome.name,
    'detail': detail,
  };
}

/// Asks each service whether the credential it issued is still good.
///
/// A field report rotated three valid App Store Connect secrets, because the
/// only way to learn whether a key worked was a release run, and after a
/// failed one rotating felt cheaper than finding out. One authenticated,
/// read-only request per credential answers the same question in seconds and
/// changes nothing on the other side.
class CredentialVerifier {
  CredentialVerifier({
    required this.resolver,
    required this.http,
    required this.redactor,
    required this.projectRoot,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final SecretResolver resolver;
  final HttpPoster http;

  /// Every token minted here is registered before it is sent, so one echoed
  /// back in an error body is masked like any other secret.
  final Redactor redactor;

  final String projectRoot;
  final DateTime Function() _clock;

  static final Uri appStoreConnectProbe = Uri.parse(
    'https://api.appstoreconnect.apple.com/v1/apps?limit=1',
  );

  /// Fixed, and never taken from the key file's `token_uri`: a signed
  /// assertion is a credential, and a file should not get to say where it is
  /// sent.
  static final Uri googleTokenEndpoint = Uri.parse(
    'https://oauth2.googleapis.com/token',
  );

  static const String _firebaseScope =
      'https://www.googleapis.com/auth/cloud-platform';
  static const String _playScope =
      'https://www.googleapis.com/auth/androidpublisher';

  static const Set<String> _appleTargets = <String>{'testflight', 'appstore'};

  /// Verifies every credential [config] declares that falls inside [scope].
  Future<List<VerifyResult>> verify(
    ShipwayConfig config, {
    String? appId,
    String? flavor,
    SecretScope scope = SecretScope.everything,
  }) async {
    final app = config.appOrNull(appId ?? config.defaultAppId);
    if (app == null) return const <VerifyResult>[];

    final results = <VerifyResult>[];

    final ios = app.signing.ios;
    if (scope.covers(platform: 'ios', targets: _appleTargets)) {
      final key = ios?.apiKey;
      if (key?.keyIdRef != null &&
          key?.issuerIdRef != null &&
          key?.p8Ref != null) {
        results.add(
          await _appStoreConnect(
            keyIdRef: key!.keyIdRef!,
            issuerIdRef: key.issuerIdRef!,
            p8Ref: key.p8Ref!,
          ),
        );
      }
      if (ios?.matchGitUrl != null) results.add(await _match(ios!));
    }

    final play = app.targets.play;
    if (play != null &&
        scope.covers(platform: 'android', targets: const <String>{'play'})) {
      final variable = play.serviceAccountRef;
      results.add(
        await _google(
          credential: 'Play service account',
          variable: variable ?? SecretNames.playServiceAccountPath,
          // A variable the config names holds the JSON itself; the default
          // one holds a path to it.
          isPath: variable == null,
          scope: _playScope,
          proves:
              'the key is live. Whether it may publish this app is decided '
              'in the Play Console and is not checked here',
        ),
      );
    }

    if (app.targets.firebase != null &&
        scope.covers(
          platform: 'android',
          targets: const <String>{'firebase'},
        )) {
      final flavors = flavor != null
          ? <String>[flavor]
          : (app.flavors.isEmpty ? const <String>[''] : app.flavors.keys);
      final variables = <String>{
        for (final name in flavors) app.firebaseServiceAccountVariable(name),
      };
      for (final variable in variables) {
        results.add(
          await _google(
            credential: 'Firebase service account',
            variable: variable,
            isPath: true,
            scope: _firebaseScope,
            proves:
                'the key is live. Whether it may upload to each app is '
                'checked by `shipway release` pre-flight',
          ),
        );
      }
    }

    return results;
  }

  Future<VerifyResult> _appStoreConnect({
    required String keyIdRef,
    required String issuerIdRef,
    required String p8Ref,
  }) async {
    const credential = 'App Store Connect API key';
    final names = <String>[keyIdRef, issuerIdRef, p8Ref];
    VerifyResult result(VerifyOutcome outcome, String detail) => VerifyResult(
      credential: credential,
      names: names,
      outcome: outcome,
      detail: detail,
    );

    final keyId = await resolver.read(keyIdRef);
    final issuerId = await resolver.read(issuerIdRef);
    final p8 = await resolver.read(p8Ref);
    final unset = <String>[
      if (keyId == null) keyIdRef,
      if (issuerId == null) issuerIdRef,
      if (p8 == null) p8Ref,
    ];
    if (unset.isNotEmpty) {
      return result(
        VerifyOutcome.skipped,
        '${unset.join(', ')} not set, so there is nothing to verify',
      );
    }

    final String token;
    try {
      final issued = _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
      token = JwtSigner.es256(
        header: <String, Object?>{'kid': keyId!.trim(), 'typ': 'JWT'},
        claims: <String, Object?>{
          'iss': issuerId!.trim(),
          // Backdated a little: Apple refuses a token issued in its future,
          // and a laptop clock a few seconds fast is ordinary.
          'iat': issued - 30,
          // Apple's ceiling is twenty minutes. This needs seconds.
          'exp': issued + 300,
          'aud': 'appstoreconnect-v1',
        },
        pem: _pemFrom(p8!, variable: p8Ref),
      );
    } on KeyFormatException catch (e) {
      return result(VerifyOutcome.rejected, '$p8Ref: ${e.message}');
    }
    redactor.register(token);

    final HttpReply reply;
    try {
      reply = await http.get(
        appStoreConnectProbe,
        headers: <String, String>{'Authorization': 'Bearer $token'},
      );
    } on HttpPostException catch (e) {
      return result(VerifyOutcome.unreachable, e.message);
    }

    return switch (reply.statusCode) {
      200 => result(VerifyOutcome.ok, 'App Store Connect accepted the key'),
      401 => result(
        VerifyOutcome.rejected,
        'App Store Connect refused the key (401'
        '${_reason(_appleReason(reply.body))}). Check that the key id and '
        'issuer id belong to this .p8, and that the key has not been revoked',
      ),
      403 => result(
        VerifyOutcome.limited,
        'the key is valid, but its role may not list apps (403'
        '${_reason(_appleReason(reply.body))}). Rotating it will not help; '
        'its access is set in Users and Access',
      ),
      final int status => result(
        VerifyOutcome.unreachable,
        'App Store Connect answered $status, which says nothing about the key',
      ),
    };
  }

  /// The `.p8` as a PEM, whichever way the variable holds it.
  ///
  /// The lane reads base64 of the file, which is the documented form; a raw
  /// PEM and a path to the file are what people have locally before they
  /// encode it, and refusing those would report a good key as a bad one.
  String _pemFrom(String value, {required String variable}) {
    final trimmed = value.trim();
    if (trimmed.contains('-----BEGIN')) return trimmed;

    final file = File(
      p.isAbsolute(trimmed) ? trimmed : p.join(projectRoot, trimmed),
    );
    if (trimmed.length < 1024 && file.existsSync()) {
      final contents = file.readAsStringSync();
      redactor.register(contents);
      return contents;
    }

    try {
      final decoded = utf8.decode(
        base64.decode(trimmed.replaceAll(RegExp(r'\s'), '')),
      );
      if (decoded.contains('-----BEGIN')) {
        redactor.register(decoded);
        return decoded;
      }
    } on FormatException {
      // Falls through to the one message that covers every wrong shape.
    }
    throw const KeyFormatException(
      'is not base64 of a .p8 file. `shipway secrets set <NAME> '
      '--from-file AuthKey_XXXX.p8 --base64` stores it in that form',
    );
  }

  Future<VerifyResult> _google({
    required String credential,
    required String variable,
    required bool isPath,
    required String scope,
    required String proves,
  }) async {
    VerifyResult result(VerifyOutcome outcome, String detail) => VerifyResult(
      credential: credential,
      names: <String>[variable],
      outcome: outcome,
      detail: detail,
    );

    final value = await resolver.read(variable);
    if (value == null) {
      return result(
        VerifyOutcome.skipped,
        '$variable not set, so there is nothing to verify',
      );
    }

    String json = value;
    if (isPath) {
      final file = File(
        p.isAbsolute(value) ? value : p.join(projectRoot, value),
      );
      if (!file.existsSync()) {
        return result(
          VerifyOutcome.skipped,
          '$variable names $value, which does not exist',
        );
      }
      json = file.readAsStringSync();
    }

    final String email;
    final String assertion;
    try {
      final Object? decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('not an object');
      }
      final address = decoded['client_email'];
      final key = decoded['private_key'];
      if (address is! String || key is! String) {
        return result(
          VerifyOutcome.rejected,
          '$variable is not a service-account key: it has no client_email '
          'or private_key. Download a JSON key for the account, not its '
          'details page',
        );
      }
      redactor.register(key);
      email = address;
      final issued = _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
      assertion = JwtSigner.rs256(
        header: <String, Object?>{
          'typ': 'JWT',
          if (decoded['private_key_id'] case final String id) 'kid': id,
        },
        claims: <String, Object?>{
          'iss': address,
          'scope': scope,
          'aud': googleTokenEndpoint.toString(),
          'iat': issued - 30,
          'exp': issued + 300,
        },
        pem: key,
      );
    } on FormatException {
      return result(VerifyOutcome.rejected, '$variable does not hold JSON');
    } on KeyFormatException catch (e) {
      return result(VerifyOutcome.rejected, '$variable: ${e.message}');
    }
    redactor.register(assertion);

    final HttpReply reply;
    try {
      reply = await http.postForm(googleTokenEndpoint, <String, String>{
        'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        'assertion': assertion,
      });
    } on HttpPostException catch (e) {
      return result(VerifyOutcome.unreachable, e.message);
    }

    if (reply.ok) {
      // The token is the point of the exchange and is not kept: registered so
      // that nothing downstream can print it, then dropped.
      redactor.register(_field(reply.body, 'access_token'));
      return result(
        VerifyOutcome.ok,
        '$email — Google issued a token, so $proves',
      );
    }
    if (reply.statusCode >= 400 &&
        reply.statusCode < 500 &&
        reply.statusCode != 429) {
      final reason =
          _field(reply.body, 'error_description') ??
          _field(reply.body, 'error');
      return result(
        VerifyOutcome.rejected,
        'Google refused the key for $email (${reply.statusCode}'
        '${_reason(reason)}). The account, or this key of it, has been '
        'deleted or disabled',
      );
    }
    return result(
      VerifyOutcome.unreachable,
      'Google answered ${reply.statusCode}, which says nothing about the key',
    );
  }

  /// Match: the shape of the clone credential, and nothing that needs the
  /// repository.
  ///
  /// The passphrase can only be proven by decrypting something, which means a
  /// clone; and whether the credential opens the repository is one
  /// `git ls-remote`, which `shipway release` already does before building.
  /// Doing either here would be a second, slower copy of that check.
  Future<VerifyResult> _match(IosSigningConfig ios) async {
    const deferred =
        'repository access and the passphrase are checked by '
        '`shipway release` pre-flight';
    final names = <String>[SecretNames.matchPassword];

    final url = ios.matchGitUrl!;
    final overSsh = url.startsWith('git@') || url.startsWith('ssh://');
    if (!overSsh) {
      final authorization = await resolver.read(
        SecretNames.matchGitBasicAuthorization,
      );
      if (authorization != null) {
        names.add(SecretNames.matchGitBasicAuthorization);
        if (!_isBasicAuthorization(authorization)) {
          return VerifyResult(
            credential: 'match',
            names: names,
            outcome: VerifyOutcome.rejected,
            detail:
                '${SecretNames.matchGitBasicAuthorization} is not base64 of '
                '"user:token", which is the only form match sends. '
                "`printf 'user:token' | base64` produces it",
          );
        }
      }
    }

    return VerifyResult(
      credential: 'match',
      names: names,
      outcome: VerifyOutcome.skipped,
      detail: deferred,
    );
  }

  static bool _isBasicAuthorization(String value) {
    try {
      final decoded = utf8.decode(base64.decode(value.trim()));
      final separator = decoded.indexOf(':');
      return separator > 0 && separator < decoded.trim().length - 1;
    } on FormatException {
      return false;
    }
  }

  /// The first error App Store Connect gave, as `CODE: detail`.
  static String? _appleReason(String body) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return null;
      final errors = decoded['errors'];
      if (errors is! List || errors.isEmpty) return null;
      final first = errors.first;
      if (first is! Map<String, dynamic>) return null;
      final parts = <String>[
        for (final key in <String>['code', 'detail'])
          if (first[key] case final String text) text,
      ];
      return parts.isEmpty ? first['title']?.toString() : parts.join(': ');
    } on FormatException {
      return null;
    }
  }

  static String? _field(String body, String name) {
    try {
      final Object? decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic> && decoded[name] is String) {
        return decoded[name] as String;
      }
    } on FormatException {
      // Not JSON: a proxy's error page, most likely. There is no reason in it.
    }
    return null;
  }

  static String _reason(String? reason) => reason == null ? '' : ', $reason';
}
