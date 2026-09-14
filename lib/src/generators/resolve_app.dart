import '../core/config/shipway_config.dart';
import '../core/model/android_model.dart';
import 'generated_file.dart';

/// Narrows a config to one app and applies every default once.
///
/// The conventions live here rather than in each generator, so the Android
/// writer and the iOS writer cannot quietly disagree about what a flavor's id
/// or entrypoint is.
abstract final class ResolveApp {
  /// The dimension shipway generates when a flavor does not name one.
  static const String defaultDimension = 'environment';

  static ResolvedApp resolve(
    ShipwayConfig config, {
    String? appId,
    GradleDsl gradleDsl = GradleDsl.kotlin,
    String? iosSchemeTemplate,
  }) {
    final id = appId ?? config.defaultAppId;
    final app = config.appOrNull(id);
    if (app == null) {
      throw ArgumentError('No app named "$id" in this config.');
    }

    final androidBase = app.android?.applicationId;
    final iosBase = app.ios?.bundleId;

    return ResolvedApp(
      appId: id!,
      projectName: config.project.name,
      androidApplicationId: androidBase,
      iosBundleId: iosBase,
      gradleDsl: gradleDsl,
      iosTeamId: app.signing.ios?.teamId,
      iosSchemeTemplate: iosSchemeTemplate,
      iosExport: app.ios?.export ?? IosExport.gym,
      matchGitUrl: app.signing.ios?.matchGitUrl,
      matchStorage: app.signing.ios?.matchStorage ?? MatchStorage.git,
      ascApiKey: app.signing.ios?.apiKey,
      testflight: app.targets.testflight,
      play: app.targets.play,
      firebase: app.targets.firebase,
      androidSigning: app.signing.android,
      versioning: app.versioning,
      appstore: app.targets.appstore,
      shipsIos: app.shipsIos,
      flavors: <ResolvedFlavor>[
        for (final entry in app.flavors.entries)
          _flavor(entry.key, entry.value, androidBase, iosBase),
      ],
    );
  }

  static ResolvedFlavor _flavor(
    String name,
    FlavorConfig flavor,
    String? androidBase,
    String? iosBase,
  ) => ResolvedFlavor(
    name: name,
    suffix: flavor.suffix,
    // The convention, applied once. A config that disagrees says so
    // explicitly, because guessing here builds the wrong app under the
    // right bundle id.
    entrypoint: flavor.entrypoint ?? 'lib/main_$name.dart',
    dimension: flavor.dimension ?? defaultDimension,
    versionNameSuffix: flavor.versionNameSuffix,
    displayName: flavor.displayName,
    dartDefines: flavor.dartDefines,
    androidApplicationId: androidBase == null
        ? null
        : '$androidBase${flavor.suffix}',
    iosBundleId: iosBase == null ? null : '$iosBase${flavor.suffix}',
    firebaseAndroid: flavor.firebase?.android,
    firebaseIos: flavor.firebase?.ios,
    firebaseServiceAccountRef: flavor.firebase?.distribution?.serviceAccountRef,
    firebaseAndroidAppIdRef: flavor.firebase?.distribution?.androidAppIdRef,
  );
}
