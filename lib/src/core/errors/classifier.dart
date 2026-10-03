import 'failure_attribution.dart';

/// Whether a diagnosis explains a failure or only accompanies one.
///
/// A field report showed a Ruby end-of-support notice in red beneath a failed
/// lane, as if it were why the lane failed. A warning is true, and worth
/// saying, but it is never the answer to "why did this fail".
enum DiagnosisKind {
  /// Explains why the command failed.
  cause,

  /// Worth knowing, and not why anything failed.
  warning,
}

/// What a failed command meant, and the one thing to do about it.
///
/// The point of this file is that a developer should never have to search for
/// an error message shipway has already seen. Every entry names a real failure,
/// says what actually caused it, and gives a single next action.
class Diagnosis {
  const Diagnosis({
    required this.id,
    required this.summary,
    required this.fix,
    this.docsUrl,
    this.kind = DiagnosisKind.cause,
  });

  /// Stable identifier. Used in tests and `--json`, so it may not be renamed
  /// casually once released.
  final String id;

  /// What went wrong, stated as fact rather than as a guess.
  final String summary;

  /// The single next action. One line, imperative.
  final String fix;

  final String? docsUrl;

  final DiagnosisKind kind;

  bool get isWarning => kind == DiagnosisKind.warning;
}

/// One recognisable failure.
class ErrorSignature {
  const ErrorSignature({
    required this.id,
    required this.patterns,
    required this.summary,
    required this.fix,
    this.docsUrl,
    this.anyOf = false,
    this.kind = DiagnosisKind.cause,
    this.steps,
  });

  final String id;

  /// A warning is looked for in the whole output and reported apart from the
  /// cause; see [DiagnosisKind].
  final DiagnosisKind kind;

  /// The fastlane steps this failure can come from, or null for any.
  ///
  /// Only consulted when the failing step is known. Text alone is not enough
  /// for a failure whose wording is generic: "invalid" and "401" turn up in
  /// logs that have nothing to do with a credential.
  final List<Pattern>? steps;

  /// Whether this failure is plausible for [step]. True when either side has
  /// nothing to say: no [steps] declared, or output without step markers.
  bool plausibleFor(String? step) {
    final allowed = steps;
    if (allowed == null || step == null) return true;
    return allowed.any((pattern) => step.contains(pattern));
  }

  /// Substrings or regexes that identify this failure.
  ///
  /// All must be present by default, which is what makes a signature specific
  /// enough to be worth acting on: `error:` plus a bare noun matches half the
  /// build logs ever written.
  final List<Pattern> patterns;

  /// When true, any one pattern is enough — for a failure that has several
  /// equivalent wordings across tool versions.
  final bool anyOf;

  final String summary;
  final String fix;
  final String? docsUrl;

  bool matches(String output) {
    bool present(Pattern p) => output.contains(p);
    return anyOf ? patterns.any(present) : patterns.every(present);
  }

  Diagnosis get diagnosis => Diagnosis(
    id: id,
    summary: summary,
    fix: fix,
    docsUrl: docsUrl,
    kind: kind,
  );
}

/// What shipway makes of a failed run: where it failed, why, and what else it
/// noticed.
class FailureReport {
  const FailureReport({
    required this.attribution,
    this.causes = const <Diagnosis>[],
    this.warnings = const <Diagnosis>[],
  });

  final FailureAttribution attribution;

  /// Signatures found in the failing region, most specific first. Empty when
  /// shipway does not recognise the failure — which is to be said plainly, not
  /// papered over with the nearest match.
  final List<Diagnosis> causes;

  /// Signatures of kind [DiagnosisKind.warning] found anywhere in the output.
  final List<Diagnosis> warnings;

  /// The most specific cause, or null.
  Diagnosis? get cause => causes.isEmpty ? null : causes.first;

  bool get recognised => causes.isNotEmpty;

  /// Whether any cause carries [id].
  bool hasCause(String id) => causes.any((d) => d.id == id);
}

