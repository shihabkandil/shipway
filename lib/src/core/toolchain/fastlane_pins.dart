/// Pinned versions for the generated `Gemfile`s.
///
/// Pinned rather than floated because an unpinned fastlane is a build that
/// changes under you: the same commit signs and uploads differently next week.
/// These are facts about the world that go stale, so they carry the date they
/// were last checked, like `platform_deadlines.dart`.
abstract final class FastlanePins {
  /// Last verified 2026-09-09.
  static const String fastlane = '2.238.0';

  /// Last verified 2026-09-09.
  ///
  /// Held one minor behind deliberately: 1.0.0 requires Ruby >= 3.2, which is
  /// above [rubyFloor], and `bundle install` on a Ruby the floor admits fails
  /// version solving rather than degrading. These three constants have to stay
  /// mutually satisfiable, and this is the one that constrains the others.
  static const String firebaseAppDistribution = '0.10.1';

  /// The pinned fastlane's own `required_ruby_version`, which is `>= 3.0`.
  ///
  /// fastlane warns below 3.3 and will require it eventually; `doctor` carries
  /// that soft floor, because a Gemfile that refuses to install is a worse
  /// answer to "your Ruby is getting old" than a warning.
  static const String rubyFloor = '3.0';

  /// A ceiling on `google-apis-core`, written into the generated Gemfile.
  /// Last verified 2026-09-14.
  ///
  /// Neither [fastlane] nor [firebaseAppDistribution] caps it below 2.0, so
  /// those two pins alone resolved 1.1.0 — which runs on Faraday — alongside
  /// `net-http` 0.9.1. That combination crashed a Firebase App Distribution
  /// upload partway through in a field report; 0.18.0 uploaded. With this
  /// constraint the pins resolve 0.18.0 on Ruby 3.1.1.
  static const List<String> googleApisCore = <String>['>= 0.18', '< 1'];

  /// Whether a resolved `google-apis-core` is at or above the ceiling in
  /// [googleApisCore].
  static bool googleApisCoreAboveCeiling(String version) {
    final major = int.tryParse(
      RegExp(r'^\d+').stringMatch(version.trim()) ?? '',
    );
    return major != null && major >= 1;
  }
}
