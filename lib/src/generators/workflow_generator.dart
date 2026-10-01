import '../core/config/shipway_config.dart';
import '../core/env/run_environment.dart';
import '../core/fastlane/release_target.dart';
import '../core/secrets/secret_names.dart';
import '../core/toolchain/fastlane_pins.dart';
import '../version.dart';
import 'generated_file.dart';

/// Toolchain versions a workflow should hold the runner to.
///
/// Both optional, and both absent by default: a version nobody recorded is not
/// one to pin. They are passed in rather than read here because a generator is
/// pure — whoever knows what the project was last built with hands it over.
class WorkflowPins {
  const WorkflowPins({this.flutterVersion, this.xcodeVersion});

  /// An exact Flutter version, e.g. `3.35.4`. Null follows the stable channel.
  final String? flutterVersion;

  /// An Xcode version as it appears in the application's name on a runner,
  /// e.g. `16.2` for `/Applications/Xcode_16.2.app`. Null uses the machine's
  /// selected Xcode.
  final String? xcodeVersion;

  bool get isEmpty => flutterVersion == null && xcodeVersion == null;
}

/// Writes `.github/workflows/release.yml`.
///
/// The lanes are the product; this removes the last of the guesswork — which
/// secrets to set, how signing material reaches a runner that has none, and in
/// what order to call things. It is generated rather than copied from a README
/// because the `env:` block comes from the same `*_ref` fields the pre-flight
/// checks, so the workflow and `shipway secrets check` cannot disagree.
///
/// Two shapes, chosen by `ci.runner`. They differ in one idea: a hosted runner
/// is a clean machine that is thrown away, so the workflow installs a
/// toolchain and caches what it can; a self-hosted one is neither, so the
/// workflow installs nothing, caches nothing and asks shipway to leave nothing
/// behind.
///
/// Both call `shipway release` rather than fastlane. Everything that used to
/// be a YAML step and could therefore be got wrong — installing gems, writing
/// each credential file, removing it again, sizing Gradle to the machine — is
/// done by that command, the same way on either kind of runner.
class WorkflowGenerator extends Generator {
  const WorkflowGenerator({this.pins = const WorkflowPins()});

  /// The Flutter and Xcode this workflow pins, when any.
  final WorkflowPins pins;

  /// This generator, pinning [pins].
  WorkflowGenerator withPins(WorkflowPins pins) =>
      WorkflowGenerator(pins: pins);

  @override
  String get name => 'workflow';

  @override
  String get description => 'A GitHub Actions release workflow.';

  static const String path = '.github/workflows/release.yml';