/// Recognises failures shipway has seen before.
///
/// Ordered most specific first: [classify] returns the first match, so a
/// signature that names an exact cause must precede a broader one that would
/// also match. The ordering is asserted by a test rather than left to care.
abstract final class ErrorClassifier {
  /// Every signature, most specific first.
  ///
  /// Sources are marked: `verified` was reproduced on a real project during the
  /// Phase 2 spike; `catalog` comes from the research document's error table
  /// and has not been reproduced here.
  // `final`, not `const`: a RegExp cannot be a constant, and several
  // signatures need one to cover the wordings a tool has used across versions.
  /// The one failure `shipway release` acts on itself, by refreshing the spec
  /// repo and running the lane once more.
  static const String podSpecsOutOfDate = 'ios.pods.specs_out_of_date';

  static final List<ErrorSignature> signatures = <ErrorSignature>[
    // --- iOS build and export -------------------------------------------

    // verified 2026-09-09
    ErrorSignature(
      id: 'ios.export.no_team',
      patterns: <Pattern>['exportArchive', 'No Team Found in Archive'],
      summary:
          'The archive records no development team, so the export step has '
          'nothing to sign with. An archive built with `--no-codesign` always '
          'looks like this.',
      fix:
          'Pass a team to the export — set signing.ios.team_id in '
          'shipway.yaml, or DEVELOPER_PORTAL_TEAM_ID in the environment.',
    ),

    // verified 2026-09-09
    ErrorSignature(
      id: 'ios.export.xcode_managed_profile',
      patterns: <Pattern>[
        'exportArchive',
        'Xcode managed, but signing settings require a manually managed '
            'profile',
      ],
      summary:
          'The export was given an Xcode-managed provisioning profile while '
          'signing manually. Xcode will not use one that way.',
      fix:
          'Use a match-managed profile — run the `certificates` lane — rather '
          'than an "iOS Team Provisioning Profile".',
    ),

    // verified 2026-09-09: the modern replacement for the plan's exportArchive
    // signature, on any Flutter that resolves through Swift Package Manager.
    ErrorSignature(
      id: 'ios.gym.missing_ephemeral',
      patterns: <Pattern>[
        'Could not resolve package dependencies',
        'Flutter/ephemeral',
      ],
      summary:
          'xcodebuild was run before Flutter had generated '
          'ios/Flutter/ephemeral, which is git-ignored. This is what happens '
          'when fastlane archives a Flutter app itself instead of exporting '
          'the archive `flutter build ipa` produced.',
      fix:
          'Let Flutter build the archive: run `shipway build ios --flavor '
          '<f>`, or add `skip_build_archive: true` to build_app.',
    ),

    // catalog: the CocoaPods-era form of the same mistake.
    ErrorSignature(
      id: 'ios.gym.wraps_flutter_build',
      patterns: <Pattern>[
        'exportArchive',
        "The data couldn't be read because it isn't in the correct format",
      ],
      summary:
          'The archive being exported is not one Flutter produced, so it has '
          'no readable Info.plist. fastlane `gym` archiving a Flutter app is '
          'the usual cause.',
      fix:
          'Let Flutter build the archive: run `shipway build ios --flavor '
          '<f>`, or add `skip_build_archive: true` to build_app.',
    ),

    // verified 2026-09-09: not an error at all, which is why it costs hours.
    ErrorSignature(
      id: 'ios.gym.scheme_prompt',
      patterns: <Pattern>['Ambiguous choice', 'Please choose one of'],
      summary:
          'fastlane is asking which scheme to use and nothing is there to '
          'answer. A non-interactive run hangs here rather than failing.',
      fix: 'Pass `scheme:` to build_app; every generated lane already does.',
    ),

    // verified 2026-09-09
    ErrorSignature(
      id: 'ios.codesign.key_acl',
      patterns: <Pattern>['errSecInternalComponent'],
      summary:
          'codesign could not use the signing key. The keychain is usually '
          'unlocked; what is missing is permission for a non-interactive '
          'process to use that particular key.',
      fix:
          'Grant it once: security set-key-partition-list -S apple-tool:,apple: '
          '-s -k <login password> ~/Library/Keychains/login.keychain-db',
    ),

    // catalog
    ErrorSignature(
      id: 'ios.signing.no_profile',
      patterns: <Pattern>[
        RegExp(r"No profiles for '[^']+' were found|No profile for team"),
      ],
      summary: 'No provisioning profile matches this bundle id and team.',
      fix:
          'Run the `certificates` lane to sync profiles, and check the bundle '
          'id and team_id in shipway.yaml.',
    ),

    // catalog
    ErrorSignature(
      id: 'ios.match.wrong_password',
      patterns: <Pattern>[
        RegExp(r'wrong final block length|Could not decrypt|Couldn.t decrypt'),
      ],
      summary:
          'The match repository could not be decrypted, which means '
          'MATCH_PASSWORD is wrong or unset.',
      fix: 'Re-enter the match passphrase in your .env or keychain entry.',
    ),

    // catalog
    ErrorSignature(
      id: 'ios.signing.needs_team',
      patterns: <Pattern>['requires a development team'],
      summary: 'The Xcode target has no development team set.',
      fix:
          'Set signing.ios.team_id in shipway.yaml and re-run `shipway '
          'generate`.',
    ),

    // catalog
    ErrorSignature(
      id: 'ios.signing.no_identity',
      patterns: <Pattern>['Could not find a matching code signing identity'],
      summary:
          'No signing certificate for this distribution type is in the '
          'keychain.',
      fix:
          'Unlock the keychain and run the `certificates` lane; it needs write '
          'mode once to create a certificate that does not exist yet.',
    ),

    // catalog
    ErrorSignature(
      id: 'ios.xcodeproj.synchronized_groups',
      patterns: <Pattern>['unknown ISA PBXFileSystemSynchronizedRootGroup'],
      summary:
          'The xcodeproj gem is too old for this Xcode project format '
          '(Xcode 16 synchronized folders).',
      fix: 'Update the xcodeproj gem to 1.26.0 or newer.',
    ),

    // --- upload ----------------------------------------------------------

    // catalog
    ErrorSignature(
      id: 'asc.duplicate_build_number',
      patterns: <Pattern>[
        'includes an attribute with a value that has already been used',
      ],
      summary:
          'This build number already exists for this app on App Store '
          'Connect.',
      fix:
          'Increment the build number, or set versioning.strategy to `remote` '
          'so it is taken from the last TestFlight build.',
    ),

    // catalog
    ErrorSignature(
      id: 'play.version_code_used',
      patterns: <Pattern>['Version code has already been used'],
      summary:
          'Google Play requires a strictly increasing version code, and this '
          'one has been uploaded before.',
      fix:
          'Set versioning.strategy to `remote` so the code is taken from the '
          'track, or bump it in pubspec.yaml.',
    ),

    // catalog
    ErrorSignature(
      id: 'play.permission_denied',
      patterns: <Pattern>[
        RegExp(r'does not have permission|\b403\b'),
        RegExp(r'androidpublisher|Google Play|play\.googleapis'),
      ],
      summary: 'The Play service account cannot act on this app.',
      fix:
          'Grant it access in Play Console under Users & Permissions, and '
          'enable the Google Play Android Developer API.',
    ),

    // catalog
    ErrorSignature(
      id: 'firebase.deprecated_token',
      patterns: <Pattern>[
        'App Distribution could not generate credentials from the refresh '
            'token',
      ],
      summary: 'Firebase App Distribution was given the deprecated CI token.',
      fix:
          'Switch to a service-account JSON and set '
          'FIREBASE_SERVICE_ACCOUNT_JSON_PATH.',
    ),

    // catalog: the plugin's own wording, read from 0.10.1. App Distribution
    // answered 403, and the message names no account, project or role.
    ErrorSignature(
      id: 'firebase.permission_denied',
      patterns: <Pattern>[
        'does not have the required permissions on the Firebase project',
      ],
      summary:
          'The Firebase service account may not upload to this app — most '
          'often because it belongs to a different Firebase project.',
      fix:
          'Grant it the Firebase App Distribution Admin role in the app\'s '
          'project, or set flavors.<flavor>.firebase.distribution.'
          'service_account_ref to that project\'s account. `shipway release` '
          'checks this before building.',
    ),

    // catalog: the plugin's own wording, read from 0.10.1.
    ErrorSignature(
      id: 'firebase.app_not_onboarded',
      patterns: <Pattern>['App Distribution could not find your app'],
      summary:
          'App Distribution does not know this app id, or has not been set '
          'up for the project.',
      fix:
          'Press "Get started" on the App Distribution page of the Firebase '
          'console, and check the app id `shipway release` printed.',
    ),

    // catalog: Phase 4 store failures. The stores' own messages are unusually
    // bad at naming what to change, which is the whole reason these exist.
    ErrorSignature(
      id: 'play.app_not_found',
      patterns: <Pattern>[RegExp(r'applicationNotFound|Package not found')],
      summary:
          'Google Play has no app with this package name, or the service '
          'account cannot see it.',
      fix:
          'Check apps.<id>.android.application_id, and that the service '
          'account has been invited to this app in the Play Console.',
    ),

    ErrorSignature(
      id: 'play.unknown_track',
      patterns: <Pattern>[RegExp(r'is not a valid track|Could not find track')],
      summary: 'Play does not know that track name.',
      fix:
          'Use internal, alpha, beta or production, or create the closed '
          'track in the Play Console first.',
    ),

    ErrorSignature(
      id: 'play.rollout_wrong_status',
      patterns: <Pattern>[
        RegExp(
          r'Cannot rollout a release with status|rollout.*not.*inProgress',
        ),
      ],
      summary: 'That release cannot take a user fraction in its current state.',
      fix:
          'Promote it to a track first, or set targets.play.release_status to '
          'inProgress; supply sets the status from the fraction on upload.',
    ),

    // catalog. Scoped twice over after a field report: the old patterns —
    // "App Store Connect API" anywhere plus "invalid" anywhere — matched
    // fastlane's update changelog under a failed `pod install`, and a team
    // rotated a working key. It now needs Apple's own authentication wording,
    // from a step that talks to App Store Connect.
    ErrorSignature(
      id: 'asc.key_rejected',
      patterns: <Pattern>[
        RegExp(
          r'Authentication credentials are missing or invalid|NOT_AUTHORIZED|'
          r'App Store Connect API[^\n]*\b40[13]\b|'
          r'\b40[13]\b[^\n]*App Store Connect API',
        ),
      ],
      steps: <Pattern>[
        RegExp(
          r'^(app_store_connect_api_key|upload_to_testflight|pilot|testflight|'
          r'upload_to_app_store|deliver|appstore|latest_testflight_build_number|'
          r'app_store_build_number|sync_code_signing|match|match_nuke|'
          r'get_certificates|cert|get_provisioning_profile|sigh)$',
        ),
      ],
      summary:
          'App Store Connect refused the API key — wrong, expired, or without '
          'the role this operation needs.',
      fix:
          'Check signing.ios.api_key refs resolve (`shipway secrets check`), '
          'and that the key has App Manager access in App Store Connect.',
    ),

    ErrorSignature(
      id: 'testflight.external_without_groups',
      patterns: <Pattern>['distribute_external', 'groups'],
      summary:
          'External distribution was asked for with no group to distribute '
          'to.',
      fix:
          'Add targets.testflight.groups, or set distribute_external to '
          'false. `shipway release` checks this before building.',
    ),

    // --- CocoaPods -------------------------------------------------------

    // field report 2026-10-01: a self-hosted runner whose spec repo predated
    // the Podfile.lock. `shipway release` retries this one itself.
    ErrorSignature(
      id: podSpecsOutOfDate,
      patterns: <Pattern>[
        RegExp(
          r"CocoaPods's specs repository is too out-of-date|"
          r'CocoaPods could not find compatible versions for pod',
        ),
      ],
      summary:
          "This machine's copy of the CocoaPods specs repository is older than "
          'the pod versions Podfile.lock asks for, so `pod install` cannot '
          'find them.',
      fix:
          'Run `pod install --repo-update` in ios/. If it still cannot '
          'resolve, the Podfile and Podfile.lock disagree: run `pod update '
          '<pod>` and commit the lock file.',
    ),

    // --- toolchain -------------------------------------------------------

    // verified 2026-09-09: Homebrew's fastlane is a shell wrapper that
    // overrides GEM_HOME, so `bundle exec fastlane` silently runs the wrong
    // gems. It looks like a corrupt bundle, which is why it wastes an evening.
    ErrorSignature(
      id: 'ruby.bundle_gem_missing',
      patterns: <Pattern>[
        RegExp(r'Could not find .* in locally installed gems|GemNotFound'),
      ],
      summary:
          'bundler resolved a different Ruby or gem home than the one the '
          'bundle was installed into. A Homebrew-installed fastlane does '
          'exactly this: it is a shell script that overrides GEM_HOME and '
          'GEM_PATH, so `bundle exec fastlane` never reaches the bundled gems.',
      fix:
          'Run fastlane through a binstub that cannot be shadowed: '
          '`bundle binstubs fastlane` then `./bin/fastlane`. If this came '
          'from `shipway release`, run `bundle install` in the platform '
          'directory.',
    ),

    // verified 2026-09-09
    ErrorSignature(
      id: 'ruby.version_solving_failed',
      patterns: <Pattern>['version solving has failed'],
      summary:
          'No set of gem versions satisfies this Gemfile on this Ruby. A gem '
          'pinned above what the Ruby version allows will do it.',
      fix:
          'Check the Ruby the bundle is using (`ruby -v`) against the floor in '
          'the Gemfile, and upgrade Ruby or relax the pin.',
    ),

    // catalog
    ErrorSignature(
      id: 'ruby.too_old_for_fastlane',
      kind: DiagnosisKind.warning,
      patterns: <Pattern>['Support for your Ruby version'],
      summary: 'fastlane is warning that this Ruby is near end of support.',
      fix: 'Upgrade Ruby to 3.3 or newer.',
    ),

    // catalog
    ErrorSignature(
      id: 'gradle.jdk_mismatch',
      patterns: <Pattern>['Unsupported class file major version'],
      summary: 'The JDK in use is newer than this Gradle version understands.',
      fix:
          'Align the JDK with the Gradle version; `shipway doctor` names both.',
    ),

    // --- Flutter flavor wiring -------------------------------------------

    // verified 2026-09-09: the failure that is not one. Flutter exits zero and
    // the missing keys are simply absent from the built Info.plist, so this is
    // only ever caught by reading the build output. A warning for the same
    // reason: the build prints it and carries on, and what fails is a later
    // upload, whose step would otherwise hide it.
    ErrorSignature(
      id: 'ios.flavor.missing_version',
      kind: DiagnosisKind.warning,
      patterns: <Pattern>[
        RegExp(r'Version Number: Missing|Build Number: Missing'),
      ],
      summary:
          'The build produced no CFBundleShortVersionString or CFBundleVersion. '
          'A flavored build configuration that does not inherit '
          'ios/Flutter/Generated.xcconfig loses them, and App Store Connect '
          'rejects the upload.',
      fix:
          'Run `shipway generate`, which points each flavor configuration back '
          "at its build type's xcconfig.",
    ),
  ];

