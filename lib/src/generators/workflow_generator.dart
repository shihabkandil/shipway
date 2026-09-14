import '../core/env/run_environment.dart';
import '../core/secrets/secret_names.dart';
import '../core/toolchain/fastlane_pins.dart';
import '../version.dart';
import 'generated_file.dart';

/// Writes `.github/workflows/release.yml`.
///
/// The lanes are the product; this removes the last of the guesswork — which
/// secrets to set, how signing material reaches a runner that has none, and in
/// what order to call things. It is generated rather than copied from a README
/// because the `env:` block comes from the same `*_ref` fields the pre-flight
/// checks, so the workflow and `shipway secrets check` cannot disagree.
///
/// Targets GitHub-hosted runners. A self-hosted runner is a different machine
/// shape — persistent, shared, with a keychain that may not be unlocked after a
/// reboot — and shipway does not yet claim to support one.
class WorkflowGenerator extends Generator {
  const WorkflowGenerator();

  @override
  String get name => 'workflow';

  @override
  String get description => 'A GitHub Actions release workflow.';

  static const String path = '.github/workflows/release.yml';

  /// Created once, then left alone.
  ///
  /// By the second run this is somebody's pipeline: they have added a test job,
  /// changed the trigger, pinned a different runner image. Regenerating over
  /// that destroys work no test would catch, and unlike a Fastfile there is no
  /// marked region to preserve.
  @override
  List<GeneratedFile> render(ResolvedApp app) {
    if (!app.hasFlavors) return const <GeneratedFile>[];
    return <GeneratedFile>[
      GeneratedFile.scaffold(
        path: path,
        contents: _render(app),
        description: 'GitHub Actions release workflow (yours to edit)',
      ),
    ];
  }

  /// Never swept: create-once, and the user's after that.
  @override
  bool owns(String path) => false;

  static bool supports(RunEnvironment environment) =>
      environment != RunEnvironment.persistentRunner;

  String _render(ResolvedApp app) {
    final flavors = app.flavors.map((f) => f.name).toList();
    final options = flavors.map((f) => '          - $f').join('\n');

    return '''
# Created once by shipway, then never touched again — this file is yours.
#
# It calls the same lanes you run locally, so green here and green on your
# machine mean the same thing.
#
# Before the first run:  shipway secrets list --env ci
name: Release

on:
  workflow_dispatch:
    inputs:
      flavor:
        description: Which flavor to ship
        required: true
        default: ${flavors.first}
        type: choice
        options:
$options

concurrency:
  # One release at a time. Two uploads racing produce two builds claiming the
  # same version, and the store rejects the second as a duplicate.
  group: release-\${{ github.ref }}
  cancel-in-progress: false

jobs:
${app.shipsIos ? _iosJob(app) : _noIosJobNote()}${_androidJob(app)}''';
  }

  /// A project that configures no iOS signing and no Apple destination has no
  /// iOS job to run. Generating one anyway makes red the repository's normal
  /// state, which is how a failing pipeline stops being read.
  String _noIosJobNote() =>
      '  # No iOS job: this config arranges no iOS signing and no Apple\n'
      '  # destination. Add signing.ios or targets.testflight and re-run\n'
      '  # `shipway generate ci` in a fresh checkout to get one.\n';

  String _iosJob(ResolvedApp app) =>
      '''
  ios:
    runs-on: macos-15
    timeout-minutes: 60
    env:
${_indent(_iosEnv(app), 6)}
    steps:
      - uses: actions/checkout@v4

      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - uses: ruby/setup-ruby@v1
        with:
          # Reads ios/Gemfile, so the fastlane shipway pinned is the one that
          # runs — not whatever the runner image ships.
          ruby-version: '${FastlanePins.rubyFloor}'
          bundler-cache: true
          working-directory: ios

${_installStep()}

      # Fails in seconds naming the missing variable, rather than twenty
      # minutes later at the upload.
      - name: Check credentials
        run: shipway secrets check --env ci

${_matchAccessStep(app)}
      # The `certificates` lane runs `setup_ci` — which gives the runner a
      # throwaway keychain — and then `match` in readonly mode. Readonly is the
      # important half: a build that mints a certificate spends one of the
      # team's limited allowance every time it runs.
      - name: Build and upload
        working-directory: ios
        run: bundle exec fastlane ios beta flavor:\${{ inputs.flavor }}
''';

