/// Environment-variable names the generated lanes read.
///
/// Defined once because two things have to agree exactly: the Fastfile that
/// reads a variable, and `shipway secrets check` that verifies it is set. A
/// pre-flight that checks `MATCH_PASSWORD` while the lane reads
/// `MATCH_PASSPHRASE` is worse than no pre-flight at all — it reports green and
/// the build still fails. A shared constant makes them the same string by
/// construction, and a test asserts every name here appears in the rendered
/// output.
///
/// Names taken from a `*_ref` field in `shipway.yaml` are *not* here: those are
/// chosen by the user and read from the config.
abstract final class SecretNames {
  /// The passphrase the match repository is encrypted with.
  static const String matchPassword = 'MATCH_PASSWORD';

  /// Overrides the match repo the config names.
  static const String matchGitUrl = 'MATCH_GIT_URL';
  static const String matchGitBranch = 'MATCH_GIT_BRANCH';

  /// How match authenticates to an **HTTPS** certificates repository:
  /// base64 of `user:token`. Sent as an `Authorization: Basic` header.
  ///
  /// A runner has no credential helper and no SSH agent, so without one of
  /// these two the clone fails with an authentication error that looks like a
  /// signing problem.
  static const String matchGitBasicAuthorization =
      'MATCH_GIT_BASIC_AUTHORIZATION';

  /// How match authenticates to an **SSH** certificates repository: the
  /// private key itself, or a path to it.
  static const String matchGitPrivateKey = 'MATCH_GIT_PRIVATE_KEY';

  /// The Apple Developer Portal team. Not a secret — it appears in every build
  /// log — but it must be resolvable, so it is tracked alongside the rest.
  static const String developerPortalTeamId = 'DEVELOPER_PORTAL_TEAM_ID';

  /// Optional: only needed for the interactive Apple ID login path, which a
  /// runner should never take.
  static const String appleId = 'FASTLANE_APPLE_ID';
  static const String appStoreConnectTeamId = 'APP_STORE_CONNECT_TEAM_ID';

  /// Path to the Play service-account JSON.
  static const String playServiceAccountPath = 'PLAY_SERVICE_ACCOUNT_JSON_PATH';

  /// Path to the Firebase service-account JSON. A file, not the deprecated CI
  /// token, which App Distribution no longer accepts.
  static const String firebaseServiceAccountPath =
      'FIREBASE_SERVICE_ACCOUNT_JSON_PATH';

  /// The *contents* of those two service accounts.
  ///
  /// A runner has no file to point at, so the workflow writes one from a
  /// repository secret and sets the `_PATH` variable to where it wrote it. The
  /// secret you set in GitHub is therefore not the variable the lane reads,
  /// which is exactly the kind of thing nobody works out from a failure
  /// message — so `secrets export` names the one you can actually set.
  static const String playServiceAccountJson = 'PLAY_SERVICE_ACCOUNT_JSON';
  static const String firebaseServiceAccountJson =
      'FIREBASE_SERVICE_ACCOUNT_JSON';

  /// The repository secret that supplies [pathVariable]'s content, if the
  /// variable is one a workflow materialises into a file.
  ///
  /// A variable the config names itself — a flavor's own Firebase account —
  /// follows the same convention: `_PATH` dropped, or `_CONTENT` added.
  static String contentSecretFor(String pathVariable) => switch (pathVariable) {
    playServiceAccountPath => playServiceAccountJson,
    firebaseServiceAccountPath => firebaseServiceAccountJson,
    _ when pathVariable.endsWith('_PATH') => pathVariable.substring(
      0,
      pathVariable.length - '_PATH'.length,
    ),
    _ => '${pathVariable}_CONTENT',
  };

  /// Password for the dedicated keychain shipway creates off-workstation.
  static const String keychainPassword = 'SHIPWAY_KEYCHAIN_PASSWORD';

  /// Every name shipway itself defines, for tests and documentation.
  static const List<String> all = <String>[
    matchPassword,
    matchGitUrl,
    matchGitBranch,
    matchGitBasicAuthorization,
    matchGitPrivateKey,
    developerPortalTeamId,
    appleId,
    appStoreConnectTeamId,
    playServiceAccountPath,
    firebaseServiceAccountPath,
    playServiceAccountJson,
    firebaseServiceAccountJson,
    keychainPassword,
  ];
}
