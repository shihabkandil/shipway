import '../core/config/shipway_config.dart';
import '../core/secrets/secret_names.dart';
import 'fastlane_ruby.dart';
import 'version_resolver.dart';
import 'generated_file.dart';

/// Writes `ios/fastlane/Fastfile`.
///
/// Whole-file managed. A Fastfile that was already in the project is never
/// touched — the writer refuses on ownership, and `shipway adopt` is the only
/// way to hand one over — because a real Fastfile encodes a team's release
/// process and regenerating over it destroys work no test would catch.
///
/// Every value a lane needs at runtime is read from `ENV`. Nothing that could
/// be a credential is ever written into this file, and a golden test greps the
/// rendered output to keep it that way.
class IosFastfileGenerator extends Generator {
  const IosFastfileGenerator();

  @override
  String get name => 'ios-fastfile';

  @override
  String get description => 'The iOS release lanes.';

  static const String path = 'ios/fastlane/Fastfile';

  /// Where `flutter build ipa` leaves the archive, relative to the project.
  static const String archivePath = 'build/ios/archive/Runner.xcarchive';

  /// Where both export shapes are told to put the `.ipa`.
  static const String ipaDirectory = 'build/ios/ipa';

  /// Where `changelog_from: file` looks, relative to the project root.
  static const String changelogFileName = FastlaneRuby.changelogFileName;

  @override
  List<GeneratedFile> render(ResolvedApp app) {
    if (!app.hasFlavors) return const <GeneratedFile>[];
    return <GeneratedFile>[
      GeneratedFile.full(
        path: path,
        contents: _render(app),
        description: 'iOS build and release lanes (${app.iosExport.name})',
      ),
    ];
  }

  String _render(ResolvedApp app) => <String>[
    FastlaneRuby.header('ios'),
    FastlaneRuby.flavorTable(
      app,
      (flavor) => <String, String>{'bundle_id': flavor.iosBundleId ?? ''},
    ),
    FastlaneRuby.helpers(),
    FastlaneRuby.flutterBuild(),
    VersionResolver.render(
      strategy: app.versioning.strategy,
      syncIosAndroid: app.versioning.syncIosAndroid,
      platform: 'ios',
    ),
    _ipaHelper(),
    _changelogHelper(app),
    'platform :ios do',
    _certificatesLane(app),
    _buildLane(app),
    _testflightLane(app),
    if (app.appstore != null) _appStoreLane(app),
    'end',
  ].join('\n');

  /// Finds the freshly exported `.ipa` without ever constructing its name.
  ///
  /// The filename follows `CFBundleName`, which shipway does not vary per
  /// flavor — only `CFBundleDisplayName` is per-flavor — so every flavor of a
  /// project exports to the *same* name and overwrites the last one. Picking
  /// any match would therefore happily upload the previous flavor's build, so
  /// the lane takes only a file written after its own build started.
  String _ipaHelper() =>
      '''
def exported_ipa(since)
  found = Dir[root_path("$ipaDirectory", "*.ipa")]
          .select { |f| File.mtime(f) >= since }
          .max_by { |f| File.mtime(f) }
  if found.nil?
    UI.user_error!("No .ipa written to $ipaDirectory by this build. The export " \\
                   "step produced nothing.")
  end
  found
end
''';

  String _certificatesLane(ResolvedApp app) {
    final key = app.ascApiKey;
    // All three refs or none: a half-configured key cannot authenticate, and
    // rendering `ENV.fetch("null")` would fail at lane runtime with nothing
    // pointing back at the config that caused it.
    final keyIdRef = key?.keyIdRef;
    final issuerIdRef = key?.issuerIdRef;
    final p8Ref = key?.p8Ref;
    final complete = keyIdRef != null && issuerIdRef != null && p8Ref != null;
    final auth = !complete
        ? '''
  # No App Store Connect key is configured, so match authenticates
  # interactively. Add signing.ios.api_key to shipway.yaml for unattended runs.
  private_lane :asc_api_key do
    nil
  end
'''
        : '''
  private_lane :asc_api_key do
    require_env("$keyIdRef", "$issuerIdRef", "$p8Ref")

    app_store_connect_api_key(
      key_id: ENV.fetch("$keyIdRef"),
      issuer_id: ENV.fetch("$issuerIdRef"),
      key_content: ENV.fetch("$p8Ref"),
      is_key_content_base64: true,
      in_house: false
    )
  end
''';

    return '''
$auth
  desc "Sync signing certificates and profiles via match"
  lane :certificates do |options|
    require_env("${SecretNames.matchPassword}")
    setup_ci if is_ci

    sync_code_signing(
      type: "appstore",
      # readonly by default: a day-to-day build must never mint a new
      # certificate, which is a limited and shared resource.
      readonly: options.fetch(:readonly, true),
      app_identifier: FLAVORS.values.map { |f| f[:bundle_id] }.reject(&:empty?),
      api_key: asc_api_key
    )
  end
''';
  }

