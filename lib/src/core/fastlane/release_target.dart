import '../config/shipway_config.dart';

/// Where a build is going, and the generated lane that takes it there.
///
/// In `core` rather than beside `shipway release`, because `doctor` asks the
/// same question — does every configured destination have a lane? — and may
/// import nothing else. Two tables mapping a target to a lane is how one of
/// them ends up naming a lane the other never looks for.
enum ReleaseTarget {
  testflight('testflight', 'ios', 'beta'),
  appstore('appstore', 'ios', 'release'),
  play('play', 'android', 'play'),
  firebase('firebase', 'android', 'firebase');

  const ReleaseTarget(this.id, this.platform, this.lane);

  final String id;

  /// The platform whose Fastfile holds the lane.
  final String platform;

  /// How the platform is written in a sentence.
  String get platformLabel => platform == 'ios' ? 'an iOS' : 'an Android';

  /// The generated lane this runs.
  final String lane;

  /// Whether [app] configures this destination.
  bool isConfiguredIn(AppConfig app) => switch (this) {
    ReleaseTarget.testflight => app.targets.testflight != null,
    ReleaseTarget.appstore => app.targets.appstore != null,
    ReleaseTarget.play => app.targets.play != null,
    ReleaseTarget.firebase => app.targets.firebase != null,
  };

  static ReleaseTarget? parse(String? value) {
    for (final target in ReleaseTarget.values) {
      if (target.id == value) return target;
    }
    return null;
  }

  static List<String> get ids => <String>[
    for (final target in ReleaseTarget.values) target.id,
  ];
}
