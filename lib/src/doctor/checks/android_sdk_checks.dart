import '../../core/gradle/android_build_facts.dart';
import '../check.dart';
import '../tool_version.dart';

/// Which Android Gradle Plugin a `compileSdk` needs.
///
/// Facts about the world, like the store deadlines, and kept as small as what
/// is actually known. A level that is not listed is not checked: guessing a
/// floor for an API level nobody has built against would fail projects that
/// work.
abstract final class AgpCompatibility {
  /// Below this the build cannot find the platform at all.
  ///
  /// Source: a field report from a self-hosted runner. `compileSdk = 37` with
  /// AGP 8.11.1 failed with "Failed to find target with hash string
  /// 'android-37'" although the platform was installed — the SDK manager puts
  /// it in `platforms/android-37.0`, and that AGP only looks for
  /// `android-37`. AGP 9.1.1 with Gradle 9.3.1 built it. Only API 37 is
  /// listed because it is the only level seen to fail this way.
  static const Map<int, ToolVersion> required = <int, ToolVersion>{
    37: ToolVersion(9, 0, 0),
  };

  /// The minimum AGP Google documents for each API level.
  ///
  /// Source: the "Android API level support" table at
  /// https://developer.android.com/build/releases/about-agp, read 2026-10-01.
  /// An older plugin is "not supported" rather than known to fail — it usually
  /// builds with a warning — so falling below these warns and never blocks.
  static const Map<int, ToolVersion> documented = <int, ToolVersion>{
    33: ToolVersion(7, 2, 0),
    34: ToolVersion(8, 1, 1),
    35: ToolVersion(8, 6, 0),
    36: ToolVersion(8, 9, 1),
    37: ToolVersion(9, 1, 1),
  };

  static const String sourceUrl =
      'https://developer.android.com/build/releases/about-agp';

  /// The `sdkmanager` package for an API level.
  ///
  /// `platforms;android-37.0` is what an installed API 37 reports in its own
  /// `package.xml`; every earlier level is plain `android-<level>`. Later
  /// levels are assumed to keep the older form until one is seen.
  static String platformPackage(int level) =>
      level == 37 ? 'platforms;android-37.0' : 'platforms;android-$level';
}

/// Whether the project's `compileSdk`, its Android Gradle Plugin and the
/// installed SDK platforms agree.
///
/// A disagreement between them surfaces minutes into a Gradle build as a
/// missing "target with hash string", which names neither the plugin nor the
/// fix. All three are readable from files in under a second.
class CompileSdkCheck extends Check {
  @override
  String get id => 'compile_sdk';

  @override
  String get title => 'compileSdk and AGP';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    if (!context.hasProject) {
      return const CheckResult.skip('Not inside a Flutter project.');
    }
    final root = context.projectRoot;

    final compileSdk = AndroidBuildFacts.compileSdk(root);
    if (compileSdk == null) {
      return const CheckResult.skip('No compileSdk declared in android/app.');
    }
    final level = compileSdk.level;
    if (level == null) {
      // The Flutter Gradle plugin, or a variable, decides this when Gradle
      // configures. Guessing which Flutter is in play would be a second
      // opinion nobody can check.
      return CheckResult.skip(
        'compileSdk is `${compileSdk.expression}` in ${compileSdk.file}, '
        'which is only known once Gradle runs.',
      );
    }

    final declaration = AndroidBuildFacts.agp(root);
    final agp = switch (declaration?.version) {
      final String version => ToolVersion.tryParse(version),
      null => null,
    };

    if (agp != null) {
      final floor = AgpCompatibility.required[level];
      if (floor != null && agp < floor) {
        return CheckResult.fail(
          'compileSdk $level needs AGP ${_short(floor)} or newer; this '
          'project has ${declaration!.version}.',
          version: agp,
          fixHint:
              'The SDK manager installs API $level as '
              '${AgpCompatibility.platformPackage(level)}, which older '
              'plugins cannot see, so Gradle fails with "Failed to find '
              "target with hash string 'android-$level'\" even with it "
              'installed. Raise com.android.application in '
              '${declaration.file} to '
              '${AgpCompatibility.documented[level] ?? floor} or later, with '
              'the Gradle wrapper it requires, or lower compileSdk.',
          docsUrl: AgpCompatibility.sourceUrl,
        );
      }
    }

    final sdk = AndroidSdk.locate(root, environment: context.environment);
    final installed = sdk == null
        ? const <InstalledPlatform>[]
        : AndroidSdk.platforms(
            sdk,
          ).where((platform) => platform.level == level).toList();
    if (sdk != null && installed.isEmpty) {
      // A warning: Gradle downloads a missing platform itself where the SDK
      // licences have been accepted, so this fails some machines and not
      // others.
      return CheckResult.warn(
        'compileSdk $level, but that platform is not installed in $sdk.',
        fixHint:
            'Run `sdkmanager "${AgpCompatibility.platformPackage(level)}"`. '
            'Gradle only downloads it by itself where the SDK licences have '
            'been accepted.',
      );
    }

    final facts = <String>[
      'compileSdk $level',
      if (agp != null)
        'AGP ${declaration!.version}'
      else if (declaration?.expression != null)
        'AGP `${declaration!.expression}` (not readable statically)'
      else
        'AGP version not found',
      if (installed.isNotEmpty)
        '${installed.map((platform) => platform.directory).join(', ')} '
            'installed'
      else
        'no Android SDK found to look in',
    ].join(', ');

    final documented = AgpCompatibility.documented[level];
    if (agp != null && documented != null && agp < documented) {
      return CheckResult.warn(
        'compileSdk $level is documented to need AGP $documented or newer; '
        'this project has ${declaration!.version}.',
        version: agp,
        fixHint:
            'It may still build, with a warning. Raise '
            'com.android.application in ${declaration.file} when you can.',
        docsUrl: AgpCompatibility.sourceUrl,
      );
    }

    return CheckResult.ok(facts, version: agp);
  }

  /// `9` for 9.0.0, `8.9.1` otherwise: a floor reads as it would be said.
  static String _short(ToolVersion version) =>
      version.minor == 0 && version.patch == 0
      ? '${version.major}'
      : '$version';
}