  /// The words a self-hosted workflow's `runs-on` contains and a hosted one's
  /// never does, for telling which kind an existing file is.
  static const String selfHostedLabel = 'self-hosted';

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
        description:
            'GitHub Actions release workflow for '
            '${_selfHosted(app) ? 'self-hosted' : 'GitHub-hosted'} runners '
            '(yours to edit)',
      ),
    ];
  }

  /// Never swept: create-once, and the user's after that.
  @override
  bool owns(String path) => false;

  /// What shipway is told it is running on, by a workflow for [runner].
  ///
  /// Said outright with `--env` rather than left to detection, because the
  /// workflow knows and detection only infers.
  static RunEnvironment environmentFor(CiRunner runner) => switch (runner) {
    CiRunner.hosted => RunEnvironment.ephemeralCi,
    CiRunner.selfHosted => RunEnvironment.persistentRunner,
  };

  /// Which kind of runner an existing workflow was written for.
  static CiRunner runnerOf(String workflow) =>
      workflow.contains(selfHostedLabel)
      ? CiRunner.selfHosted
      : CiRunner.hosted;

  static bool _selfHosted(ResolvedApp app) =>
      app.ciRunner == CiRunner.selfHosted;

  static String _env(ResolvedApp app) => environmentFor(app.ciRunner).flagName;

  String _render(ResolvedApp app) {
    final flavors = app.flavors.map((f) => f.name).toList();
    final options = flavors.map((f) => '          - $f').join('\n');
    final env = _env(app);

    return '''
# Created once by shipway, then never touched again — this file is yours.
#
# It runs `shipway release`, the same command you run locally, so green here
# and green on your machine mean the same thing.
${_selfHosted(app) ? _selfHostedNote() : ''}#
# Before the first run:  shipway secrets list --env $env
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
${app.shipsIos ? _platformInput('ios', 'Release the iOS app') : ''}${_platformInput('android', 'Release the Android app')}
concurrency:
  # One release at a time. Two uploads racing produce two builds claiming the
  # same version, and the store rejects the second as a duplicate.
  group: release-\${{ github.ref }}
  cancel-in-progress: false

jobs:
${app.shipsIos ? _iosJob(app) : _noIosJobNote()}
${_androidJob(app)}''';
  }

  static String _selfHostedNote() =>
      '#\n'
      '# Written for self-hosted runners (`ci.runner: self-hosted`): machines that\n'
      '# keep running, and keep whatever a job leaves on them. So nothing here\n'
      '# installs a toolchain or caches one, and shipway removes every credential\n'
      '# file it writes. The runner needs Flutter, Ruby 3.3 or newer with bundler,\n'
      '# and the platform toolchains already installed — run\n'
      '# `shipway doctor --env persistent` on it to see what is missing.\n';

  /// One checkbox per platform, both ticked.
  ///
  /// A release that always runs both jobs makes shipping an Android fix cost
  /// an iOS build, and an iOS build that fails for its own reasons then paints
  /// the whole run red.
  static String _platformInput(String name, String description) =>
      '''
      $name:
        description: $description
        type: boolean
        default: true
''';

  /// A project that configures no iOS signing and no Apple destination has no
  /// iOS job to run. Generating one anyway makes red the repository's normal
  /// state, which is how a failing pipeline stops being read.
  String _noIosJobNote() =>
      '  # No iOS job: this config arranges no iOS signing and no Apple\n'
      '  # destination. Add signing.ios or targets.testflight and re-run\n'
      '  # `shipway generate ci` in a fresh checkout to get one.\n';

  String _iosJob(ResolvedApp app) {
    final env = _env(app);
    final target = _iosTarget(app);
    final steps = <String>[
      '      - uses: actions/checkout@v4',
      ..._toolchainSteps(app, platform: 'ios'),
      _installStep(app),
      '''
      # Fails in seconds naming the missing variable, rather than twenty
      # minutes later at the upload.
      - name: Check credentials
        run: shipway secrets check --env $env --platform ios''',
      _matchAccessStep(app),
      '''
      # shipway checks the bundle is installed, then runs the ${target.lane} lane. Its
      # `certificates` step gives the runner a throwaway keychain and runs
      # `match` in readonly mode. Readonly is the important half: a build that
      # mints a certificate spends one of the team's limited allowance every
      # time it runs.
      - name: Build and upload
        run: shipway release ios --flavor \${{ inputs.flavor }} --target ${target.id} --env $env''',
      if (_selfHosted(app)) _cleanupStep(),
    ];

    return '''
  ios:
    if: \${{ inputs.ios }}
${_runsOn(app, platform: 'ios')}
    timeout-minutes: 60
    env:
${_indent(<String>[..._xcodeEnv(app), ..._iosEnv(app)], 6)}
    steps:
${steps.join('\n\n')}
''';
  }

  /// TestFlight when it is configured, the App Store when only that is.
  static ReleaseTarget _iosTarget(ResolvedApp app) =>
      app.testflight == null && app.appstore != null
      ? ReleaseTarget.appstore
      : ReleaseTarget.testflight;

  /// Play when it is configured, Firebase when only that is.
  ///
  /// A job that releases to Play for a project that ships only to Firebase
  /// fails at the Play credential it was never going to have.
  static ReleaseTarget _androidTarget(ResolvedApp app) =>
      app.play == null && app.firebase != null
      ? ReleaseTarget.firebase
      : ReleaseTarget.play;

  /// Which machine a job runs on.
  String _runsOn(ResolvedApp app, {required String platform}) {
    if (!_selfHosted(app)) {
      return '    runs-on: ${platform == 'ios' ? 'macos-15' : 'ubuntu-latest'}';
    }
    return platform == 'ios'
        ? '    # The labels your runner was registered with. Edit to match.\n'
              '    runs-on: [self-hosted, macOS]'
        : '    # Any self-hosted runner with a JDK and the Android SDK. Add the\n'
              '    # labels that pick yours out — the Mac above can do both.\n'
              '    runs-on: [self-hosted]';
  }

  /// Everything between the checkout and installing shipway: the toolchain a
  /// clean machine has to be given, and a persistent one must not be.
  ///
  /// This and [_xcodeEnv] are the only places a version of Flutter, Ruby,
  /// Java or Xcode is written into the workflow.
  List<String> _toolchainSteps(ResolvedApp app, {required String platform}) {
    final flutter = pins.flutterVersion;

    if (_selfHosted(app)) {
      // `setup-*` actions download into the runner's tool cache and
      // `bundler-cache` writes a `.bundle/config` pointing at `vendor/bundle`.
      // On a machine that keeps both, each is a second copy of something
      // already installed, and the config outlives the job that wrote it.
      return <String>[
        '      # No setup actions and no caches: this machine already has its\n'
            '      # toolchain, and what a job installs here stays here. '
            '`shipway release`\n'
            '      # runs `bundle install` itself when the bundle is not '
            'satisfied.'
            '${flutter == null ? '' : '\n      #\n'
                      '      # This project was last built with Flutter '
                      '$flutter. The runner\'s should match.'}',
      ];
    }

    final flutterStep =
        '''
      - uses: subosito/flutter-action@v2
        with:
          channel: stable${flutter == null ? '' : "\n          flutter-version: '$flutter'"}
          cache: true''';
    final rubyStep =
        '''
      - uses: ruby/setup-ruby@v1
        with:
          # A Ruby fastlane still supports. Installs $platform/Gemfile's bundle,
          # so the fastlane shipway pinned is the one that runs — not whatever
          # the runner image ships.
          ruby-version: '${FastlanePins.ciRuby}'
          bundler-cache: true
          working-directory: $platform''';

    return <String>[
      if (platform == 'android')
        '''
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17\'''',
      flutterStep,
      rubyStep,
    ];
  }

  /// Selects a pinned Xcode for the job.
  ///
  /// Through `DEVELOPER_DIR` rather than `sudo xcode-select`: the variable
  /// lasts as long as the job, while `xcode-select` changes the machine for
  /// every job after it — harmless on a runner about to be destroyed, and a
  /// surprise for the next project on one that is not.
  List<String> _xcodeEnv(ResolvedApp app) {
    final xcode = pins.xcodeVersion;
    if (xcode == null) return const <String>[];
    return <String>[
      '# The Xcode this project was last built with. The path is how GitHub\'s',
      '# images name it; on your own machine it may differ.',
      'DEVELOPER_DIR: /Applications/Xcode_$xcode.app/Contents/Developer',
    ];
  }

  /// The belt to `shipway release`'s braces, on a machine that keeps running.
  static String _cleanupStep() => '''
      # shipway removes the credential files it writes when the release ends —
      # passed, failed or cancelled. This is for the one ending it cannot
      # handle: the process killed outright.
      - name: Remove credential files
        if: always()
        run: shipway cleanup''';

  /// How match reaches the certificates repository from a runner.
  ///
  /// A runner has no SSH agent and no credential helper, so a private
  /// repository needs an explicit credential. Which kind is decided by the URL
  /// in the config rather than left to the reader, because match treats the two
  /// as mutually exclusive and silently ignores the wrong one.
  String _matchAccessStep(ResolvedApp app) {
    final url = app.matchGitUrl;
    if (url == null) {
      return '      # No match repository configured, so nothing to clone.';
    }

    if (url.startsWith('git@') || url.startsWith('ssh://')) {
      if (_selfHosted(app)) {
        // Appending to known_hosts every run grows a file that belongs to the
        // machine, so here it is said once rather than done each time.
        return '''
      # An SSH match repository. The key in ${SecretNames.matchGitPrivateKey} is handed to
      # match directly rather than to an agent, so nothing else on the runner
      # can use it. The host has to be trusted already — once, on the runner:
      #
      #   ssh-keyscan github.com >> ~/.ssh/known_hosts''';
      }
      return '''
      # An SSH match repository. The key is handed to match directly rather
      # than to an agent, so nothing else on the runner can use it.
      - name: Authorise the certificates repository
        run: |
          mkdir -p ~/.ssh
          ssh-keyscan github.com >> ~/.ssh/known_hosts
        env:
          MATCH_GIT_PRIVATE_KEY: \${{ secrets.${SecretNames.matchGitPrivateKey} }}''';
    }

    return '''
      # An HTTPS match repository. ${SecretNames.matchGitBasicAuthorization} is
      # base64 of "user:token" — a token with read access to that repository
      # only, not to this one.
      #
      #   printf 'someone:ghp_xxx' | base64''';
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
  static String _installStep(ResolvedApp app) {
    final ref = packageGitRef;
    final pin = ref == null ? '' : ' --git-ref $ref';
    final note = ref == null
        ? '      # shipway $packageVersion is a development build with no tag, so\n'
              '      # this tracks the default branch. Add `--git-ref v<version>` once\n'
              '      # you are on a released one.\n'
        : '      # Pinned to the version that generated this workflow.\n';
    const activate = 'dart pub global activate --source git';

    if (!_selfHosted(app)) {
      return '$note'
          '      - name: Install shipway\n'
          '        run: $activate $packageRepository$pin';
    }
    // flutter-action puts pub's executables on PATH. Without it nothing does,
    // and the next step fails on `shipway: command not found`.
    return '$note'
        '      - name: Install shipway\n'
        '        run: |\n'
        '          $activate $packageRepository$pin\n'
        '          echo "\${PUB_CACHE:-\$HOME/.pub-cache}/bin" >> "\$GITHUB_PATH"';
  }

  String _androidJob(ResolvedApp app) {
    final env = _env(app);
    final target = _androidTarget(app);
    final steps = <String>[
      '      - uses: actions/checkout@v4',
      ..._toolchainSteps(app, platform: 'android'),
      _installStep(app),
      '''
      - name: Check credentials
        run: shipway secrets check --env $env --platform android''',
      '''
      # shipway writes the keystore, key.properties and each service account
      # from the secrets above into files for this run, limits Gradle to what
      # the machine has, runs the ${target.lane} lane, and removes the files again.
      - name: Build and upload
        run: shipway release android --flavor \${{ inputs.flavor }} --target ${target.id} --env $env''',
      if (_selfHosted(app)) _cleanupStep(),
    ];

    return '''
  android:
    if: \${{ inputs.android }}
${_runsOn(app, platform: 'android')}
    timeout-minutes: 45
    env:
${_indent(_androidEnv(app), 6)}
    steps:
${steps.join('\n\n')}
''';
  }

  /// One per distinct variable: flavors in separate Firebase projects name
  /// separate accounts, and the runner may be asked to ship any flavor.
  static Set<String> _firebaseAccounts(ResolvedApp app) => <String>{
    for (final flavor in app.flavors) flavor.firebaseServiceAccountVariable,
  };

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

    /// A variable the lane reads as a *path*. What a repository can hold is
    /// the file's content, so that is what is passed, and `shipway release`
    /// writes the file and sets the path for as long as the lane runs.
    void file(String pathVariable) {
      lines.add(
        '# Written to a file for the run; the lane reads $pathVariable.',
      );
      secret(SecretNames.contentSecretFor(pathVariable));
    }

    final playRef = app.play?.serviceAccountRef;
    if (playRef != null) {
      // The variable holds the JSON, so it is an ordinary repository secret.
      secret(playRef);
    } else if (app.play != null) {
      file(SecretNames.playServiceAccountPath);
    }

    final signing = app.androidSigning;
    final keystoreRef = signing?.keystoreRef;
    if (keystoreRef != null) {
      lines.add(
        '# The keystore, base64. Decoded for the run, beside a key.properties',
      );
      lines.add('# built from the two passwords.');
      secret(keystoreRef);
      final properties = signing?.keyProperties;
      // The names key.properties is built from when the config names none.
      secret(
        properties?.storePasswordRef ?? SecretNames.androidStorePasswordDefault,
      );
      secret(
        properties?.keyPasswordRef ?? SecretNames.androidKeyPasswordDefault,
      );
    }

    if (app.firebase != null) {
      _firebaseAccounts(app).forEach(file);
      for (final variable in <String>{
        for (final flavor in app.flavors)
          if (app.firebaseAndroidAppIdVariable(flavor) case final name?) name,
      }) {
        secret(variable);
      }
    }

    return lines.isEmpty ? <String>['# Nothing configured yet.'] : lines;
  }

  static String _indent(List<String> lines, int spaces) =>
      lines.map((line) => '${' ' * spaces}$line').join('\n');
}
