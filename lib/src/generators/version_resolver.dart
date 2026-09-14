import '../core/config/shipway_config.dart';
import '../core/secrets/secret_names.dart';

/// Renders the Ruby that decides a build number.
///
/// Ruby rather than Dart because one of the three strategies means asking App
/// Store Connect, Google Play or App Distribution, which only fastlane can do.
/// Computing the other two in Dart would leave two implementations of the
/// same question, and the failure when they disagree is a duplicate build
/// number in a store — an error whose message names neither implementation.
///
/// So there is one answer, in the place that can actually reach a store.
abstract final class VersionResolver {
  /// The version name and build number a release lane should use.
  ///
  /// `version_name` always comes from `pubspec.yaml`: a marketing version is a
  /// decision, not something to derive. Only the build number varies.
  ///
  /// [playKey] is how the Android lanes authenticate to Play, so a `remote`
  /// lookup reads the same credential the upload does. [firebase] adds
  /// `firebase_build_number`, for the Firebase lane.
  static String render({
    required VersioningStrategy strategy,
    required bool syncIosAndroid,
    required String platform,
    ({String name, String parameter})? playKey,
    bool firebase = false,
  }) =>
      '''
${_pubspecReader()}
${_buildNumber(strategy, platform, playKey)}
${firebase ? _firebaseBuildNumber(strategy) : ''}${_syncNote(syncIosAndroid)}''';

  /// Reads `version: x.y.z+n` without a YAML parser.
  ///
  /// The line has a fixed shape and pulling in a gem to read one field would be
  /// another pin to keep satisfiable on the Ruby floor.
  static String _pubspecReader() => r'''
def pubspec_version
  @pubspec_version ||= begin
    match = File.read(root_path("pubspec.yaml"))
                .match(/^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$/)
    unless match
      UI.user_error!("Could not read `version: x.y.z+n` from pubspec.yaml. " \
                     "Every release needs a version to claim.")
    end
    { name: match[1], code: match[2] }
  end
end

def version_name(requested = nil)
  value = requested.to_s.strip
  value.empty? ? pubspec_version[:name] : value
end
''';

  static String _buildNumber(
    VersioningStrategy strategy,
    String platform,
    ({String name, String parameter})? playKey,
  ) => switch (strategy) {
    VersioningStrategy.increment => _incrementStrategy(),
    VersioningStrategy.timestamp => _timestampStrategy(),
    VersioningStrategy.remote =>
      platform == 'ios'
          ? _remoteIosStrategy()
          : _remoteAndroidStrategy(
              playKey ??
                  (
                    name: SecretNames.playServiceAccountPath,
                    parameter: 'json_key',
                  ),
            ),
  };

  static String _incrementStrategy() => r'''
# versioning.strategy: increment — pubspec is the source of truth, and bumping
# it is a commit somebody makes deliberately.
def build_number(requested = nil, **)
  value = requested.to_s.strip
  value.empty? ? pubspec_version[:code] : value
end
''';

  static String _timestampStrategy() => r'''
# versioning.strategy: timestamp — monotonic without asking anything, which is
# what makes it work offline and on a fresh checkout.
def build_number(requested = nil, **)
  value = requested.to_s.strip
  return value unless value.empty?

  Time.now.utc.strftime("%y%m%d%H%M")
end
''';

  static String _remoteIosStrategy() => r'''
# versioning.strategy: remote — ask App Store Connect what the last build was.
# The store is the only thing that knows for certain, and a number derived from
# anything else is a guess that fails at upload with a message naming neither.
def build_number(requested = nil, app_identifier:, api_key: nil)
  value = requested.to_s.strip
  return value unless value.empty?

  latest = latest_testflight_build_number(
    app_identifier: app_identifier,
    api_key: api_key,
    # A brand new app has no builds; starting at 0 makes the first one 1.
    initial_build_number: 0
  )
  (latest.to_i + 1).to_s
end
''';

  /// Asks Play, with the credential the upload itself uses.
  static String _remoteAndroidStrategy(
    ({String name, String parameter}) playKey,
  ) =>
      '''
# versioning.strategy: remote — ask Play for the version codes it already has.
#
# Every standard track, plus the one being uploaded to: Play rejects a code
# that is not higher than every code the app has used, and the highest is
# usually on production rather than on the track a build is headed for.
def build_number(requested = nil, package_name:, tracks: [], **)
  value = requested.to_s.strip
  return value unless value.empty?

  names = (%w[internal alpha beta production] + tracks).uniq
  failures = []
  codes = names.flat_map do |track|
    google_play_track_version_codes(
      package_name: package_name,
      track: track,
      ${playKey.parameter}: ENV.fetch("${playKey.name}")
    ) || []
  rescue StandardError => e
    # A track this app has never used answers with an error, not an empty list.
    failures << "#{track}: #{e.message}"
    []
  end

  # Not one track answered: that is a credential or package problem, and
  # numbering the build 1 would only move the failure to the upload.
  if failures.length == names.length
    UI.user_error!("Could not read version codes from Play for #{package_name}.\\n#{failures.join("\\n")}")
  end

  # `.max`, not `.first`: the API does not promise an order, and picking the
  # wrong element produces a code Play rejects as non-increasing. No codes at
  # all gives nil, which becomes 0, so the first upload is 1.
  (codes.map(&:to_i).max.to_i + 1).to_s
end
''';

  /// The build number for a Firebase App Distribution release.
  ///
  /// Only `remote` differs: each Firebase app keeps its own release history,
  /// which is the history that decides what comes next for it. The other
  /// strategies never ask anything, so Firebase takes the number any release
  /// would.
  static String _firebaseBuildNumber(VersioningStrategy strategy) =>
      strategy == VersioningStrategy.remote
      ? r'''
# versioning.strategy: remote, for Firebase — ask App Distribution for the
# latest release of this app.
def firebase_build_number(requested = nil, app:, credentials:)
  value = requested.to_s.strip
  return value unless value.empty?

  latest = firebase_app_distribution_get_latest_release(
    app: app,
    service_credentials_file: credentials
  )
  # nil when the app has no releases yet, so the first upload is 1.
  ((latest && latest[:buildVersion]).to_i + 1).to_s
end
'''
      : r'''
# Firebase takes the number any other release would.
def firebase_build_number(requested = nil, **)
  build_number(requested)
end
''';

  static String _syncNote(bool sync) => sync
      ? '# versioning.sync_ios_android is on: each release resolves the build\n'
            '# number once and both platforms are given the same one.\n'
      : '# versioning.sync_ios_android is off: each platform numbers itself.\n';
}