  String _buildLane(ResolvedApp app) => switch (app.iosExport) {
    IosExport.gym => _buildLaneGym(app.iosTeamId),
    IosExport.flutter => _buildLaneFlutter(),
  };

  /// `flutter build ipa --no-codesign` archives, `gym` exports.
  ///
  /// `--no-codesign` rather than letting Flutter export and then exporting
  /// again: the second export is the one that counts, and the first costs a
  /// signing round trip and fails outright when no distribution profile is
  /// installed yet. Verified that gym signs an unsigned archive correctly.
  String _buildLaneGym(String? teamId) =>
      '''
  desc "Build a signed IPA for a flavor"
  lane :build_ipa do |options|
    flavor = require_flavor(options)
    config = flavor_config(flavor)

    profiles = Actions.lane_context[SharedValues::MATCH_PROVISIONING_PROFILE_MAPPING] || {}
    profile = profiles[config[:bundle_id]]
    UI.user_error!("No profile synced for #{config[:bundle_id]}; run the certificates lane first.") if profile.to_s.empty?

    started = Time.now
    # Archive only. gym does the signing on export, so signing here would be
    # thrown away.
    flutter_build(
      type: "ipa",
      flavor: flavor,
      entrypoint: config[:entrypoint],
      version: options[:version_name],
      build: options[:build_number],
      extra: ["--no-codesign"]
    )

    build_app(
      # The whole point: gym exports the archive Flutter made and does not try
      # to make one. A gym that archives a Flutter app either fails on the
      # git-ignored ios/Flutter/ephemeral, or silently builds whatever
      # Generated.xcconfig was left pointing at.
      skip_build_archive: true,
      archive_path: root_path("$archivePath"),
      output_directory: root_path("$ipaDirectory"),
      # Required even when only exporting: without it gym prompts for a scheme
      # and a non-interactive run hangs forever.
      scheme: flavor,
      # Also required, and only for this shape: an archive built with
      # --no-codesign records an empty Team, so export has none to infer and
      # fails with "exportArchive No Team Found in Archive".
      export_team_id: ${teamId == null ? 'ENV.fetch("${SecretNames.developerPortalTeamId}")' : 'ENV.fetch("${SecretNames.developerPortalTeamId}", "$teamId")'},
      export_method: "app-store",
      export_options: {
        provisioningProfiles: { config[:bundle_id] => profile }
      }
    )

    exported_ipa(started)
  end
''';

  /// `flutter build ipa --export-options-plist` does both legs.
  String _buildLaneFlutter() => '''
  desc "Build a signed IPA for a flavor"
  lane :build_ipa do |options|
    flavor = require_flavor(options)
    config = flavor_config(flavor)

    plist = root_path("ios", "ExportOptions-#{flavor}.plist")
    UI.user_error!("Missing #{plist}; run `shipway generate`.") unless File.exist?(plist)

    started = Time.now
    # Flutter archives and exports in one command, running the same
    # `xcodebuild -exportArchive` gym would.
    flutter_build(
      type: "ipa",
      flavor: flavor,
      entrypoint: config[:entrypoint],
      version: options[:version_name],
      build: options[:build_number],
      extra: ["--export-options-plist=#{plist.shellescape}"]
    )

    exported_ipa(started)
  end
''';