  /// The first signature matching [output], or null. A cause before a
  /// warning.
  static Diagnosis? classify(String? output) {
    final all = classifyAll(output);
    return all.isEmpty ? null : all.first;
  }

  /// Every signature matching [output] as a whole: causes most specific
  /// first, then warnings.
  ///
  /// For output that is not a failed lane — a fragment, or a run that
  /// succeeded and is being read for what it warned about. A failure goes
  /// through [diagnose], which first works out which part of the output the
  /// failure is in.
  static List<Diagnosis> classifyAll(String? output) {
    if (output == null || output.isEmpty) return const <Diagnosis>[];
    return <Diagnosis>[
      ..._matching(output, DiagnosisKind.cause),
      ..._matching(output, DiagnosisKind.warning),
    ];
  }

  /// What a failed run's [output] means.
  ///
  /// Causes are matched against the failing step's output and fastlane's
  /// error line only, and only signatures plausible for that step. Warnings
  /// are matched against everything, since fastlane prints them at the start.
  /// Output with no step markers has no narrower region than itself, so a
  /// plain `flutter build` is classified as it always was.
  static FailureReport diagnose(String? output) {
    final text = output ?? '';
    final attribution = FailureAttribution.parse(text);
    return FailureReport(
      attribution: attribution,
      causes: _matching(
        attribution.region,
        DiagnosisKind.cause,
        step: attribution.failedStep,
      ),
      warnings: _matching(text, DiagnosisKind.warning),
    );
  }

  static List<Diagnosis> _matching(
    String text,
    DiagnosisKind kind, {
    String? step,
  }) {
    if (text.isEmpty) return const <Diagnosis>[];
    return <Diagnosis>[
      for (final signature in signatures)
        if (signature.kind == kind &&
            signature.plausibleFor(step) &&
            signature.matches(text))
          signature.diagnosis,
    ];
  }

  /// Ids, for tests and documentation.
  static List<String> get ids => <String>[for (final s in signatures) s.id];
}