  /// How match reaches the certificates repository from a runner.
  ///
  /// A runner has no SSH agent and no credential helper, so a private
  /// repository needs an explicit credential. Which kind is decided by the URL
  /// in the config rather than left to the reader, because match treats the two
  /// as mutually exclusive and silently ignores the wrong one.
  String _matchAccessStep(ResolvedApp app) {
    final url = app.matchGitUrl;
    if (url == null) {
      return '      # No match repository configured, so nothing to clone.\n';
    }

    if (url.startsWith('git@') || url.startsWith('ssh://')) {
      return '''
      # An SSH match repository. The key is handed to match directly rather
      # than to an agent, so nothing else on the runner can use it.
      - name: Authorise the certificates repository
        run: |
          mkdir -p ~/.ssh
          ssh-keyscan github.com >> ~/.ssh/known_hosts
        env:
          MATCH_GIT_PRIVATE_KEY: \${{ secrets.${SecretNames.matchGitPrivateKey} }}

''';
    }

    return '''
      # An HTTPS match repository. ${SecretNames.matchGitBasicAuthorization} is
      # base64 of "user:token" — a token with read access to that repository
      # only, not to this one.
      #
      #   printf 'someone:ghp_xxx' | base64

''';
  }

  /// How a runner gets the same shipway that generated this file.
  ///
  /// Pinned to the tag matching the generating version, because a workflow that
  /// installs whatever the default branch holds today can start failing on a
  /// morning nobody touched this repository — and the failure arrives looking
  /// like the app's, in a job that was green yesterday.
  ///
  /// A development build has no tag behind it, so it says so rather than
  /// naming a ref that does not resolve.
  static String _installStep() {
    final ref = packageGitRef;
    final pin = ref == null ? '' : ' --git-ref $ref';
    final note = ref == null
        ? '      # shipway $packageVersion is a development build with no tag, so\n'
              '      # this tracks the default branch. Add `--git-ref v<version>` once\n'
              '      # you are on a released one.\n'
        : '      # Pinned to the version that generated this workflow.\n';
    return '$note'
        '      - name: Install shipway\n'
        '        run: dart pub global activate --source git '
        '$packageRepository$pin';
  }

  String _androidJob(ResolvedApp app) =>
      '''
  android:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    env:
${_indent(_androidEnv(app), 6)}
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'

      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '${FastlanePins.rubyFloor}'
          bundler-cache: true
          working-directory: android

${_installStep()}

${_androidSigningStep(app)}${_playKeyStep(app)}${_firebaseKeyStep(app)}
      - name: Check credentials
        run: shipway secrets check --env ci

      - name: Build and upload
        working-directory: android
        run: bundle exec fastlane android ${_androidLane(app)} flavor:\${{ inputs.flavor }}
''';

  /// Play when it is configured, Firebase when only that is.
  ///
  /// A job that runs the play lane for a project that ships only to Firebase
  /// fails at the Play credential it was never going to have.
  static String _androidLane(ResolvedApp app) =>
      app.play == null && app.firebase != null ? 'firebase' : 'play';

  /// Turns the keystore secret back into the two files Gradle expects.
  ///
  /// A checkout has neither: the keystore is binary and git-ignored, and
  /// `key.properties` holds passwords. Without this step the build fails inside
  /// Gradle on a null signing config, which names nothing a reader could act
  /// on.
  String _androidSigningStep(ResolvedApp app) {
    final signing = app.androidSigning;
    final keystoreRef = signing?.keystoreRef;
    if (keystoreRef == null) {
      return '      # No Android signing configured; Gradle will use its debug key.\n\n';
    }

    final properties = signing!.keyProperties;
    final storePassword =
        properties?.storePasswordRef ?? 'ANDROID_STORE_PASSWORD';
    final keyPassword = properties?.keyPasswordRef ?? 'ANDROID_KEY_PASSWORD';
    final alias = properties?.keyAlias ?? 'upload';

    return '''
      - name: Materialise the signing key
        run: |
          # An absolute path, because `storeFile` in key.properties is resolved
          # relative to android/app and a relative one silently misses.
          echo "\$$keystoreRef" | base64 --decode > "\$GITHUB_WORKSPACE/android/upload-keystore.jks"
          cat > "\$GITHUB_WORKSPACE/android/key.properties" <<PROPERTIES
          storeFile=\$GITHUB_WORKSPACE/android/upload-keystore.jks
          storePassword=\$$storePassword
          keyPassword=\$$keyPassword
          keyAlias=$alias
          PROPERTIES

''';
  }

