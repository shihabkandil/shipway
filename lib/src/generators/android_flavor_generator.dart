import '../core/model/android_model.dart';
import 'generated_file.dart';
import 'gradle_flavor_reconciler.dart';

/// Writes the `flavorDimensions` and `productFlavors` block into the app's
/// Gradle build file.
///
/// Block-managed: the build file belongs to the user and almost always contains
/// signing, dependencies and plugin configuration shipway must not touch. Only
/// the marked region is ours.
class AndroidFlavorGenerator extends Generator {
  const AndroidFlavorGenerator();

  @override
  String get name => 'android-flavors';

  @override
  String get description =>
      'Gradle flavorDimensions and productFlavors for each flavor.';

  @override
  List<GeneratedFile> render(ResolvedApp app) {
    if (!app.hasFlavors) return const <GeneratedFile>[];

    final kotlin = app.gradleDsl == GradleDsl.kotlin;
    final buffer = StringBuffer();

    // Dimensions in first-seen order, so the generated block is stable rather
    // than ordered by whatever a set iteration happens to produce.
    final dimensions = <String>[];
    for (final flavor in app.flavors) {
      if (!dimensions.contains(flavor.dimension)) {
        dimensions.add(flavor.dimension);
      }
    }

    // AGP 8+ generates no resValue unless the feature is switched on, and a
    // build that uses one without it fails with "contains custom resource
    // values, but the feature is disabled". Configuring `buildFeatures` twice
    // is harmless — it is the same object — so this is safe to emit next to a
    // project's own block.
    buffer
      ..writeln('buildFeatures {')
      ..writeln(kotlin ? '    resValues = true' : '    resValues true')
      ..writeln('}')
      ..writeln();

    for (final dimension in dimensions) {
      buffer.writeln(
        kotlin
            ? 'flavorDimensions += "$dimension"'
            : 'flavorDimensions "$dimension"',
      );
    }

    buffer
      ..writeln()
      ..writeln('productFlavors {');
    for (var i = 0; i < app.flavors.length; i++) {
      _writeFlavor(buffer, app.flavors[i], app, kotlin: kotlin);
      if (i != app.flavors.length - 1) buffer.writeln();
    }
    buffer.write('}');

    return <GeneratedFile>[
      GeneratedFile.block(
        path: 'android/app/${app.gradleDsl.buildFileName}',
        contents: buffer.toString(),
        // Inside `android { }`, because that is the only place these blocks are
        // legal.
        anchor: const BlockAnchor(insideBlock: 'android'),
        // The block creates each flavor, so the project's own declarations
        // of the same flavors are rewritten to configure them instead.
        reconciler: GradleFlavorReconciler(
          path: 'android/app/${app.gradleDsl.buildFileName}',
          flavors: <String>[for (final flavor in app.flavors) flavor.name],
          dimensions: dimensions,
          kotlin: kotlin,
        ),
        description:
            '${app.flavors.length} product '
            'flavor${app.flavors.length == 1 ? '' : 's'}',
      ),
    ];
  }

  void _writeFlavor(
    StringBuffer buffer,
    ResolvedFlavor flavor,
    ResolvedApp app, {
    required bool kotlin,
  }) {
    final header = kotlin ? 'create("${flavor.name}")' : flavor.name;
    buffer.writeln('    $header {');
    buffer.writeln(_assign('dimension', flavor.dimension, kotlin, indent: 8));

    // An empty suffix is the production flavor and must not be written: Gradle
    // would append the empty string, which is harmless, but the line implies a
    // decision that was never made.
    if (flavor.suffix.isNotEmpty) {
      buffer.writeln(
        _assign('applicationIdSuffix', flavor.suffix, kotlin, indent: 8),
      );
    }
    final versionNameSuffix = flavor.versionNameSuffix;
    if (versionNameSuffix != null && versionNameSuffix.isNotEmpty) {
      buffer.writeln(
        _assign('versionNameSuffix', versionNameSuffix, kotlin, indent: 8),
      );
    }

    final displayName = flavor.displayNameOr(app.projectName);
    buffer.writeln(
      kotlin
          ? '        resValue("string", "app_name", "$displayName")'
          : '        resValue "string", "app_name", "$displayName"',
    );

    buffer.write('    }');
    buffer.writeln();
  }

  static String _assign(
    String key,
    String value,
    bool kotlin, {
    required int indent,
  }) {
    final pad = ' ' * indent;
    return kotlin ? '$pad$key = "$value"' : '$pad$key "$value"';
  }
}
