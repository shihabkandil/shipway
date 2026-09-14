import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shipway/src/core/config/config_loader.dart';
import 'package:shipway/src/core/config/pipeline_references.dart';
import 'package:shipway/src/core/config/shipway_config.dart';
import 'package:shipway/src/core/model/android_model.dart';
import 'package:shipway/src/generators/fastlane_generators.dart';
import 'package:shipway/src/generators/android_fastfile_generator.dart';
import 'package:shipway/src/generators/fastfile_generator.dart';
import 'package:shipway/src/generators/generated_file.dart';
import 'package:shipway/src/generators/resolve_app.dart';
import 'package:test/test.dart';

/// The `example/` directory published with the package.
///
/// It shows what shipway writes, so it has to *be* what shipway writes: each
/// file is compared with the generators' output for `example/shipway.yaml`.
/// After a deliberate change to a generator, refresh it with
///
///     SHIPWAY_UPDATE_EXAMPLE=1 dart test test/unit/example_test.dart
void main() {
  const directory = 'example';
  final update = Platform.environment['SHIPWAY_UPDATE_EXAMPLE'] == '1';

  final configPath = p.join(directory, ConfigLoader.defaultFileName);
  final config = ConfigLoader.parse(
    File(configPath).readAsStringSync(),
    path: configPath,
  );

  test('the example config loads and names only what it declares', () {
    expect(PipelineReferences.check(config), isEmpty);
    final app = config.appOrNull(null)!;
    // Every destination is in it, which is the point of the example.
    expect(app.targets.testflight, isNotNull);
    expect(app.targets.appstore, isNotNull);
    expect(app.targets.play, isNotNull);
    expect(app.targets.firebase, isNotNull);
    expect(secretRefsOf(config).where((ref) => ref.value != null), isNotEmpty);
  });

  final app = ResolveApp.resolve(config, gradleDsl: GradleDsl.kotlin);
  final files = <GeneratedFile>[
    for (final generator in const <Generator>[
      GemfileGenerator(),
      PluginfileGenerator(),
      AppfileGenerator(),
      MatchfileGenerator(),
      IosFastfileGenerator(),
      AndroidFastfileGenerator(),
    ])
      ...generator.render(app),
  ];

  for (final file in files) {
    final path = p.join(directory, file.path);
    // The writer ends every whole file with a newline; so does the example.
    final expected = file.contents.endsWith('\n')
        ? file.contents
        : '${file.contents}\n';

    test('$path is what shipway generates', () {
      final target = File(path);
      if (update) {
        target
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(expected);
      }
      expect(
        target.existsSync(),
        isTrue,
        reason: 'Run with SHIPWAY_UPDATE_EXAMPLE=1 to write it.',
      );
      expect(
        target.readAsStringSync(),
        expected,
        reason:
            '$path no longer matches the generators. If that is intended, '
            'run with SHIPWAY_UPDATE_EXAMPLE=1.',
      );
    });
  }
}