  /// Tester groups, only when the config names any — an empty `groups:` makes
  /// `pilot` distribute to nobody rather than to the default set.
  static String _quoted(String value) => '"$value"';

  static String _groups(ResolvedApp app) {
    final groups = app.testflight?.groups ?? const <String>[];
    if (groups.isEmpty) return '';
    final list = groups.map(_quoted).join(', ');
    return '\n      groups: [$list],';
  }

  String _testflightLane(ResolvedApp app) =>
      '''
  desc "Build and upload to TestFlight"
  lane :beta do |options|
    flavor = require_flavor(options)
    config = flavor_config(flavor)

    api_key = asc_api_key
    # Resolved before the build, so the artifact carries the number the store
    # is about to be told about. Resolving afterwards is how a build ends up
    # stamped with one number and announced with another.
    name = version_name(options[:version_name])
    number = build_number(
      options[:build_number],
      app_identifier: config[:bundle_id],
      api_key: api_key
    )
    UI.message("Shipping #{config[:bundle_id]} #{name}+#{number} to TestFlight")

    # Resolved before the build so a changelog that cannot be produced fails
    # in seconds rather than after the slowest part of the job.
    changelog = what_to_test(options[:changelog])

    certificates
    ipa = build_ipa(flavor: flavor, version_name: name, build_number: number)

    next UI.important("dry_run: would upload #{ipa}") if options[:dry_run]

    upload_to_testflight(
      api_key: api_key,
      app_identifier: config[:bundle_id],
      ipa: ipa,${_groups(app)}${_externalDistribution(app)}
      changelog: changelog,
      # Processing takes minutes to hours and blocking on it holds a runner
      # open for no benefit — the build is already Apple's problem by then.
      skip_waiting_for_build_processing: true
    )
  end
''';

  /// The "What to Test" text, from wherever `changelog_from` says.
  ///
  /// This field has been in the schema since the beginning and nothing read it:
  /// a config could ask for a changelog and get none, silently. That is worse
  /// than not offering the option.
  String _changelogHelper(ResolvedApp app) => FastlaneRuby.changelog(
    source: app.testflight?.changelogFrom ?? ChangelogSource.git,
    function: 'what_to_test',
    configKey: 'targets.testflight.changelog_from',
    question: 'What to test:',
  );

  /// External distribution, only when the config asks for it.
  ///
  /// `pilot` requires `groups` alongside it, which the config loader already
  /// refuses without — so by the time this renders, the pair is sound.
  static String _externalDistribution(ResolvedApp app) {
    final testflight = app.testflight;
    if (testflight == null || !testflight.distributeExternal) return '';
    return '\n      distribute_external: true,';
  }

  /// The App Store lane, generated only when the config names that target.
  ///
  /// Separate from `beta` because they are different decisions: TestFlight is
  /// a build going to testers, the App Store is a submission. Sharing a lane
  /// would make the more consequential one a flag on the other.
  String _appStoreLane(ResolvedApp app) {
    final appstore = app.appstore!;
    final metadata = appstore.metadataPath;

    return '''
  desc "Build and upload to App Store Connect"
  lane :release do |options|
    flavor = require_flavor(options)
    config = flavor_config(flavor)

    api_key = asc_api_key
    name = version_name(options[:version_name])
    number = build_number(
      options[:build_number],
      app_identifier: config[:bundle_id],
      api_key: api_key
    )
    UI.message("Shipping #{config[:bundle_id]} #{name}+#{number} to the App Store")

    certificates
    ipa = build_ipa(flavor: flavor, version_name: name, build_number: number)

    next UI.important("dry_run: would upload #{ipa}") if options[:dry_run]

    upload_to_app_store(
      api_key: api_key,
      app_identifier: config[:bundle_id],
      ipa: ipa,
      # Submitting for review is a decision a person makes, not something a
      # tool should do because it could.
      submit_for_review: ${appstore.submitForReview},
      # A store listing belongs to whoever writes it. shipway uploads a build.
${metadata == null ? '      skip_metadata: true,\n      skip_screenshots: true,' : '      metadata_path: root_path("$metadata"),\n      skip_screenshots: true,'}
      precheck_include_in_app_purchases: false,
      force: true
    )
  end
''';
  }
}