  /// The Firebase service account is a path as well, and App Distribution no
  /// longer accepts the old CI token, so the file has to be there.
  String _firebaseKeyStep(ResolvedApp app) {
    if (app.firebase == null) return '';
    return '''
      - name: Materialise the Firebase service account
        run: echo "\$${SecretNames.firebaseServiceAccountJson}" > "\$GITHUB_WORKSPACE/firebase.json"
        env:
          ${SecretNames.firebaseServiceAccountJson}: \${{ secrets.${SecretNames.firebaseServiceAccountJson} }}

''';
  }

  /// The Play service account is a *file path*, so the file has to exist.
  ///
  /// Unless the config names its own variable, which holds the JSON itself —
  /// then there is no file to write and the lane reads the secret directly.
  String _playKeyStep(ResolvedApp app) {
    if (app.play == null || app.play!.serviceAccountRef != null) return '';
    return '''
      - name: Materialise the Play service account
        run: echo "\$${SecretNames.playServiceAccountJson}" > "\$GITHUB_WORKSPACE/play.json"
        env:
          ${SecretNames.playServiceAccountJson}: \${{ secrets.${SecretNames.playServiceAccountJson} }}

''';
  }

  List<String> _iosEnv(ResolvedApp app) {
    final lines = <String>[];
    void secret(String name) => lines.add('$name: \${{ secrets.$name }}');

    secret(SecretNames.matchPassword);

    final url = app.matchGitUrl;
    if (url != null) {
      secret(
        url.startsWith('git@') || url.startsWith('ssh://')
            ? SecretNames.matchGitPrivateKey
            : SecretNames.matchGitBasicAuthorization,
      );
    }

    final key = app.ascApiKey;
    for (final ref in <String?>[key?.keyIdRef, key?.issuerIdRef, key?.p8Ref]) {
      if (ref != null) secret(ref);
    }

    final team = app.iosTeamId;
    if (team == null) {
      secret(SecretNames.developerPortalTeamId);
    } else {
      // Not a secret: it is printed in every build log. Writing it plainly is
      // more honest than a repository secret that hides nothing.
      lines.add('${SecretNames.developerPortalTeamId}: $team');
    }
    return lines;
  }

  List<String> _androidEnv(ResolvedApp app) {
    final lines = <String>[];
    void secret(String name) => lines.add('$name: \${{ secrets.$name }}');

    final playRef = app.play?.serviceAccountRef;
    if (playRef != null) {
      // The variable holds the JSON, so it is an ordinary repository secret.
      secret(playRef);
    } else if (app.play != null) {
      // A path, and the step above is what makes the file exist.
      lines.add(
        '${SecretNames.playServiceAccountPath}: '
        '\${{ github.workspace }}/play.json',
      );
    }

    final signing = app.androidSigning;
    if (signing?.keystoreRef != null) secret(signing!.keystoreRef!);
    final properties = signing?.keyProperties;
    for (final ref in <String?>[
      properties?.storePasswordRef,
      properties?.keyPasswordRef,
    ]) {
      if (ref != null) secret(ref);
    }

    if (app.firebase != null) {
      lines.add(
        '${SecretNames.firebaseServiceAccountPath}: '
        '\${{ github.workspace }}/firebase.json',
      );
    }
    final firebase = app.firebase?.androidAppIdRef;
    if (firebase != null) secret(firebase);

    return lines.isEmpty ? <String>['# Nothing configured yet.'] : lines;
  }

  static String _indent(List<String> lines, int spaces) =>
      lines.map((line) => '${' ' * spaces}$line').join('\n');
}
